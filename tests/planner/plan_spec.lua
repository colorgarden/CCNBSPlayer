-- tests/planner/plan_spec.lua
--
-- Tier-1 spec for player/plan.lua -- the DETERMINISM ANCHOR of the player.
--
-- FROZEN PUBLIC INTERFACE UNDER TEST
-- ----------------------------------
--   local plan = require("player.plan")
--   plan.plan(song, analysis) -> <array of events>     -- pure: no clock, no I/O
--
-- Each event uses EXACTLY these keys:
--   t_ms          number   tick * analysis.tick_ms (derived, never accumulated)
--   tick_index    integer  the note's tick
--   layer_index   integer  the note's layer (0-based)
--   note_index    integer  1-based index WITHIN its (tick, layer) group
--   instrument    integer  the raw NBS instrument id
--   key           integer
--   kind          "play_note" | "play_sound" | "custom"
--   name          string | nil  (nil exactly when kind == "custom")
--   custom_index  integer | nil (integer exactly when kind == "custom")
--   volume        number   0..3
--   pitch         integer  semitones, UNCLAMPED
--   pitch_cents   number   cents residual
--   layer_volume  integer  source layer volume (default 100 when missing)
--
-- THE FROZEN TOTAL ORDER (the whole point of this spec)
-- -----------------------------------------------------
-- Events sort ascending by the tuple (tick_index, layer_index, note_index).
-- There is NO other tiebreaker.  The Tier-2 integration strategy asserts on this
-- ordered sequence of speaker calls, so any dependence on input array order, on
-- a hash-table iteration order (`pairs`), or on the clock would make those
-- integration tests flaky.  Case 3 below (shuffled input -> identical output) is
-- the assertion that catches a missing sort; case 1 catches a hidden clock.
--
-- `note_index` is per (tick, layer) group and resets to 1 for each new group.
-- The module documents which construction approach it uses; this spec only
-- pins the observable result.
--
-- Fixture loading mirrors tests/nbs/analyze_spec.lua.

local plan = require("player.plan")
local decode = require("nbs.decode")
local analyze = require("nbs.analyze")

-- ---------------------------------------------------------------------------
-- Project root + fixture helpers (same convention as analyze_spec.lua)
-- ---------------------------------------------------------------------------

local function project_root()
  local first = package.path:match("^(.-)/%?%.lua")
  if first == nil or first == "" then
    return "."
  end
  return first
end

local ROOT = project_root()

local function join(root, rel)
  if root == "." or root == "" then
    return rel
  end
  return root .. "/" .. rel
end

local FIXTURES_DIR = join(ROOT, "tests/fixtures")

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a") or ""
  handle:close()
  return data
end

