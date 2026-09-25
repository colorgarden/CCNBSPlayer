-- tests/player/dispatch_spec.lua
--
-- Tier-1 spec for player/dispatch.lua -- the ROUTING layer that decides, for ONE
-- already-planned event, exactly which speaker call to make and WHEN TO REFUSE.
--
-- player/plan.lua has ALREADY resolved everything numeric: the instrument
-- routing (`kind`/`name`/`custom_index`), the speaker volume (0..3) and the
-- playNote semitone pitch (UNCLAMPED).  Dispatch must therefore NEVER re-resolve
-- an instrument or re-map a volume; it routes on the pre-computed `kind` and
-- forwards `volume`/`pitch` verbatim.  Case 12 pins that mechanically.
--
-- FROZEN PUBLIC INTERFACE under test:
--   local dispatch = require("player.dispatch")
--   dispatch.new(opts)                    -> d
--   d:event(event, speaker_record)        -> result
--   d:warnings()                          -> array of warning codes, emission order
--   d:reset()                             -> clears the once-only warning ledger
--   dispatch.WARN_CUSTOM_INSTRUMENT       -> "custom-instrument"
--   dispatch.WARN_PLAY_SOUND_PITCH        -> "play-sound-pitch"
--
--   result = { called, method, speaker_side, refused, warning_code [, error_message] }
--
-- THE THREE BRANCHES:
--   1. kind == "play_note"  -> speaker:play_note(name, volume, pitch); pitch
--      verbatim (NEGATIVE IS FINE: extended range is the point, never clamp).
--   2. kind == "play_sound" -> speaker:play_sound(name, volume, ratio) where the
--      ratio comes from mapping.play_sound_pitch(event.key) -- plan.lua keeps
--      SEMITONES in `pitch`, so dispatch is the one that computes the ratio.  A
--      key whose ideal ratio is outside 0.5..2.0 was CLAMPED; warn once.
--   3. kind == "custom"     -> REFUSE: no call at all; warn once.
--
-- ONCE-ONLY WARNINGS: a given code appears at most once in d:warnings().
-- REFUSAL vs ERROR: `refused = true` means the speaker returned false (NORMAL);
-- `refused = false` plus an `error_message` means the call RAISED or the speaker
-- was unusable.  Dispatch must never raise, for any input.
--
-- Mock idiom follows tests/player/speaker_spec.lua: speaker.mock(side) records
-- { method, args } and returns true; record.calls is the buffer.

local dispatch = require("player.dispatch")
local speaker = require("player.speaker")
local mapping = require("player.mapping")
local instrument_table = require("nbs.instrument_table")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- A mock that always REFUSES (returns false) while still recording the call:
-- the 8-notes-per-tick budget makes a refusal normal, and dispatch must forward
-- it rather than treat it as an error.
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

-- A bare event builder so each case states only what it cares about.
local function play_note_event(overrides)
  local event = { kind = "play_note", name = "harp", volume = 2, pitch = 12 }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

-- ---------------------------------------------------------------------------
-- Restore any monkey-patched mapping/instrument functions even if a case fails.
-- ---------------------------------------------------------------------------

local saved_speaker_volume = nil
local saved_resolve = nil

after_each(function()
  if saved_speaker_volume ~= nil then
    mapping.speaker_volume = saved_speaker_volume
    saved_speaker_volume = nil
  end
  if saved_resolve ~= nil then
    instrument_table.resolve = saved_resolve
    saved_resolve = nil
  end
end)

-- ---------------------------------------------------------------------------
-- 1-2. play_note branch
-- ---------------------------------------------------------------------------

