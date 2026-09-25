-- tests/player/fanout_spec.lua
--
-- Tier-1 spec for player/fanout.lua -- the DETERMINISTIC MULTI-SPEAKER FAN-OUT
-- with GRACEFUL DEGRADATION.
--
-- FROZEN PUBLIC INTERFACE under test:
--   local fanout = require("player.fanout")
--   fanout.assign(events, analysis, speakers) -> assignment
--   fanout.play(events, analysis, speakers, dispatch) -> { calls_made, refused,
--                                                          dropped, results }
--
--   assignment = {
--     speakers = <the array it was given>,
--     required = <integer>,        -- nbs.speakers.required_count(analysis)
--     found    = <integer>,        -- #speakers
--     dropped  = <integer>,
--     dropped_events = <array>,    -- dropped events, in drop order
--     by_speaker = { [side] = <array of events, frozen order> },
--     warning_code = "speakers" | nil,   -- BARE code
--     warning_args = { peak, required, found, dropped } | nil,
--   }
--
-- THE CAPACITY UNIT IS A 50 ms WINDOW (measured on event.t_ms), NOT a tick and
-- not the whole song.  Per window, per speaker:
--   * a play_note consumes ONE of MAX_NOTES_PER_TICK (8) slots;
--   * a play_sound consumes the ENTIRE speaker for that window;
--   * a custom event consumes NOTHING (dispatch refuses it) -- it must NEVER
--     cause a drop, and it is passed through to the first speaker so the
--     recorded call order stays a faithful projection.
--
-- ASSIGNMENT POLICY: stable greedy least-loaded.  Walk events in their frozen
-- (tick, layer, note) order; pick the speaker with the FEWEST notes already
-- assigned in that event's window; ties break to the ASCENDING side (the
-- earliest speaker in the already-side-sorted array).  A play_sound needs a
-- speaker with NOTHING else in the window; if none is empty it is dropped.
--
-- DROP POLICY: deterministic and preserves the early song.  An event that
-- cannot be placed is dropped; because the walk is in frozen order, the losers
-- are the LATER events in (tick_index, layer_index, note_index) order.
--
-- DETERMINISM: no `pairs` may decide any emitted order; `play()` must emit in
-- the frozen event order, routing each event to its assigned speaker.
--
-- Mock idioms follow tests/player/dispatch_spec.lua / speaker_spec.lua:
--   speaker.mock(side) records { method, args } and never refuses.

local fanout = require("player.fanout")
local speaker = require("player.speaker")
local dispatch = require("player.dispatch")

-- ---------------------------------------------------------------------------
-- Builders
-- ---------------------------------------------------------------------------

-- Copy only this fixed set of keys, so an override never silently leaks an
-- unexpected field into an event.
local EVENT_KEYS = {
  "t_ms", "tick_index", "layer_index", "note_index", "instrument", "key",
  "kind", "name", "custom_index", "volume", "pitch", "pitch_cents",
  "layer_volume",
}

-- A plan-shaped event with every required field, overridable per case.
local function event(overrides)
  local built = {
    t_ms = 0,
    tick_index = 0,
    layer_index = 0,
    note_index = 1,
    instrument = 0,
    key = 45,
    kind = "play_note",
    name = "harp",
    volume = 2,
    pitch = 12,
    pitch_cents = 0,
    layer_volume = 100,
  }
  if type(overrides) == "table" then
    for index = 1, #EVENT_KEYS do
      local key = EVENT_KEYS[index]
      if overrides[key] ~= nil then
        built[key] = overrides[key]
      end
    end
  end
  return built
end

-- An analysis result carrying only the fields fanout/nbs.speakers read.
local function analysis(overrides)
  local built = {
    tick_ms = 50,
    ticks_per_second = 20,
    peak_concurrent = 0,
    vanilla_notes_at_peak = 0,
    play_sound_notes_at_peak = 0,
  }
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      built[key] = value
    end
  end
  return built
end

