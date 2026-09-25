-- tests/tier2/assert_spec.lua
--
-- PURE-LUA UNIT TESTS for tests/tier2/assert_order.lua -- the Tier-2 PROJECTION
-- and COMPARISON logic.  These run under `lua tests/run.lua` (Lua 5.2) and need
-- NO emulator: they test the comparator and the projector directly.
--
-- WHAT IS UNDER TEST
--   assert_order.format_number(value)        -- mirrors record.lua's arg format
--   assert_order.format_call(side, method,..) -- one "CALL ..." line
--   assert_order.project(events, analysis, sides)
--   assert_order.expect(bytes, sides)
--   assert_order.parse_recorded(text)
--   assert_order.compare(expected_calls, recorded_text)
--
-- TDD NOTE: this file was written BEFORE assert_order.lua existed, so the first
-- run fails (the module is missing).  See the evidence file for the literal
-- failing-first transcript and the later green run.
--
-- Cobalt / Lua 5.2 subset: no `//`, no bitwise operators, no utf8.*, no goto,
-- no os.exit.  Only `io.open` is used, to read a real fixture as bytes.

local assert_order = require("tests.tier2.assert_order")
local mapping = require("player.mapping")

-- ---------------------------------------------------------------------------
-- Helpers: build synthetic plan events (no decode needed)
-- ---------------------------------------------------------------------------

-- base(overrides) -> a fully-shaped plan event with sane defaults.  Every field
-- player/plan.lua promises is present so the real fanout/dispatch accept it.
local function base(overrides)
  local event = {
    t_ms = 0,
    tick_index = 0,
    layer_index = 0,
    note_index = 1,
    instrument = 0,
    key = 45,
    kind = "play_note",
    name = "harp",
    custom_index = nil,
    volume = 3,
    pitch = 12,
    pitch_cents = 0,
    layer_volume = 100,
  }
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      event[key] = value
    end
  end
  return event
end

-- A minimal analyze() result: enough for fanout.assign to compute required_count.
local function analysis(overrides)
  local result = {
    tick_ms = 100,
    ticks_per_second = 10,
    peak_concurrent = 0,
    peak_window_ms = 50,
    vanilla_notes_at_peak = 0,
    play_sound_notes_at_peak = 0,
    has_extended_range = false,
    min_key = 0,
    max_key = 0,
  }
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      result[key] = value
    end
  end
  return result
end

-- lines(...) -> a "\n"-joined recorded-text body.
local function lines(...)
  local parts = { ... }
  return table.concat(parts, "\n")
end

local function read_bytes(path)
  local handle = io.open(path, "rb")
  if handle == nil then
    return nil
  end
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

-- ---------------------------------------------------------------------------
-- format_number / format_call: the byte-for-byte mirror of record.lua
-- ---------------------------------------------------------------------------

describe("assert_order.format_number", function()
  it("renders an integral float without a decimal point", function()
    expect.equal(assert_order.format_number(1.0), "1")
  end)

  it("renders an integer unchanged", function()
    expect.equal(assert_order.format_number(3), "3")
  end)

  it("renders a non-integer with six decimal places", function()
    expect.equal(assert_order.format_number(1.5), "1.500000")
  end)

  it("renders a playSound ratio with six decimals", function()
    expect.equal(
      assert_order.format_number(2 ^ (2 / 12)), "1.122462")
  end)

  it("renders a string argument verbatim", function()
    expect.equal(assert_order.format_number("harp"), "harp")
  end)
end)

describe("assert_order.format_call", function()
  it("builds a CALL line with integer arguments", function()
    expect.equal(
      assert_order.format_call("back", "playNote", "harp", 3, 12),
      "CALL back playNote harp 3 12")
  end)
end)

-- ---------------------------------------------------------------------------
-- compare: EXACT ordered comparison of the performance calls
-- ---------------------------------------------------------------------------