local function list_fixtures(dir)
  local is_windows = package.config:sub(1, 1) == "\\"
  local command
  if is_windows then
    command = 'dir /b "' .. dir:gsub("/", "\\") .. '" 2>nul'
  else
    command = 'ls -1 "' .. dir .. '" 2>/dev/null'
  end
  local names = {}
  local pipe = io.popen(command)
  if not pipe then
    return names
  end
  local output = pipe:read("*a") or ""
  pipe:close()
  for line in output:gmatch("[^\r\n]+") do
    local name = line:gsub("%s+$", "")
    if name:match("%.nbs$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- ---------------------------------------------------------------------------
-- Synthetic builders.  Field names mirror nbs.decode exactly.
-- ---------------------------------------------------------------------------

-- n(tick, layer, instrument, key, velocity, pitch_cents)
local function n(tick, layer, instrument, key, velocity, pitch_cents)
  return {
    tick = tick,
    layer = layer,
    instrument = instrument,
    key = key,
    velocity = velocity or 100,
    panning = 100,
    pitch = pitch_cents or 0,
  }
end

-- song(opts) -> a decoded-shaped song.  `layers` is the 1-based layer array
-- (layer_index 0 reads layers[1]).  Header carries the vanilla-instrument count.
local function song(opts)
  opts = opts or {}
  return {
    header = {
      vanilla_instrument_count = opts.vic or 16,
      tempo_ticks_per_second = opts.tps or 10,
    },
    layers = opts.layers or {},
    notes = opts.notes or {},
    custom_instruments = {},
    song_length = 0,
    song_length_source = "empty",
  }
end

-- analysis(tick_ms) -> the analysis-shaped input (plan reads tick_ms).
local function analysis(tick_ms)
  return {
    tick_ms = tick_ms,
    ticks_per_second = 1000 / tick_ms,
  }
end

local function layer(volume)
  return { name = "", lock = 0, volume = volume, panning = 100 }
end

-- ---------------------------------------------------------------------------
-- Stable serialiser: a FIXED field order joined with separators.  Deliberately
-- independent of table iteration order, so two plans are byte-identical iff
-- their events match field for field in the same sequence.
-- ---------------------------------------------------------------------------

local FIELD_ORDER = {
  "t_ms", "tick_index", "layer_index", "note_index", "instrument", "key",
  "kind", "name", "custom_index", "volume", "pitch", "pitch_cents",
  "layer_volume",
}

local function serialize(events)
  local lines = {}
  for _, event in ipairs(events) do
    local parts = {}
    for _, field in ipairs(FIELD_ORDER) do
      parts[#parts + 1] = field .. "=" .. tostring(event[field])
    end
    lines[#lines + 1] = table.concat(parts, ",")
  end
  return table.concat(lines, "|")
end

-- frozen-order comparison: true when a <= b in (tick, layer, note) order.
local function leq(a, b)
  if a.tick_index ~= b.tick_index then
    return a.tick_index < b.tick_index
  end
  if a.layer_index ~= b.layer_index then
    return a.layer_index < b.layer_index
  end
  return a.note_index <= b.note_index
end

local function is_finite(value)
  if type(value) ~= "number" then
    return false
  end
  if value ~= value then
    return false
  end
  return value ~= math.huge and value ~= -math.huge
end

-- A mixed song used by several cases below.
local function mixed_song()
  return song({
    vic = 20,
    layers = { layer(100), layer(50), layer(100) },
    notes = {
      n(4, 2, 1, 50, 100, 0),
      n(0, 0, 0, 45, 100, 0),
      n(4, 0, 16, 40, 80, 12),
      n(0, 1, 5, 33, 100, 0),
      n(4, 0, 21, 60, 100, -25),
      n(0, 0, 2, 57, 100, 0),
    },
  })
end

-- ---------------------------------------------------------------------------
-- 1. Determinism across 10 runs
-- ---------------------------------------------------------------------------

describe("player.plan determinism", function()
  it("1. ten runs on the same song serialise byte-identically", function()
    local subject = mixed_song()
    local first = serialize(plan.plan(subject, analysis(100)))
    expect.truthy(#first > 0)
    for _ = 1, 10 do
      expect.equal(serialize(plan.plan(subject, analysis(100))), first)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. Total order
-- ---------------------------------------------------------------------------

describe("player.plan frozen total order", function()
  it("2. emits (0,0), (0,1), (1,0) in that order", function()
    local events = plan.plan(song({
      notes = {
        n(1, 0, 0, 45),
        n(0, 0, 0, 45),
        n(0, 1, 0, 45),
      },
    }), analysis(100))

    local pairs_seen = {}
    for _, event in ipairs(events) do
      pairs_seen[#pairs_seen + 1] = { event.tick_index, event.layer_index }
    end

    expect.sequence_equal(pairs_seen, { { 0, 0 }, { 0, 1 }, { 1, 0 } })

    io.write("    CASE2 total-order (tick,layer)=")
    for _, pair in ipairs(pairs_seen) do
      io.write(string.format("(%d,%d) ", pair[1], pair[2]))
    end
    io.write("\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. Input order independence
-- ---------------------------------------------------------------------------

describe("player.plan input order independence", function()
  it("3. a shuffled note array yields output identical to the sorted-input run", function()
    -- Each note sits in its OWN (tick, layer) group so the frozen tuple
    -- identifies it uniquely.  (Two notes in one group are indistinguishable by
    -- the frozen order -- note_index is documented to follow input order there --
    -- so they are deliberately not used here.)  A missing sort would emit these
    -- in `shuffled_notes` order and fail this assertion.
    local ordered_notes = {
      n(0, 0, 0, 45, 100, 0),
      n(0, 1, 5, 40, 100, 25),
      n(1, 0, 3, 60, 100, 0),
      n(2, 0, 16, 50, 100, 0),
      n(2, 3, 21, 33, 70, -50),
      n(3, 2, 1, 40, 100, 0),
    }
    local shuffled_notes = {
      ordered_notes[5], ordered_notes[2], ordered_notes[6],
      ordered_notes[3], ordered_notes[1], ordered_notes[4],
    }

    local vic = 20
    local layers = { layer(100), layer(80), layer(100), layer(60) }

    local sorted_run = plan.plan(song({
      vic = vic, layers = layers, notes = ordered_notes,
    }), analysis(100))
    local shuffled_run = plan.plan(song({
      vic = vic, layers = layers, notes = shuffled_notes,
    }), analysis(100))

    expect.equal(serialize(shuffled_run), serialize(sorted_run))
    expect.truthy(#sorted_run == 6)

    io.write("    CASE3 shuffled-identical length=" .. #shuffled_run
      .. " hash=" .. tostring(#serialize(shuffled_run)) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. note_index resets per (tick, layer) group
-- ---------------------------------------------------------------------------

describe("player.plan note_index grouping", function()
  it("4. two notes at (0,0) then one at (0,1) yield note_index 1, 2, 1", function()
    local events = plan.plan(song({
      notes = {
        n(0, 0, 0, 45),
        n(0, 0, 1, 50),
        n(0, 1, 2, 55),
      },
    }), analysis(100))

    expect.equal(events[1].note_index, 1)
    expect.equal(events[2].note_index, 2)
    expect.equal(events[3].note_index, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. t_ms derivation
-- ---------------------------------------------------------------------------

describe("player.plan t_ms derivation", function()
  it("5. at 10 ticks/second tick 5 -> 500 ms and tick 0 -> 0 ms", function()
    local events = plan.plan(song({
      notes = { n(0, 0, 0, 45), n(5, 0, 0, 45) },
    }), analysis(100))

    expect.equal(events[1].t_ms, 0)
    expect.equal(events[2].t_ms, 500)
  end)
end)

-- ---------------------------------------------------------------------------
-- 6. No cumulative rounding: t_ms is derived, never accumulated
-- ---------------------------------------------------------------------------

describe("player.plan non-cumulative timing", function()
  it("6. with a repeating tick_ms, t_ms equals N * tick_ms exactly", function()
    local tick_ms = 1000 / 3
    local a = analysis(tick_ms)

    for tick = 0, 30 do
      local events = plan.plan(song({ notes = { n(tick, 0, 0, 45) } }), a)
      expect.equal(events[1].t_ms, tick * tick_ms)
    end

    -- Explicitly re-state the anchor that accumulation would miss.
    local far = plan.plan(song({ notes = { n(30, 0, 0, 45) } }), a)
    expect.equal(far[1].t_ms, 30 * tick_ms)
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. kind routing through nbs/instrument_table (end-to-end)
-- ---------------------------------------------------------------------------

describe("player.plan instrument kind routing", function()
  it("7. id 0 -> play_note harp; v6 id 16 -> play_sound trumpet; v5 id 16 -> custom 0", function()
    local vanilla = plan.plan(song({
      vic = 20,
      notes = { n(0, 0, 0, 45) },
    }), analysis(100))[1]
    expect.equal(vanilla.kind, "play_note")
    expect.equal(vanilla.name, "harp")
    expect.equal(vanilla.custom_index, nil)

    local trumpet = plan.plan(song({
      vic = 20,
      notes = { n(0, 0, 16, 45) },
    }), analysis(100))[1]
    expect.equal(trumpet.kind, "play_sound")
    expect.equal(trumpet.name, "minecraft:block.note_block.trumpet")
    expect.equal(trumpet.custom_index, nil)

    local custom = plan.plan(song({
      vic = 16,
      notes = { n(0, 0, 16, 45) },
    }), analysis(100))[1]
    expect.equal(custom.kind, "custom")
    expect.equal(custom.name, nil)
    expect.equal(custom.custom_index, 0)

    io.write(string.format(
      "    CASE7 routing id0=%s/%s id16@vic20=%s/%s id16@vic16=%s/%s(custom_index=%s)\n",
      vanilla.kind, tostring(vanilla.name),
      trumpet.kind, tostring(trumpet.name),
      custom.kind, tostring(custom.name), tostring(custom.custom_index)))
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. Custom notes are EMITTED, not dropped
-- ---------------------------------------------------------------------------

describe("player.plan custom notes are emitted", function()
  it("8. a custom-only song plans one event per note, all kind custom", function()
    local events = plan.plan(song({
      vic = 16,
      notes = { n(0, 0, 16, 45), n(1, 0, 17, 50), n(2, 0, 20, 55) },
    }), analysis(100))

    expect.equal(#events, 3)
    for _, event in ipairs(events) do
      expect.equal(event.kind, "custom")
      expect.equal(event.name, nil)
      expect.equal(type(event.custom_index), "number")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. Volume composition (combined_volume then speaker_volume)
-- ---------------------------------------------------------------------------

describe("player.plan volume composition", function()
  it("9. layer 50 x velocity 100 -> combined 50 -> speaker volume 2", function()
    local events = plan.plan(song({
      layers = { layer(50) },
      notes = { n(0, 0, 0, 45, 100) },
    }), analysis(100))

    expect.equal(events[1].layer_volume, 50)
    expect.equal(events[1].volume, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. Missing layer defaults to 100 and still emits
-- ---------------------------------------------------------------------------

describe("player.plan missing layer", function()
  it("10. a note past the decoded layer list emits with layer_volume 100 and no raise", function()
    local called, events = pcall(plan.plan, song({
      layers = { layer(50) },
      notes = { n(0, 5, 0, 45, 100) },
    }), analysis(100))

    expect.truthy(called)
    expect.equal(#events, 1)
    expect.equal(events[1].layer_volume, 100)
    expect.equal(type(events[1].volume), "number")
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. Pitch is UNCLAMPED in the plan
-- ---------------------------------------------------------------------------

describe("player.plan unclamped pitch", function()
  it("11. key 20 -> semitone -13 (not clamped to 0)", function()
    local events = plan.plan(song({
      notes = { n(0, 0, 0, 20) },
    }), analysis(100))

    expect.equal(events[1].pitch, -13)
    expect.truthy(events[1].pitch ~= 0)

    io.write("    CASE11 key=20 pitch=" .. tostring(events[1].pitch) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. pitch_cents is the raw residual
-- ---------------------------------------------------------------------------

describe("player.plan pitch_cents residual", function()
  it("12. note pitch 50 -> pitch_cents 0.5, independent of the integer pitch", function()
    local events = plan.plan(song({
      notes = { n(0, 0, 0, 45, 100, 50) },
    }), analysis(100))

    expect.equal(events[1].pitch_cents, 0.5)
    expect.equal(events[1].pitch, 12)
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. Empty song
-- ---------------------------------------------------------------------------

describe("player.plan empty song", function()
  it("13. zero notes -> empty array, no raise", function()
    local called, events = pcall(plan.plan, song({ notes = {} }), analysis(100))
    expect.truthy(called)
    expect.equal(type(events), "table")
    expect.equal(#events, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 14. Purity / non-mutation of the input
-- ---------------------------------------------------------------------------

describe("player.plan purity", function()
  it("14. plan does not mutate song.notes", function()
    local subject = song({
      layers = { layer(50) },
      notes = { n(0, 0, 0, 45), n(3, 1, 16, 40, 90, 25) },
    })

    -- Capture each field explicitly (no `pairs`) and the array length.
    local first = subject.notes[1]
    local before_tick = first.tick
    local before_layer = first.layer
    local before_instrument = first.instrument
    local before_key = first.key
    local before_velocity = first.velocity
    local before_panning = first.panning
    local before_pitch = first.pitch
    local before_len = #subject.notes

    plan.plan(subject, analysis(100))

    expect.equal(#subject.notes, before_len)
    expect.equal(first.tick, before_tick)
    expect.equal(first.layer, before_layer)
    expect.equal(first.instrument, before_instrument)
    expect.equal(first.key, before_key)
    expect.equal(first.velocity, before_velocity)
    expect.equal(first.panning, before_panning)
    expect.equal(first.pitch, before_pitch)
  end)
end)

-- ---------------------------------------------------------------------------
-- 15. Real fixtures
-- ---------------------------------------------------------------------------

describe("player.plan real fixtures", function()
  it("15. every .nbs plans fully, finitely and in non-decreasing frozen order", function()
    local names = list_fixtures(FIXTURES_DIR)
    expect.truthy(#names >= 10)

    local rows = {}
    for _, name in ipairs(names) do
      local bytes = read_file(join(FIXTURES_DIR, name))
      expect.truthy(bytes ~= nil)

      local called, result = pcall(function()
        local decoded = decode.decode(bytes)
        expect.equal(decoded.ok, true)
        local analysed = analyze.analyze(decoded.song)
        local planned = plan.plan(decoded.song, analysed)
        return { decoded = decoded, planned = planned }
      end)
      expect.truthy(called)

      local decoded = result.decoded
      local planned = result.planned

      -- Length equals the note count (custom notes included, nothing dropped).
      expect.equal(#planned, #decoded.song.notes)

      local previous = nil
      for _, event in ipairs(planned) do
        expect.truthy(is_finite(event.t_ms))
        if previous ~= nil then
          expect.truthy(leq(previous, event))
        end
        previous = event
      end

      rows[#rows + 1] = string.format(
        "    FIXTURE %-28s v=%-2s notes=%-4d plan=%-4d",
        name, tostring(decoded.song.header.version),
        #decoded.song.notes, #planned)
    end

    for _, row in ipairs(rows) do
      io.write(row .. "\n")
    end
  end)
end)