-- Two side-sorted speaker mocks, matching speaker.discover()'s ordering.
local function two_speakers()
  return { speaker.mock("left"), speaker.mock("right") }
end

-- A deterministic plan of `count` simultaneous play_note events in ONE window.
local function burst(count, t_ms)
  local events = {}
  for index = 1, count do
    events[index] = event({
      t_ms = t_ms or 0,
      tick_index = math.floor((t_ms or 0) / 50),
      layer_index = 0,
      note_index = index,
      name = "n" .. tostring(index),
    })
  end
  return events
end

-- A recording dispatcher: logs the emitted (tick, layer, note) and side of
-- every dispatched event, in call order, and reports a successful call.
local function recording_dispatch()
  local log = {}
  local recorder = {}
  function recorder:event(plan_event, record)
    log[#log + 1] = {
      tick_index = plan_event.tick_index,
      layer_index = plan_event.layer_index,
      note_index = plan_event.note_index,
      side = record.side,
    }
    return {
      called = true,
      method = "play_note",
      speaker_side = record.side,
      refused = false,
    }
  end
  return recorder, log
end

-- A speaker mock that RECORDS the attempt but always REFUSES (returns false):
-- on CC:Tweaked the per-tick budget makes a refusal normal, not a failure.
local function refusing_mock(side)
  local record = { side = side, calls = {} }
  function record.play_note(self, name, volume, pitch)
    self.calls[#self.calls + 1] =
      { method = "play_note", args = { name, volume, pitch } }
    return false
  end
  function record.play_sound(self, name, volume, pitch)
    self.calls[#self.calls + 1] =
      { method = "play_sound", args = { name, volume, pitch } }
    return false
  end
  function record.stop(self)
    return true
  end
  return record
end

local function count_of(assignment, side)
  return #assignment.by_speaker[side]
end

-- ---------------------------------------------------------------------------
-- 1-2. required/found accounting and the balanced split
-- ---------------------------------------------------------------------------

describe("fanout.assign accounting", function()
  it("1. two speakers, analysis requiring 1: required=1, found=2, dropped=0, no warning", function()
    local speakers = two_speakers()
    local events = { event({ t_ms = 0, tick_index = 0, note_index = 1 }) }

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 1, peak_concurrent = 1 }), speakers)

    expect.equal(result.required, 1)
    expect.equal(result.found, 2)
    expect.equal(result.dropped, 0)
    expect.equal(result.warning_code, nil)
    expect.equal(result.warning_args, nil)
    -- The assignment hands back the very array it was given.
    expect.truthy(result.speakers == speakers)
  end)

  it("2. ten simultaneous notes across two speakers split 5/5 (ascending-side least-loaded)", function()
    local speakers = two_speakers()
    local events = burst(10, 0)

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 10, peak_concurrent = 10 }), speakers)

    expect.equal(count_of(result, "left"), 5)
    expect.equal(count_of(result, "right"), 5)
    expect.equal(result.dropped, 0)
    -- The earliest event wins the earliest side (tie-break ascending).
    expect.equal(result.by_speaker["left"][1].note_index, 1)
    expect.equal(result.by_speaker["right"][1].note_index, 2)

    io.write(string.format("    CASE-2 balanced split: left=%d right=%d dropped=%d\n",
      count_of(result, "left"), count_of(result, "right"), result.dropped))
  end)

  it("3. eight simultaneous notes on ONE speaker is legal: dropped=0, all eight land there", function()
    local speakers = { speaker.mock("left") }
    local events = burst(8, 0)

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 8, peak_concurrent = 8 }), speakers)

    expect.equal(result.dropped, 0)
    expect.equal(count_of(result, "left"), 8)
  end)

  it("4. nine simultaneous notes on ONE speaker drops exactly the LAST in frozen order", function()
    local speakers = { speaker.mock("left") }
    local events = burst(9, 0)

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 9, peak_concurrent = 9 }), speakers)

    expect.equal(result.dropped, 1)
    expect.equal(count_of(result, "left"), 8)
    expect.equal(#result.dropped_events, 1)
    -- The loser is the 9th (last assigned) note, not an early one.
    expect.equal(result.dropped_events[1].note_index, 9)
  end)

  it("5. DEGRADATION WARNING: overflow sets the bare code and the peak/required/found/dropped args", function()
    local speakers = { speaker.mock("left") }
    local events = burst(9, 0)

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 9, peak_concurrent = 9 }), speakers)

    expect.equal(result.warning_code, "speakers")
    expect.equal(result.warning_args.peak, 9)
    expect.equal(result.warning_args.required, 2)
    expect.equal(result.warning_args.found, 1)
    expect.equal(result.warning_args.dropped, 1)

    io.write(string.format(
      "    CASE-5 warning: code=%s peak=%d required=%d found=%d dropped=%d\n",
      tostring(result.warning_code), result.warning_args.peak,
      result.warning_args.required, result.warning_args.found,
      result.warning_args.dropped))
  end)
