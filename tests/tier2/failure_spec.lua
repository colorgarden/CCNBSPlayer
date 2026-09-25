-- tests/tier2/failure_spec.lua
--
-- TIER-2 FAILURE / EDGE-CASE SPECS -- the PROJECTOR-level half.
--
-- These run under `lua tests/run.lua` with NO emulator: they drive the REAL
-- production modules (nbs.decode / nbs.analyze / player.plan / player.fanout /
-- player.dispatch / player.warnings) through tests/tier2/assert_order.lua and
-- assert the edge behaviour there.  The companion host-driven emulator spec is
-- tests/tier2/edge_cases.ps1, which runs the SAME fixtures through CraftOS-PC;
-- where a case can only be asserted without the emulator it is stated in the
-- test name and in the evidence file.
--
-- THE FIVE CASES (see tests/tier2/README.md)
--   1. capacity_10.nbs + TWO speakers  -> balanced least-loaded split, dropped 0
--   2. capacity_10.nbs + ONE  speaker  -> deterministic drop + "speakers" warning
--   3. tests/corpus/malformed/*        -> typed decode codes, no raise
--   4. simple.nbs                      -> extended-range warning EXACTLY ONCE
--      compat_demo_song.nbs            -> in-range, ZERO extended-range warning
--   5. custom_mix.nbs                  -> custom notes make ZERO calls, one
--                                         WARN[custom-instrument], vanilla plays
--
-- WHY simple.nbs IS SAFE HERE (and unsafe on the emulator)
--   simple.nbs has min_key 27, so it genuinely carries has_extended_range ==
--   true and is the right fixture for the projector-level warning assertion.
--   It is NOT played on the emulator: CraftOS-PC's emulated speaker RAISES for
--   any playNote pitch outside 0..24 (docs/COMPAT.md), and key 27 -> pitch -6.
--   The emulator half of case 4 therefore uses an in-range fixture and asserts
--   ZERO extended-range warnings; see edge_cases.ps1.
--
-- Cobalt / Lua 5.2 subset: no `//`, no bitwise operators, no utf8.*, no goto,
-- no os.exit.  io.open is used only to read fixture bytes.

local assert_order = require("tests.tier2.assert_order")
local decode = require("nbs.decode")
local warnings = require("player.warnings")

local TIER2_DIR = "tests/tier2"
local FIXTURES = TIER2_DIR .. "/fixtures"
local MALFORMED = "tests/corpus/malformed"

local function read_bytes(path)
  local handle = io.open(path, "rb")
  if handle == nil then
    return nil
  end
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

-- require_fixture(path): read a committed fixture or fail the test loudly.
local function require_fixture(path)
  local bytes = read_bytes(path)
  if bytes == nil then
    expect.fail("fixture is missing from the working tree: " .. path)
  end
  return bytes
end

-- count_lines_starting_with(lines, prefix) -> integer
local function count_lines_starting_with(lines, prefix)
  local total = 0
  for index = 1, #lines do
    if lines[index]:sub(1, #prefix) == prefix then
      total = total + 1
    end
  end
  return total
end

-- render(ledger) -> array of WARN[...] lines produced by the real renderer.
local function render(ledger, args_by_code)
  local lines = {}
  local w = warnings.new({
    emit = function(line)
      lines[#lines + 1] = line
    end,
  })
  for index = 1, #ledger do
    local code = ledger[index]
    local args = nil
    if type(args_by_code) == "table" then
      args = args_by_code[code]
    end
    w:report(code, args)
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- CASE 1 + 2: capacity_10.nbs, two speakers vs one
-- ---------------------------------------------------------------------------

describe("tier2 failure fixture: capacity_10", function()
  local bytes = require_fixture(FIXTURES .. "/capacity_10.nbs")

  it("is an in-range 10-note / peak-10 fixture (keys 45 only)", function()
    local projected = assert_order.expect(bytes, { "back" })
    expect.equal(projected.analysis.total_notes, 10)
    expect.equal(projected.analysis.min_key, 45)
    expect.equal(projected.analysis.max_key, 45)
    expect.equal(projected.analysis.has_extended_range, false)
    expect.equal(projected.analysis.peak_concurrent, 10)
    expect.equal(projected.analysis.vanilla_notes_at_peak, 10)
  end)

  it("CASE 1: TWO speakers split 10 notes 5/5 with dropped == 0", function()
    local projected = assert_order.expect(bytes, { "back", "left" })

    expect.equal(projected.assignment.required, 2)
    expect.equal(projected.assignment.found, 2)
    expect.equal(projected.assignment.dropped, 0)
    expect.equal(projected.assignment.warning_code, nil)
    expect.equal(projected.assignment.warning_args, nil)

    local back = projected.assignment.by_speaker["back"]
    local left = projected.assignment.by_speaker["left"]
    expect.truthy(back ~= nil)
    expect.truthy(left ~= nil)
    expect.equal(#back, 5)
    expect.equal(#left, 5)
    -- Balanced least-loaded: the two buckets differ by at most one.
    expect.truthy(math.abs(#back - #left) <= 1)

    -- Emitted order follows the frozen (tick, layer, note) walk, alternating
    -- sides because each event goes to the currently least-loaded speaker.
    expect.equal(#projected.calls, 10)
    expect.equal(projected.calls[1], "CALL back playNote harp 3 12")
    expect.equal(projected.calls[2], "CALL left playNote harp 3 12")
    expect.equal(projected.calls[3], "CALL back playNote harp 3 12")
    expect.equal(projected.calls[10], "CALL left playNote harp 3 12")
  end)

  it("CASE 2: ONE speaker drops the deterministic excess with warning args", function()
    local projected = assert_order.expect(bytes, { "back" })

    expect.equal(projected.assignment.required, 2)
    expect.equal(projected.assignment.found, 1)
    expect.equal(projected.assignment.dropped, 2)
    expect.equal(projected.assignment.warning_code, "speakers")
    expect.deep_equal(projected.assignment.warning_args,
      { peak = 10, required = 2, found = 1, dropped = 2 })

    -- The documented drop order loses the LATER (tick, layer, note) events.
    local dropped = projected.assignment.dropped_events
    expect.equal(#dropped, 2)
    expect.equal(dropped[1].tick_index, 0)
    expect.equal(dropped[1].layer_index, 8)
    expect.equal(dropped[1].note_index, 1)
    expect.equal(dropped[2].tick_index, 0)
    expect.equal(dropped[2].layer_index, 9)
    expect.equal(dropped[2].note_index, 1)

    -- The early part of the song survives: layers 0..7 still make their call.
    expect.equal(#projected.calls, 8)
    expect.equal(#projected.assignment.by_speaker["back"], 8)

    -- The warning renderer turns the bare code into ONE WARN[speakers] line
    -- carrying the real {peak, required, found, dropped}.
    local rendered = render({ projected.assignment.warning_code }, {
      speakers = projected.assignment.warning_args,
    })
    expect.equal(#rendered, 1)
    expect.contains(rendered[1], "WARN[speakers]")
    expect.contains(rendered[1], "峰值 10")
    expect.contains(rendered[1], "需要 2")
    expect.contains(rendered[1], "实际 1")
    expect.contains(rendered[1], "已丢弃 2")
  end)
end)

-- ---------------------------------------------------------------------------
-- CASE 3: the malformed corpus -> typed codes, never a raise
-- ---------------------------------------------------------------------------

describe("tier2 malformed corpus decode codes", function()
  -- Every file the generator produces, with the code it must surface.  This is
  -- the SAME table recorded in the evidence file (criterion c).
  local EXPECTED = {
    ["empty.nbs"] = "E_TRUNCATED",
    ["one_byte.nbs"] = "E_TRUNCATED",
    ["truncated_header.nbs"] = "E_TRUNCATED",
    ["version_9.nbs"] = "E_UNSUPPORTED_VERSION",
    ["negative_tick_jump.nbs"] = "E_BAD_JUMP",
    ["layer_overflow.nbs"] = "E_LAYER_OVERFLOW",
    ["absurd_layer_count.nbs"] = "E_BAD_LAYER_COUNT",
    ["negative_layer_count.nbs"] = "E_BAD_LAYER_COUNT",
    ["max_unsigned_layer_count.nbs"] = "E_BAD_LAYER_COUNT",
    ["absurd_instrument_count.nbs"] = "E_BAD_INSTRUMENT_COUNT",
    ["truncated_notes.nbs"] = "E_TRUNCATED",
    ["cyclic_jumps.nbs"] = "E_TOO_MANY_TICKS",
    ["truncated_layers.nbs"] = "E_TRUNCATED",
    ["huge_declared_string.nbs"] = "E_TRUNCATED",
  }

  it("names the four representative files from the task", function()
    -- A guard so the representative subset can never silently disappear.
    expect.equal(EXPECTED["empty.nbs"], "E_TRUNCATED")
    expect.equal(EXPECTED["truncated_header.nbs"], "E_TRUNCATED")
    expect.equal(EXPECTED["version_9.nbs"], "E_UNSUPPORTED_VERSION")
    expect.equal(EXPECTED["negative_tick_jump.nbs"], "E_BAD_JUMP")
  end)

  for name, expected_code in pairs(EXPECTED) do
    it(name .. " decodes to " .. expected_code .. " without raising", function()
      local bytes = read_bytes(MALFORMED .. "/" .. name)
      if bytes == nil then
        expect.fail("malformed corpus file missing: " .. MALFORMED .. "/" .. name)
      end

      -- decode must be TOTAL: pcall returns true and a rejection table.
      local ok, decoded = pcall(decode.decode, bytes)
      expect.truthy(ok)
      expect.equal(type(decoded), "table")
      expect.equal(decoded.ok, false)
      expect.equal(decoded.error.code, expected_code)
      expect.truthy(type(decoded.error.msg) == "string")
      expect.truthy(#decoded.error.msg > 0)
    end)
  end
end)

-- ---------------------------------------------------------------------------
-- CASE 4: extended-range warning, exactly once
-- ---------------------------------------------------------------------------

describe("tier2 extended-range warning", function()
  it("simple.nbs genuinely carries extended-range metadata", function()
    local projected = assert_order.expect(
      require_fixture("tests/fixtures/simple.nbs"), { "back" })
    expect.equal(projected.analysis.has_extended_range, true)
    expect.equal(projected.analysis.min_key, 27)
    expect.equal(projected.analysis.max_key, 46)
  end)

  it("renders WARN[extended-range] EXACTLY ONCE even when reported twice", function()
    local projected = assert_order.expect(
      require_fixture("tests/fixtures/simple.nbs"), { "back" })
    local args = {
      min_key = projected.analysis.min_key,
      max_key = projected.analysis.max_key,
    }
    -- The renderer is fed the code twice on purpose: the once-per-song rule
    -- must suppress the duplicate.
    local lines = {}
    local w = warnings.new({
      emit = function(line)
        lines[#lines + 1] = line
      end,
    })
    w:report(warnings.CODES.EXTENDED_RANGE, args)
    w:report(warnings.CODES.EXTENDED_RANGE, args)

    expect.equal(count_lines_starting_with(lines, "WARN[extended-range]"), 1)
  end)

  it("in-range fixture reports has_extended_range == false (zero warnings)", function()
    local projected = assert_order.expect(
      require_fixture("tests/fixtures/compat_demo_song.nbs"), { "back" })
    expect.equal(projected.analysis.has_extended_range, false)
    -- The gate the harness uses: only report when the analysis says so.
    local ledger = {}
    if projected.analysis.has_extended_range then
      ledger[#ledger + 1] = warnings.CODES.EXTENDED_RANGE
    end
    expect.equal(#ledger, 0)
    expect.equal(#render(ledger), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- CASE 5: custom instruments are refused
-- ---------------------------------------------------------------------------

describe("tier2 custom-instrument refusal", function()
  local bytes = require_fixture(FIXTURES .. "/custom_mix.nbs")

  it("plans three events, one of them custom (id 16, vanilla count 16)", function()
    local projected = assert_order.expect(bytes, { "back" })
    expect.equal(projected.analysis.total_notes, 3)
    expect.equal(#projected.plan, 3)

    local custom_seen = 0
    for index = 1, #projected.plan do
      if projected.plan[index].kind == "custom" then
        custom_seen = custom_seen + 1
        expect.equal(projected.plan[index].instrument, 16)
        expect.equal(projected.plan[index].custom_index, 0)
        expect.equal(projected.plan[index].name, nil)
      end
    end
    expect.equal(custom_seen, 1)
  end)

  it("makes ZERO calls for the custom note and one WARN[custom-instrument]", function()
    local projected = assert_order.expect(bytes, { "back" })

    -- Only the two vanilla notes reach the speaker; the custom note is refused
    -- with no call at all.
    expect.equal(#projected.calls, 2)
    expect.equal(projected.calls[1], "CALL back playNote harp 3 12")
    expect.equal(projected.calls[2], "CALL back playNote bass 3 12")
    for index = 1, #projected.calls do
      expect.falsy(string.find(projected.calls[index], "custom", 1, true))
    end

    -- The dispatcher ledger carries the bare code exactly once...
    expect.equal(#projected.warnings, 1)
    expect.equal(projected.warnings[1], "custom-instrument")

    -- ...and the renderer turns it into exactly one WARN[custom-instrument].
    local rendered = render(projected.warnings)
    expect.equal(count_lines_starting_with(rendered, "WARN[custom-instrument]"), 1)
  end)
end)