describe("dispatch play_note branch", function()
  it("1. routes to play_note with (name, volume, pitch) and reports the call", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local result = d:event(
      play_note_event({ name = "harp", volume = 2, pitch = 12 }), record)

    expect.equal(#record.calls, 1)
    expect.equal(record.calls[1].method, "play_note")
    expect.deep_equal(record.calls[1].args, { "harp", 2, 12 })

    expect.equal(result.called, true)
    expect.equal(result.method, "play_note")
    expect.equal(result.warning_code, nil)
  end)

  it("2. passes a NEGATIVE pitch through VERBATIM (extended range, no clamp)", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local result = d:event(play_note_event({ pitch = -13 }), record)

    expect.equal(#record.calls, 1)
    -- Assert the literal argument, not merely that it ran.
    expect.equal(record.calls[1].args[3], -13)
    expect.equal(result.called, true)
    expect.equal(result.method, "play_note")

    io.write(string.format("    CASE-2 negative pitch forwarded: %s\n",
      tostring(record.calls[1].args[3])))
  end)
end)

-- ---------------------------------------------------------------------------
-- 3-4. play_sound branch (v6 trumpet; ratio, not semitones)
-- ---------------------------------------------------------------------------

describe("dispatch play_sound branch", function()
  it("3. routes to play_sound with the RATIO 1.0 for the reference key 45", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local event = {
      kind = "play_sound",
      name = "minecraft:block.note_block.trumpet",
      key = 45,
      volume = 1,
      pitch = 12, -- semitones; must NOT be forwarded as the third argument
    }

    local result = d:event(event, record)

    expect.equal(#record.calls, 1)
    expect.equal(record.calls[1].method, "play_sound")
    expect.equal(record.calls[1].args[1],
      "minecraft:block.note_block.trumpet")
    expect.equal(record.calls[1].args[2], 1)
    -- The literal numeric ratio, NOT the semitone value (12).
    expect.equal(record.calls[1].args[3], 1.0)
    expect.truthy(record.calls[1].args[3] ~= 12)
    expect.equal(result.called, true)
    expect.equal(result.method, "play_sound")
    expect.equal(result.warning_code, nil)

    io.write(string.format(
      "    CASE-3 play_sound ratio for key 45: %s (mapping.play_sound_pitch(45)=%s)\n",
      tostring(record.calls[1].args[3]),
      tostring(mapping.play_sound_pitch(45))))
  end)

  it("4. a far key clamps to 0.5 and warns ONCE while still making later calls", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local far = {
      kind = "play_sound",
      name = "minecraft:block.note_block.trumpet",
      key = 20,
      volume = 1,
    }

    local first = d:event(far, record)

    expect.equal(#record.calls, 1)
    expect.equal(record.calls[1].args[3], mapping.play_sound_pitch(20))
    expect.equal(record.calls[1].args[3], 0.5)
    expect.equal(first.warning_code, dispatch.WARN_PLAY_SOUND_PITCH)

    -- A SECOND far-key event still makes its call but does not warn again.
    local second = d:event(far, record)

    expect.equal(#record.calls, 2)
    expect.equal(second.called, true)
    expect.equal(second.warning_code, nil)
    expect.sequence_equal(d:warnings(), { dispatch.WARN_PLAY_SOUND_PITCH })

    io.write(string.format(
      "    CASE-4 clamped ratio=%s first_warning=%s second_warning=%s\n",
      tostring(record.calls[1].args[3]), tostring(first.warning_code),
      tostring(second.warning_code)))
  end)
end)

-- ---------------------------------------------------------------------------
-- 5-8. custom refusal + once-only ledger
-- ---------------------------------------------------------------------------

describe("dispatch custom refusal and warning ledger", function()
  it("5. a custom event refuses: zero calls, called=false, method=nil, warns once", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local result = d:event({ kind = "custom", custom_index = 3 }, record)

    expect.equal(#record.calls, 0) -- NEVER pass a custom name to play_sound
    expect.equal(result.called, false)
    expect.equal(result.method, nil)
    expect.equal(result.warning_code, dispatch.WARN_CUSTOM_INSTRUMENT)
  end)

  it("6. three custom events: zero calls and the warning is emitted exactly once", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local first = d:event({ kind = "custom", custom_index = 0 }, record)
    local second = d:event({ kind = "custom", custom_index = 1 }, record)
    local third = d:event({ kind = "custom", custom_index = 2 }, record)

    expect.equal(#record.calls, 0)
    expect.equal(first.warning_code, dispatch.WARN_CUSTOM_INSTRUMENT)
    expect.equal(second.warning_code, nil)
    expect.equal(third.warning_code, nil)

    local warnings = d:warnings()
    expect.equal(#warnings, 1)
    expect.equal(warnings[1], dispatch.WARN_CUSTOM_INSTRUMENT)

    io.write(string.format(
      "    CASE-6 custom x3 warnings={%s} codes={%s,%s,%s}\n",
      table.concat(warnings, ","), tostring(first.warning_code),
      tostring(second.warning_code), tostring(third.warning_code)))
  end)

  it("7. warnings() preserves EMISSION ORDER across different codes", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    d:event({ kind = "play_sound", name = "minecraft:block.note_block.trumpet",
      key = 20 }, record)
    d:event({ kind = "custom", custom_index = 0 }, record)

    expect.sequence_equal(d:warnings(),
      { dispatch.WARN_PLAY_SOUND_PITCH, dispatch.WARN_CUSTOM_INSTRUMENT })
  end)

  it("8. reset() clears the ledger so a fresh playback can warn again", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    d:event({ kind = "custom", custom_index = 0 }, record)
    expect.equal(#d:warnings(), 1)

    d:reset()
    expect.sequence_equal(d:warnings(), {})

    local after_reset = d:event({ kind = "custom", custom_index = 0 }, record)
    expect.equal(after_reset.warning_code, dispatch.WARN_CUSTOM_INSTRUMENT)
    expect.equal(#d:warnings(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. a refusal is forwarded, NOT an error
-- ---------------------------------------------------------------------------

describe("dispatch forwards refusals", function()
  it("9. a speaker returning false sets refused=true, called=true, no error field", function()
    local d = dispatch.new()
    local record = refusing_mock("left")

    local result = d:event(play_note_event(), record)

    -- The call WAS made...
    expect.equal(#record.calls, 1)
    expect.equal(result.called, true)
    expect.equal(result.method, "play_note")
    -- ...and the refusal is surfaced as refused, distinctly from an error.
    expect.equal(result.refused, true)
    expect.equal(result.error_message, nil)

    io.write(string.format(
      "    CASE-9 refusal: called=%s refused=%s error_message=%s\n",
      tostring(result.called), tostring(result.refused),
      tostring(result.error_message)))
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. a raising speaker is contained (error, not refusal)
-- ---------------------------------------------------------------------------

describe("dispatch contains a raising speaker", function()
  it("10. a raising play_note does not propagate; a later healthy call still works", function()
    local d = dispatch.new()
    local record = speaker.mock("left")
    record.play_note = function(self, name, volume, pitch)
      error("boom-speaker", 0)
    end

    local ok, result = pcall(function()
      return d:event(play_note_event(), record)
    end)

    expect.truthy(ok)                       -- the raise did NOT propagate
    expect.equal(result.called, false)
    expect.equal(result.error_message ~= nil, true)
    expect.contains(result.error_message, "boom-speaker")
    -- Distinguishable from a refusal: an error is NOT a refusal.
    expect.truthy(result.refused ~= true)

    -- The dispatcher is not poisoned: a healthy speaker afterwards works.
    local healthy = speaker.mock("right")
    local next_result = d:event(play_note_event(), healthy)
    expect.equal(next_result.called, true)
    expect.equal(next_result.method, "play_note")
    expect.equal(#healthy.calls, 1)

    io.write(string.format(
      "    CASE-10 raising speaker: called=%s refused=%s error_message=%s\n",
      tostring(result.called), tostring(result.refused),
      tostring(result.error_message)))
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. hostile inputs NEVER raise
-- ---------------------------------------------------------------------------

describe("dispatch never raises on hostile input", function()
  it("11. sweep nil / non-table / empty / unknown / missing fields / nil speaker", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    local probes = {
      nil,
      42,
      "not-an-event",
      {},
      { kind = "bogus" },
      { kind = "play_note" },              -- no name
      { kind = "custom" },                 -- no index
      { kind = "play_sound" },             -- no name / key
    }

    for index = 1, #probes do
      local ok, result = pcall(function()
        return d:event(probes[index], record)
      end)
      expect.truthy(ok)
      expect.equal(type(result), "table")
      expect.equal(result.called, false)
    end

    -- A valid event but a nil speaker: still no raise, still no call.
    local ok_nil_speaker, nil_speaker_result = pcall(function()
      return d:event(play_note_event(), nil)
    end)
    expect.truthy(ok_nil_speaker)
    expect.equal(type(nil_speaker_result), "table")
    expect.equal(nil_speaker_result.called, false)

    -- A speaker whose method is absent: no raise, no call.
    local ok_missing, missing_result = pcall(function()
      return d:event(play_note_event(), { side = "left" })
    end)
    expect.truthy(ok_missing)
    expect.equal(type(missing_result), "table")
    expect.equal(missing_result.called, false)

    io.write("    CASE-11 hostile sweep: all returned tables, none raised\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. no re-resolution: dispatch must not touch the instrument resolver or the
--     volume mapping (plan.lua already did that)
-- ---------------------------------------------------------------------------

describe("dispatch does not re-resolve instruments or volumes", function()
  it("12. raising mapping.speaker_volume / instrument_table.resolve is never called", function()
    local d = dispatch.new()
    local record = speaker.mock("left")

    saved_speaker_volume = mapping.speaker_volume
    saved_resolve = instrument_table.resolve
    mapping.speaker_volume = function()
      error("dispatch must not call mapping.speaker_volume", 0)
    end
    instrument_table.resolve = function()
      error("dispatch must not call instrument_table.resolve", 0)
    end

    local ok, result = pcall(function()
      return d:event(play_note_event(), record)
    end)

    -- Restore immediately (after_each also does this defensively).
    mapping.speaker_volume = saved_speaker_volume
    instrument_table.resolve = saved_resolve
    saved_speaker_volume = nil
    saved_resolve = nil

    expect.truthy(ok)
    expect.equal(result.called, true)
    expect.equal(result.method, "play_note")
    expect.deep_equal(record.calls[1].args, { "harp", 2, 12 })

    io.write("    CASE-12 no re-resolution: play_note succeeded with both stubs raising\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. the speaker's side is reported
-- ---------------------------------------------------------------------------

describe("dispatch reports the speaker side", function()
  it("13. result.speaker_side equals the mock record's side", function()
    local d = dispatch.new()
    local record = speaker.mock("back")

    local result = d:event(play_note_event(), record)

    expect.equal(result.speaker_side, "back")
    expect.equal(result.speaker_side, record.side)

    io.write(string.format("    CASE-13 speaker_side=%s\n",
      tostring(result.speaker_side)))
  end)
end)