end)

-- ---------------------------------------------------------------------------
-- 6-7. play_sound occupies an entire window
-- ---------------------------------------------------------------------------

describe("fanout assign: play_sound occupies a window", function()
  it("6. play_sound + play_note on ONE speaker drop one; on TWO they land on different speakers", function()
    local events = {
      event({ kind = "play_sound", name = "trumpet", key = 45,
        t_ms = 0, layer_index = 0, note_index = 1 }),
      event({ kind = "play_note", name = "harp",
        t_ms = 0, layer_index = 1, note_index = 1 }),
    }

    local one = fanout.assign(events,
      analysis({ play_sound_notes_at_peak = 1, vanilla_notes_at_peak = 1,
        peak_concurrent = 2 }),
      { speaker.mock("left") })
    expect.equal(one.dropped, 1)

    local two = fanout.assign(events,
      analysis({ play_sound_notes_at_peak = 1, vanilla_notes_at_peak = 1,
        peak_concurrent = 2 }),
      two_speakers())
    expect.equal(two.dropped, 0)
    -- Exactly one side carries the play_sound and the other the play_note.
    local sound_side = nil
    local note_side = nil
    if #two.by_speaker["left"] > 0 then
      if two.by_speaker["left"][1].kind == "play_sound" then
        sound_side = "left"
      else
        note_side = "left"
      end
    end
    if #two.by_speaker["right"] > 0 then
      if two.by_speaker["right"][1].kind == "play_sound" then
        sound_side = "right"
      else
        note_side = "right"
      end
    end
    expect.equal(sound_side ~= note_side, true)
    io.write(string.format(
      "    CASE-6 play_sound side=%s play_note side=%s dropped1=%d dropped2=%d\n",
      tostring(sound_side), tostring(note_side), one.dropped, two.dropped))
  end)

  it("7. a speaker already holding a play_note cannot take a play_sound; the sound goes to the empty speaker", function()
    local speakers = two_speakers()
    local events = {
      event({ kind = "play_note", name = "harp",
        t_ms = 0, layer_index = 0, note_index = 1 }),
      event({ kind = "play_sound", name = "trumpet", key = 45,
        t_ms = 0, layer_index = 1, note_index = 1 }),
    }

    local result = fanout.assign(events,
      analysis({ play_sound_notes_at_peak = 1, vanilla_notes_at_peak = 1,
        peak_concurrent = 2 }), speakers)

    expect.equal(result.dropped, 0)
    -- play_note took the first (left) speaker; the play_sound must take right.
    expect.equal(result.by_speaker["left"][1].kind, "play_note")
    expect.equal(result.by_speaker["right"][1].kind, "play_sound")

    io.write(string.format(
      "    CASE-7 play_sound routed to empty speaker: left=%s right=%s\n",
      result.by_speaker["left"][1].kind,
      result.by_speaker["right"][1].kind))
  end)
end)

-- ---------------------------------------------------------------------------
-- 8-9. custom consumes nothing; distinct windows do not compete
-- ---------------------------------------------------------------------------