describe("assert_order.compare", function()
  local expected = {
    "CALL back playNote harp 3 12",
    "CALL back playNote bass 3 5",
    "CALL back playNote bell 3 7",
  }

  it("reports ok for an identical sequence", function()
    local recorded = lines(
      "CALL back playNote harp 3 12",
      "CALL back playNote bass 3 5",
      "CALL back playNote bell 3 7",
      "STATUS ok")
    local result = assert_order.compare(expected, recorded)
    expect.truthy(result.ok)
    expect.equal(result.expected_count, 3)
    expect.equal(result.actual_count, 3)
    expect.equal(result.first_diff, nil)
  end)

  it("reports the FIRST differing index for a swapped adjacent line", function()
    local recorded = lines(
      "CALL back playNote harp 3 12",
      "CALL back playNote bell 3 7",
      "CALL back playNote bass 3 5",
      "STATUS ok")
    local result = assert_order.compare(expected, recorded)
    expect.falsy(result.ok)
    expect.equal(result.first_diff, 2)
    expect.equal(result.expected, "CALL back playNote bass 3 5")
    expect.equal(result.actual, "CALL back playNote bell 3 7")
  end)

  it("reports a count mismatch for a shortened list", function()
    local recorded = lines(
      "CALL back playNote harp 3 12",
      "CALL back playNote bass 3 5",
      "STATUS ok")
    local result = assert_order.compare(expected, recorded)
    expect.falsy(result.ok)
    expect.equal(result.expected_count, 3)
    expect.equal(result.actual_count, 2)
    expect.equal(result.first_diff, 3)
    expect.equal(result.expected, "CALL back playNote bell 3 7")
    expect.equal(result.actual, nil)
  end)

  it("reports failure with an empty recorded text", function()
    local result = assert_order.compare(expected, "")
    expect.falsy(result.ok)
    expect.equal(result.actual_count, 0)
    expect.equal(result.first_diff, 1)
  end)

  it("ignores the three setup lines (getNames/getType/wrap)", function()
    local one_expected = { "CALL back playNote harp 3 12" }
    local recorded = lines(
      "CALL - getNames",
      "CALL back getType",
      "CALL back wrap",
      "CALL back playNote harp 3 12",
      "STATUS ok")
    local result = assert_order.compare(one_expected, recorded)
    expect.truthy(result.ok)
    expect.equal(result.actual_count, 1)
  end)

  it("tolerates CRLF line endings", function()
    local recorded = "CALL back playNote harp 3 12\r\nSTATUS ok\r\n"
    local result = assert_order.compare({ "CALL back playNote harp 3 12" }, recorded)
    expect.truthy(result.ok)
  end)
end)

-- ---------------------------------------------------------------------------
-- parse_recorded
-- ---------------------------------------------------------------------------

describe("assert_order.parse_recorded", function()
  it("splits CALL lines from the STATUS line, dropping setup calls", function()
    local recorded = lines(
      "CALL - getNames",
      "CALL back getType",
      "CALL back wrap",
      "CALL back playNote harp 3 12",
      "CALL back stop",
      "STATUS ok")
    local parsed = assert_order.parse_recorded(recorded)
    expect.equal(#parsed.calls, 2)
    expect.equal(parsed.calls[1], "CALL back playNote harp 3 12")
    expect.equal(parsed.calls[2], "CALL back stop")
    expect.equal(parsed.status, "STATUS ok")
  end)

  it("returns no calls and a nil status for empty text", function()
    local parsed = assert_order.parse_recorded("")
    expect.equal(#parsed.calls, 0)
    expect.equal(parsed.status, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- project: the routing mirror
-- ---------------------------------------------------------------------------

describe("assert_order.project", function()
  it("emits no call at all for a custom-instrument event", function()
    local events = { base({ kind = "custom", name = nil, custom_index = 0 }) }
    local projected = assert_order.project(events, analysis(), { "back" })
    expect.equal(#projected.calls, 0)
  end)

  it("emits a playNote call for a play_note event", function()
    local events = { base({}) }
    local projected = assert_order.project(events, analysis(
      { vanilla_notes_at_peak = 1 }), { "back" })
    expect.equal(#projected.calls, 1)
    expect.equal(projected.calls[1], "CALL back playNote harp 3 12")
  end)

  it("emits a playSound RATIO (not the semitone) for a play_sound event", function()
    local events = { base({
      kind = "play_sound",
      name = "minecraft:block.note_block.trumpet",
      key = 47,
      pitch = 14,
      volume = 1,
    }) }
    local projected = assert_order.project(events, analysis(
      { play_sound_notes_at_peak = 1 }), { "back" })
    expect.equal(#projected.calls, 1)
    expect.equal(projected.calls[1],
      "CALL back playSound minecraft:block.note_block.trumpet 1 "
        .. assert_order.format_number(mapping.play_sound_pitch(47)))
    expect.contains(projected.calls[1], "1.122462")
    -- The semitone (key - 33 = 14) must NOT appear as the pitch argument.
    expect.falsy(string.find(projected.calls[1], " 14", 1, true))
  end)

  it("honours the fan-out assignment across two speakers", function()
    local events = {
      base({ t_ms = 0, tick_index = 0, note_index = 1 }),
      base({ t_ms = 0, tick_index = 0, note_index = 2 }),
    }
    local projected = assert_order.project(events, analysis(
      { vanilla_notes_at_peak = 2 }), { "a", "b" })
    expect.equal(#projected.calls, 2)
    expect.equal(projected.calls[1], "CALL a playNote harp 3 12")
    expect.equal(projected.calls[2], "CALL b playNote harp 3 12")
  end)
end)

-- ---------------------------------------------------------------------------
-- expect: decode -> analyze -> plan -> fanout -> projection, on a REAL fixture
-- ---------------------------------------------------------------------------

describe("assert_order.expect", function()
  it("projects tests/fixtures/v4.nbs to five in-range playNote calls", function()
    local bytes = read_bytes("tests/fixtures/v4.nbs")
    if bytes == nil then
      expect.fail("tests/fixtures/v4.nbs is missing from the working tree")
    end
    local projected = assert_order.expect(bytes, { "back" })
    expect.equal(#projected.calls, 5)
    expect.equal(projected.calls[1], "CALL back playNote harp 3 12")
    expect.equal(projected.assignment.found, 1)
    expect.equal(projected.analysis.has_extended_range, false)
  end)
end)
