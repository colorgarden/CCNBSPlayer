-- tests/tier2/assert_order.lua
--
-- TIER-2 ASSERTION LOGIC: PROJECT the expected speaker-call sequence from a
-- fixture, then COMPARE it, exactly, against what the emulator recorded.
--
-- This module is the "assert, not just run" half of the Tier-2 harness.  It is
-- PURE: it never touches the emulator, the global `peripheral`, the clock, or
-- any file unless it is invoked as the optional host-side command-line tool at
-- the bottom of this file.
--
-- ---------------------------------------------------------------------------
-- WHAT IT PROJECTS, AND FROM WHAT
-- ---------------------------------------------------------------------------
--   assert_order.expect(bytes, speaker_sides) -> {
--       calls       array of "CALL <side> <method> <args...>" strings,
--       assignment  the fanout.assign() result,
--       analysis    the nbs.analyze() result,
--       plan        the player.plan() event array,
--   }
--
-- The projection runs the REAL production modules, in the REAL pipeline order:
--
--     nbs.decode.decode  ->  nbs.analyze.analyze  ->  player.plan.plan
--         ->  player.fanout.assign(events, analysis, speakers)
--         ->  walk the assignment in the frozen (tick, layer, note) order
--         ->  player.dispatch:event(event, speaker_record)
--
-- and records what the real dispatcher actually asked each speaker to do.  The
-- speakers are `player.speaker.mock` records, whose call buffers capture the
-- exact method name and arguments dispatch forwarded.  Nothing about the
-- routing is re-typed here: if player/dispatch.lua changes, this projection
-- follows it, which is the whole point of "the call the dispatcher WOULD make".
--
-- `speaker_sides` is a list of the side names the harness will attach.  It is
-- ACCEPTED AS N SIDES so multi-speaker fixtures can be asserted later, but the
-- current harness attaches exactly one (see tests/tier2/record.lua), so the
-- default is { "back" }.  The sides are de-duplicated and sorted ASCENDING, so
-- the projection matches speaker.discover()'s frozen side order.
--
-- ---------------------------------------------------------------------------
-- THE RECORDED TEXT FORMAT (must match tests/tier2/record.lua byte-for-byte)
-- ---------------------------------------------------------------------------
-- record.lua writes one line per peripheral call:
--
--     CALL <side> <method> <args...>
--
-- with the side rendered as "-" when the API has none (getNames), integer
-- arguments as %d, and non-integer numbers as %.6f.  format_number below is a
-- deliberate, documented MIRROR of record.lua's format_arg so the projected
-- text and the recorded text are directly comparable.  It must never drift.
--
-- The harness records three SETUP calls before any note -- verified live:
--
--     CALL - getNames
--     CALL back getType
--     CALL back wrap
--
-- Those are peripheral discovery, not playback, so compare() IGNORES them
-- (see SETUP_METHODS).  They are still part of the determinism hash computed by
-- run.ps1, because they are recorded lines too.
--
-- ---------------------------------------------------------------------------
-- EXACTNESS
-- ---------------------------------------------------------------------------
-- compare() is EXACT: same length, same order, same bytes.  There is no
-- tolerance and no reordering.  On a mismatch it reports the FIRST differing
-- 1-based index plus both values, so a failure is actionable.  A missing line
-- on either side is a mismatch (index = the shorter list's length + 1).
--
-- ---------------------------------------------------------------------------
-- WHAT THIS DOES NOT DO
-- ---------------------------------------------------------------------------
-- It does not run the emulator (that is run.ps1 + record.lua).  It does not
-- silence out-of-range pitches: a note outside 0..24 makes the CraftOS-PC
-- emulated speaker RAISE, and dispatch contains the raise with pcall and drops
-- the note SILENTLY -- so the recorded call list would not match a 1:1 plan
-- projection.  That is exactly why playback assertions must use an in-range
-- fixture (see docs/COMPAT.md).  The projector faithfully models the player,
-- not the emulator's pitch restriction.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt -- no `//`, no bitwise operators,
-- no utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.
-- `pairs` is used only to copy synthetic option tables in tests, never to order
-- emitted calls.

local assert_order = {}

-- The three discovery calls record.lua emits before any note.  compare() drops
-- recorded lines whose method is one of these; they are not playback calls.
assert_order.SETUP_METHODS = {
  getNames = true,
  getType = true,
  wrap = true,
}

-- speaker.mock / plan use the snake_case seam names; record.lua writes the
-- camelCase peripheral method it actually invoked.  This maps one to the other.
local METHOD_TEXT = {
  play_note = "playNote",
  play_sound = "playSound",
  stop = "stop",
}

-- ---------------------------------------------------------------------------
-- Optional host-side command line: set up the module path BEFORE requiring.
-- ---------------------------------------------------------------------------
-- This block is inert when assert_order.lua is `require`d by a spec (the runner
-- has already configured package.path); it activates only for the two explicit
-- subcommands below, which run.ps1 invokes as a child `lua` process.
local IS_CLI = type(arg) == "table"
  and (arg[1] == "--project" or arg[1] == "--assert")

if IS_CLI then
  local script_path = tostring(arg[0] or ""):gsub("\\", "/")
  local root = script_path:match("^(.*)/tests/tier2/assert_order%.lua$")
  if root == nil or root == "" then
    root = "."
  end
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local decode = require("nbs.decode")
local analyze = require("nbs.analyze")
local plan = require("player.plan")
local fanout = require("player.fanout")
local dispatch = require("player.dispatch")
local speaker = require("player.speaker")

-- ---------------------------------------------------------------------------
-- Text formatting (the mirror of record.lua's format_arg)
-- ---------------------------------------------------------------------------

-- assert_order.format_number(value) -> the exact token record.lua would write.
function assert_order.format_number(value)
  local kind = type(value)
  if kind == "string" then
    return value
  end
  if kind == "boolean" then
    return tostring(value)
  end
  if kind == "number" then
    if value == math.floor(value) and math.abs(value) < 1000000000000000 then
      return string.format("%d", value)
    end
    return string.format("%.6f", value)
  end
  if value == nil then
    return "nil"
  end
  return tostring(value)
end

-- assert_order.format_call(side, method, ...) -> one "CALL ..." line.
function assert_order.format_call(side, method, ...)
  local parts = { "CALL", side or "-", method }
  local count = select("#", ...)
  local index = 1
  while index <= count do
    parts[#parts + 1] = assert_order.format_number((select(index, ...)))
    index = index + 1
  end
  return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
-- Sides
-- ---------------------------------------------------------------------------

-- assert_order.normalize_sides(speaker_sides) -> a sorted, de-duplicated list.
-- Missing/empty input yields the harness's single side, "back", so a caller may
-- pass nothing.
function assert_order.normalize_sides(speaker_sides)
  local chosen = {}
  if type(speaker_sides) == "table" then
    for index = 1, #speaker_sides do
      local side = speaker_sides[index]
      if type(side) == "string" and side ~= "" then
        chosen[#chosen + 1] = side
      end
    end
  end
  if #chosen == 0 then
    chosen[1] = "back"
  end

  table.sort(chosen)
  local unique = {}
  local result = {}
  for index = 1, #chosen do
    local side = chosen[index]
    if not unique[side] then
      unique[side] = true
      result[#result + 1] = side
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- The projection
-- ---------------------------------------------------------------------------

-- owner_side(assignment, records, cursors, event) -> the side an event was
-- assigned to, or nil when it was dropped.  fanout.assign preserves the frozen
-- walk order inside each by_speaker bucket, so consuming each bucket with a
-- per-side cursor and matching the event BY IDENTITY reconstructs exactly the
-- assignment the allocator made -- including the sides of custom events (which
-- are placed but make no call) and excluding dropped events (which are in no
-- bucket).
local function owner_side(assignment, records, cursors, event)
  for index = 1, #records do
    local side = records[index].side
    local bucket = assignment.by_speaker[side]
    if bucket ~= nil then
      local next_index = (cursors[side] or 0) + 1
      local candidate = bucket[next_index]
      if candidate ~= nil and rawequal(candidate, event) then
        cursors[side] = next_index
        return side
      end
    end
  end
  return nil
end

-- assert_order.project(events, analysis, speaker_sides) -> {
--     calls, assignment, records,
-- }
--
-- Pure and deterministic.  `events` is a player.plan() array; `analysis` is an
-- nbs.analyze() result.  Uses the REAL fanout allocator and the REAL dispatcher,
-- so the emitted lines are, by construction, the calls dispatch WOULD make.
function assert_order.project(events, analysis, speaker_sides)
  if type(events) ~= "table" then
    events = {}
  end
  if type(analysis) ~= "table" then
    analysis = {}
  end

  local sides = assert_order.normalize_sides(speaker_sides)

  local records = {}
  local record_by_side = {}
  for index = 1, #sides do
    local record = speaker.mock(sides[index])
    records[index] = record
    record_by_side[sides[index]] = record
  end

  local assignment = fanout.assign(events, analysis, records)
  local dispatcher = dispatch.new()
  local cursors = {}
  local calls = {}

  for index = 1, #events do
    local event = events[index]
    local side = owner_side(assignment, records, cursors, event)
    if side ~= nil then
      local record = record_by_side[side]
      local before = #record.calls
      dispatcher:event(event, record)
      if #record.calls > before then
        local entry = record.calls[#record.calls]
        local method = METHOD_TEXT[entry.method] or entry.method
        calls[#calls + 1] = assert_order.format_call(side, method,
          entry.args[1], entry.args[2], entry.args[3])
      end
    end
  end

  return {
    calls = calls,
    assignment = assignment,
    records = records,
  }
end

-- assert_order.expect(bytes, speaker_sides) -> { calls, assignment, analysis,
-- plan }.  Decodes and plans the fixture with the REAL modules, then projects.
-- Raises (never returns) when the fixture cannot be decoded, because a
-- projection of undecodable bytes would be meaningless.
function assert_order.expect(bytes, speaker_sides)
  local decoded = decode.decode(bytes)
  if type(decoded) ~= "table" or not decoded.ok then
    local detail = "decode failed"
    if type(decoded) == "table" and decoded.error ~= nil then
      detail = "decode failed: " .. tostring(decoded.error.code) .. " "
        .. tostring(decoded.error.msg)
    end
    error(detail, 2)
  end

  local analysis = analyze.analyze(decoded.song)
  local events = plan.plan(decoded.song, analysis)
  local projected = assert_order.project(events, analysis, speaker_sides)

  return {
    calls = projected.calls,
    assignment = projected.assignment,
    analysis = analysis,
    plan = events,
  }
end

-- ---------------------------------------------------------------------------
-- Parsing and comparison
-- ---------------------------------------------------------------------------

-- The method of a "CALL <side> <method> ..." line, or nil when the line is not
-- a call line.
local function method_of(line)
  local _, _, _side, method = line:find("^CALL (%S+) (%S+)")
  return method
end

-- assert_order.parse_recorded(text) -> { calls, status }.
--   calls   the playback calls only (setup lines dropped), in order,
--           normalised to LF (a trailing CR is stripped),
--   status  the last "STATUS ..." line, or nil.
function assert_order.parse_recorded(text)
  local calls = {}
  local status = nil
  if type(text) ~= "string" then
    text = ""
  end

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local clean = line:gsub("\r$", "")
    if clean:sub(1, 5) == "CALL " then
      local method = method_of(clean)
      if not assert_order.SETUP_METHODS[method] then
        calls[#calls + 1] = clean
      end
    elseif clean:sub(1, 7) == "STATUS " then
      status = clean
    end
  end

  return { calls = calls, status = status }
end

-- assert_order.compare(expected_calls, recorded_text) -> {
--     ok, first_diff, expected, actual, expected_count, actual_count, status,
-- }
--
-- EXACT ordered comparison of the projected playback calls against the recorded
-- text.  Setup lines and the STATUS line are not part of the comparison; the
-- status is reported for diagnostics only.
function assert_order.compare(expected_calls, recorded_text)
  local expected = expected_calls
  if type(expected) ~= "table" then
    expected = {}
  end

  local parsed = assert_order.parse_recorded(recorded_text)
  local actual = parsed.calls

  local expected_count = #expected
  local actual_count = #actual
  local limit = expected_count
  if actual_count > limit then
    limit = actual_count
  end

  for index = 1, limit do
    local expected_line = expected[index]
    local actual_line = actual[index]
    if expected_line ~= actual_line then
      return {
        ok = false,
        first_diff = index,
        expected = expected_line,
        actual = actual_line,
        expected_count = expected_count,
        actual_count = actual_count,
        status = parsed.status,
      }
    end
  end

  return {
    ok = true,
    first_diff = nil,
    expected = nil,
    actual = nil,
    expected_count = expected_count,
    actual_count = actual_count,
    status = parsed.status,
  }
end

-- ---------------------------------------------------------------------------
-- Optional host-side command line (never reached when required as a module)
-- ---------------------------------------------------------------------------
--   lua tests/tier2/assert_order.lua --project <fixture> [side ...]
--       Print the projected CALL lines, one per line, then a count.
--
--   lua tests/tier2/assert_order.lua --assert <fixture> <recorded.txt> [side ...]
--       Project the fixture, compare EXACTLY against the recorded text, print
--       the banner, and exit non-zero (via an uncaught error -- os.exit is
--       forbidden in this codebase) on any mismatch.

if IS_CLI then
  local function read_file(path)
    if type(path) ~= "string" or path == "" then
      error("assert_order: a file path is required", 0)
    end
    local handle = io.open(path, "rb")
    if handle == nil then
      error("assert_order: cannot read " .. path, 0)
    end
    local contents = handle:read("*a")
    handle:close()
    return contents or ""
  end

  local mode = arg[1]
  local fixture_path = arg[2]

  if mode == "--project" then
    local sides = {}
    for index = 3, #arg do
      sides[#sides + 1] = arg[index]
    end
    local projected = assert_order.expect(read_file(fixture_path), sides)
    for index = 1, #projected.calls do
      io.write(projected.calls[index] .. "\n")
    end
    io.write(string.format("PROJECTED %d call(s)\n", #projected.calls))

  elseif mode == "--assert" then
    local recorded_path = arg[3]
    local sides = {}
    for index = 4, #arg do
      sides[#sides + 1] = arg[index]
    end

    local projected = assert_order.expect(read_file(fixture_path), sides)
    local comparison = assert_order.compare(projected.calls,
      read_file(recorded_path))

    if not comparison.ok then
      io.write("=== SEQUENCE FAIL ===\n")
      if comparison.first_diff ~= nil then
        io.write(string.format("first difference at index %d\n",
          comparison.first_diff))
        io.write("  expected: " .. tostring(comparison.expected) .. "\n")
        io.write("  actual:   " .. tostring(comparison.actual) .. "\n")
      end
      io.write(string.format("expected %d call(s), recorded %d call(s)\n",
        comparison.expected_count, comparison.actual_count))
      error("tier2 assertion failed", 0)
    end

    io.write(string.format("=== SEQUENCE OK (%d calls) ===\n",
      comparison.actual_count))
    io.write(string.format(
      "projected and recorded playback calls are identical (index 1..%d)\n",
      comparison.actual_count))
  end
end

return assert_order