describe("fanout assign: capacity boundaries", function()
  it("8. twenty custom events in one window never drop and never raise the speakers warning", function()
    local speakers = { speaker.mock("left") }
    local events = {}
    for index = 1, 20 do
      events[index] = event({ kind = "custom", name = "custom",
        custom_index = index - 1, t_ms = 0, layer_index = 0,
        note_index = index })
    end

    local result = fanout.assign(events, analysis(), speakers)

    expect.equal(result.dropped, 0)
    expect.equal(result.warning_code, nil)
    expect.equal(#result.dropped_events, 0)

    io.write(string.format(
      "    CASE-8 custom=%d dropped=%d warning=%s\n",
      #events, result.dropped, tostring(result.warning_code)))
  end)

  it("9. eight notes in window A and eight in window B (>= 50 ms apart) never compete on one speaker", function()
    local speakers = { speaker.mock("left") }
    local window_a = burst(8, 0)
    local window_b = burst(8, 50)
    local events = {}
    for index = 1, #window_a do
      events[#events + 1] = window_a[index]
    end
    for index = 1, #window_b do
      events[#events + 1] = window_b[index]
    end

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 8, peak_concurrent = 8 }), speakers)

    expect.equal(result.dropped, 0)
    expect.equal(count_of(result, "left"), 16)
  end)
end)

-- ---------------------------------------------------------------------------
-- 10-11. frozen order in the emitted calls; determinism
-- ---------------------------------------------------------------------------

describe("fanout.play determinism", function()
  it("10. emitted call order equals the frozen (tick, layer, note) event order", function()
    local speakers = two_speakers()
    local events = {
      event({ t_ms = 0, tick_index = 0, layer_index = 0, note_index = 1,
        name = "a" }),
      event({ t_ms = 0, tick_index = 0, layer_index = 1, note_index = 1,
        name = "b" }),
      event({ t_ms = 0, tick_index = 0, layer_index = 2, note_index = 1,
        name = "c" }),
      event({ t_ms = 100, tick_index = 2, layer_index = 0, note_index = 1,
        name = "d" }),
      event({ t_ms = 100, tick_index = 2, layer_index = 1, note_index = 1,
        name = "e" }),
    }

    local recorder, log = recording_dispatch()
    local played = fanout.play(events,
      analysis({ vanilla_notes_at_peak = 3, peak_concurrent = 3 }), speakers,
      recorder)

    expect.equal(played.calls_made, 5)

    local expected = {}
    for index = 1, #events do
      expected[index] = {
        tick_index = events[index].tick_index,
        layer_index = events[index].layer_index,
        note_index = events[index].note_index,
      }
    end
    local actual = {}
    for index = 1, #log do
      actual[index] = {
        tick_index = log[index].tick_index,
        layer_index = log[index].layer_index,
        note_index = log[index].note_index,
      }
    end
    expect.sequence_equal(actual, expected)

    -- The two speakers genuinely interleaved (so this is not a single-speaker
    -- sequence by accident).
    local sides = {}
    for index = 1, #log do
      sides[#sides + 1] = log[index].side
    end
    io.write(string.format("    CASE-10 call order sides: %s\n",
      table.concat(sides, ",")))
  end)

  it("11. ten assign+play runs serialise byte-identically", function()
    local events = {
      event({ t_ms = 0, layer_index = 0, note_index = 1, name = "a" }),
      event({ t_ms = 0, layer_index = 1, note_index = 1, name = "b" }),
      event({ t_ms = 0, layer_index = 2, note_index = 1, kind = "custom",
        name = "c" }),
      event({ t_ms = 0, layer_index = 3, note_index = 1, name = "d" }),
      event({ t_ms = 50, layer_index = 0, note_index = 1, name = "e" }),
      event({ t_ms = 50, layer_index = 1, note_index = 1, name = "f" }),
      event({ t_ms = 50, layer_index = 2, note_index = 1, name = "g" }),
      event({ t_ms = 50, layer_index = 3, note_index = 1, name = "h" }),
    }
    local summary = analysis({ vanilla_notes_at_peak = 4, peak_concurrent = 4 })

    local first = nil
    for run = 1, 10 do
      local assignment = fanout.assign(events, summary, two_speakers())
      local recorder, log = recording_dispatch()
      local played = fanout.play(events, summary, two_speakers(), recorder)

      local parts = {}
      parts[#parts + 1] = "left=" .. tostring(count_of(assignment, "left"))
      parts[#parts + 1] = "right=" .. tostring(count_of(assignment, "right"))
      parts[#parts + 1] = "dropped=" .. tostring(assignment.dropped)
      for index = 1, #assignment.dropped_events do
        local dropped_event = assignment.dropped_events[index]
        parts[#parts + 1] = string.format("drop[%d]=%d/%d/%d", index,
          dropped_event.tick_index, dropped_event.layer_index,
          dropped_event.note_index)
      end
      local calls = {}
      for index = 1, #log do
        calls[#calls + 1] = string.format("%d/%d/%d@%s", log[index].tick_index,
          log[index].layer_index, log[index].note_index, log[index].side)
      end
      parts[#parts + 1] = "calls_made=" .. tostring(played.calls_made)
      parts[#parts + 1] = "calls=" .. table.concat(calls, ",")

      local serialised = table.concat(parts, ";")
      if first == nil then
        first = serialised
      else
        expect.equal(serialised, first)
      end
    end

    io.write(string.format("    CASE-11 determinism serialisation: %s\n", first))
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. ascending-side tie-break
-- ---------------------------------------------------------------------------

describe("fanout assign: ascending-side tie-break", function()
  it("12. with two equally-loaded speakers the next event takes the FIRST side", function()
    local speakers = two_speakers()
    -- e1 -> left, e2 -> right (balancing), e3 is the tie-break probe.
    local events = {
      event({ t_ms = 0, layer_index = 0, note_index = 1, name = "e1" }),
      event({ t_ms = 0, layer_index = 1, note_index = 1, name = "e2" }),
      event({ t_ms = 0, layer_index = 2, note_index = 1, name = "e3" }),
    }

    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 3, peak_concurrent = 3 }), speakers)

    expect.equal(count_of(result, "left"), 2)
    expect.equal(count_of(result, "right"), 1)
    expect.equal(result.by_speaker["left"][2].name, "e3")

    io.write(string.format(
      "    CASE-12 tie-break: left=%d right=%d last_left=%s\n",
      count_of(result, "left"), count_of(result, "right"),
      result.by_speaker["left"][2].name))
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. hostile inputs never raise
-- ---------------------------------------------------------------------------

describe("fanout.assign hostile inputs", function()
  it("13. nil/empty/hostile inputs all return a table; zero speakers drops every consumer", function()
    local probes = {
      function() return fanout.assign({}, analysis(), two_speakers()) end,
      function() return fanout.assign({}, analysis(), {}) end,
      function() return fanout.assign(nil, nil, nil) end,
      function() return fanout.assign(burst(3, 0), nil, nil) end,
      function() return fanout.assign(burst(3, 0), analysis(), {}) end,
      function() return fanout.assign({ event({ kind = "custom" }) },
        analysis(), {}) end,
      function() return fanout.assign(42, "nope", "nope") end,
    }

    for index = 1, #probes do
      local ok, result = pcall(probes[index])
      expect.truthy(ok)
      expect.equal(type(result), "table")
    end

    -- Zero speakers + a non-empty plan: every play_note/play_sound is dropped.
    local events = {
      event({ t_ms = 0, layer_index = 0, note_index = 1 }),
      event({ kind = "play_sound", name = "trumpet", key = 45,
        t_ms = 0, layer_index = 1, note_index = 1 }),
      event({ kind = "custom", name = "c", t_ms = 0, layer_index = 2,
        note_index = 1 }),
    }
    local result = fanout.assign(events,
      analysis({ vanilla_notes_at_peak = 1, play_sound_notes_at_peak = 1,
        peak_concurrent = 2 }), {})
    expect.equal(result.dropped, 2)
    expect.equal(#result.dropped_events, 2)
    expect.equal(result.warning_code, "speakers")

    -- A custom-only plan with zero speakers drops NOTHING.
    local custom_only = fanout.assign(
      { event({ kind = "custom" }), event({ kind = "custom" }) },
      analysis(), {})
    expect.equal(custom_only.dropped, 0)

    io.write(string.format(
      "    CASE-13 hostile sweep: %d probes returned tables; zero-speaker dropped=%d (custom kept=0)\n",
      #probes, result.dropped))
  end)
end)

-- ---------------------------------------------------------------------------
-- 14-15. integration with the real dispatcher; refusals are counted
-- ---------------------------------------------------------------------------

describe("fanout.play integration", function()
  it("14. real dispatcher + speaker mocks: calls_made equals non-custom events; custom makes no call", function()
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local speakers = { left, right }

    local events = {
      event({ kind = "play_note", name = "n1", key = 45,
        t_ms = 0, tick_index = 0, layer_index = 0, note_index = 1 }),
      event({ kind = "play_note", name = "n2", key = 46,
        t_ms = 0, tick_index = 0, layer_index = 1, note_index = 1 }),
      event({ kind = "custom", name = "custom", custom_index = 0,
        t_ms = 0, tick_index = 0, layer_index = 2, note_index = 1 }),
      event({ kind = "play_note", name = "n4", key = 48,
        t_ms = 0, tick_index = 0, layer_index = 3, note_index = 1 }),
      event({ kind = "play_sound", name = "trumpet", key = 45,
        t_ms = 100, tick_index = 2, layer_index = 0, note_index = 1 }),
      event({ kind = "play_note", name = "n6", key = 50,
        t_ms = 100, tick_index = 2, layer_index = 1, note_index = 1 }),
    }

    local summary = analysis({ vanilla_notes_at_peak = 2,
      play_sound_notes_at_peak = 1, peak_concurrent = 3 })

    local assignment = fanout.assign(events, summary, speakers)
    local played = fanout.play(events, summary, speakers, dispatch.new())

    -- Expected call sequence per side, derived from the assignment (custom
    -- events produce no dispatcher call and are skipped).
    local function expected(side)
      local out = {}
      local list = assignment.by_speaker[side]
      for index = 1, #list do
        local plan_event = list[index]
        if plan_event.kind == "play_note" or plan_event.kind == "play_sound" then
          out[#out + 1] =
            { method = plan_event.kind, name = plan_event.name }
        end
      end
      return out
    end
    local function recorded(record)
      local out = {}
      for index = 1, #record.calls do
        out[#out + 1] = {
          method = record.calls[index].method,
          name = record.calls[index].args[1],
        }
      end
      return out
    end

    expect.equal(played.calls_made, 5)
    expect.equal(played.dropped, 0)
    expect.equal(#left.calls + #right.calls, 5)
    expect.sequence_equal(recorded(left), expected("left"))
    expect.sequence_equal(recorded(right), expected("right"))

    io.write(string.format(
      "    CASE-14 calls_made=%d dropped=%d left=%d right=%d custom_calls=0\n",
      played.calls_made, played.dropped, #left.calls, #right.calls))
  end)

  it("15. a refusing speaker still counts attempts in calls_made and refusals in refused", function()
    local record = refusing_mock("left")
    local events = burst(3, 0)

    local played = fanout.play(events,
      analysis({ vanilla_notes_at_peak = 3, peak_concurrent = 3 }),
      { record }, dispatch.new())

    expect.equal(played.calls_made, 3)
    expect.equal(played.refused, 3)
    expect.equal(#record.calls, 3)

    io.write(string.format(
      "    CASE-15 refusals: calls_made=%d refused=%d recorded=%d\n",
      played.calls_made, played.refused, #record.calls))
  end)
end)
