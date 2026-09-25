-- tests/tui_spec.lua
--
-- Tier-1 spec for player/tui.lua and the root-level ccnbsplayer.lua entry
-- program.  Written FIRST, before either file exists (strict TDD: watch it
-- fail, then implement until it is green).
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE (asserted here)
-- ===========================================================================
--   local tui = require("player.tui")
--   tui.run(opts) -> { exit_code = <integer>, played = <string|nil>,
--                      stopped = <boolean> }
--
-- Every seam is injectable so the UI is testable WITHOUT a terminal and
-- WITHOUT a computer:
--   opts.files       array of .nbs paths/names        (default: scan cwd)
--   opts.read_file   function(path) -> bytes          (default: filesystem)
--   opts.speakers    speaker records                  (default: discover)
--   opts.clock       a clock                           (default: new_os)
--   opts.pull        function() -> event...           (default: pullEventRaw)
--   opts.write       function(text)                   (default: term/print)
--   opts.redraw      function(state)                  (optional)
--   opts.quiet       suppress warning output
--   opts.max_events  safety bound for the event loop
--
-- Behaviour pinned by this spec:
--   1. the file list is written, naming every entry;
--   2. selecting an entry decodes + analyzes + plays it, and exit_code is 0;
--   3. the extended-range warning is written BEFORE the first progress line;
--   4. left/right/a/d do NOT move the playback position (NO seek), and
--      player/tui.lua contains no `seek` identifier;
--   5. a v5 song (loop fields present) plays exactly once (NO loop playback),
--      even when the loop flag is forced on at the core level;
--   6. the stop key cancels the session and stops EVERY speaker;
--   7. pause/resume works through the clock/tempo seams -- no events fire
--      while paused even as the clock advances, and events resume afterwards;
--   8. a malformed file yields a readable, non-zero exit instead of a raise;
--   9. an injected `terminate` stops every speaker and escapes nothing;
--  10. opts.max_events bounds the event loop;
--  11. ccnbsplayer.lua is a loadable Lua chunk;
--  12. the whole harness is driven by opts.pull only (no real os.pullEvent).
--
-- The event harness is a SCRIPTED QUEUE: opts.pull pops a table of steps and
-- may advance a VIRTUAL clock as a side effect.  Nothing sleeps for real.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no utf8.*, no os.exit, no real os.pullEvent.

local tui = require("player.tui")
local ccnbs = require("ccnbs")
local speaker = require("player.speaker")
local clock = require("player.clock")
local decode = require("nbs.decode")

-- ---------------------------------------------------------------------------
-- Project root + file helpers (the convention used across the suite)
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

local V4 = join(ROOT, "tests/fixtures/v4.nbs")
local V5 = join(ROOT, "tests/fixtures/v5.nbs")
local SIMPLE = join(ROOT, "tests/fixtures/simple.nbs")
local MALFORMED = join(ROOT, "tests/corpus/malformed/truncated_header.nbs")
local TUI_SOURCE = join(ROOT, "player/tui.lua")

local function read_bytes(path)
  local handle = assert(io.open(path, "rb"), "cannot open " .. path)
  local data = handle:read("*a")
  handle:close()
  return data
end

-- Whether the concurrent warning-renderer lane has landed.  The TUI probes for
-- it defensively, so the spec accepts EITHER the rendered `WARN[code]` line or
-- the bare-code fallback and records which form it saw.
local function warnings_renderer_present()
  local ok = pcall(require, "player.warnings")
  return ok
end

local HAS_RENDERER = warnings_renderer_present()

-- ---------------------------------------------------------------------------
-- Capture + scripted-event helpers
-- ---------------------------------------------------------------------------

-- A write sink that appends every written chunk to an ordered array.
local function new_capture()
  local lines = {}
  local function write(text)
    lines[#lines + 1] = text
  end
  return lines, write
end

local function joined(lines)
  return table.concat(lines)
end

-- Extract every progress index written as "进度 <i>/<total>".
local function progress_values(lines)
  local values = {}
  for index = 1, #lines do
    local value = lines[index]:match("进度%s*(%d+)/")
    if value ~= nil then
      values[#values + 1] = tonumber(value)
    end
  end
  return values
end

local function count_progress(lines)
  local total = 0
  for index = 1, #lines do
    if lines[index]:find("进度", 1, true) ~= nil then
      total = total + 1
    end
  end
  return total
end

-- scripted(vclock, steps, on_step) -> pull function.
--
-- Each step is { advance = <ms>, event = { <values...> }, mark = <label> }.
-- When the steps run out the pull returns a neutral no-op key forever, which
-- keeps an unfinished script from wedging; real tests end in a stop/finish.
local function scripted(vclock, steps, on_step)
  local index = 0
  return function()
    index = index + 1
    local step = steps[index]
    if step == nil then
      return "key", "nop"
    end
    if step.advance ~= nil then
      clock.advance_to(vclock, step.advance)
    end
    if on_step ~= nil then
      on_step(index, step)
    end
    if step.event ~= nil then
      return table.unpack(step.event)
    end
    return "key", "nop"
  end
end

local function has_method(record, method)
  for index = 1, #record.calls do
    if record.calls[index].method == method then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- 1. File list rendering
-- ---------------------------------------------------------------------------

describe("tui file list", function()
  it("1. writes both candidate names before the selection is read", function()
    local out, write = new_capture()
    local pull = function()
      return "key", "q"
    end

    local result = tui.run({
      files = { "a.nbs", "b.nbs" },
      write = write,
      pull = pull,
      speakers = {},
    })

    expect.equal(result.exit_code, 0)
    expect.contains(joined(out), "a.nbs")
    expect.contains(joined(out), "b.nbs")

    io.write("    CASE1 list=\"" .. joined(out):gsub("\n", " | ") .. "\"\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. Selection starts playback
-- ---------------------------------------------------------------------------

describe("tui selection and playback", function()
  it("2. selecting v4.nbs decodes, analyzes and plays through a virtual clock", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()
    local reads = {}

    local steps = {
      { event = { "key", "enter" } },
      { advance = 100000, event = { "key", "nop" } },
      { event = { "key", "s" } },
    }

    local result = tui.run({
      files = { V4 },
      read_file = function(path)
        reads[#reads + 1] = path
        return read_bytes(path)
      end,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps),
    })

    expect.equal(result.exit_code, 0)
    expect.equal(result.played, V4)
    expect.equal(reads[1], V4)
    expect.contains(joined(out), "音符 5")

    local values = progress_values(out)
    expect.truthy(#values >= 1)
    expect.equal(values[#values], 5)

    local calls = #left.calls + #right.calls
    expect.truthy(calls >= 1)

    io.write("    CASE2 exit=" .. tostring(result.exit_code)
      .. " progress=" .. table.concat(values, ",")
      .. " speaker_calls=" .. tostring(calls) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. Warnings come out BEFORE playback
-- ---------------------------------------------------------------------------

describe("tui warning ordering", function()
  it("3. extended-range is written before the first progress line", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()

    local steps = {
      { event = { "key", "enter" } },
      { advance = 100000, event = { "key", "s" } },
    }

    local result = tui.run({
      files = { SIMPLE },
      read_file = read_bytes,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps),
    })

    expect.equal(result.exit_code, 0)

    local text = joined(out)
    local extended_position = text:find("extended-range", 1, true)
    local progress_position = text:find("进度", 1, true)

    expect.truthy(extended_position ~= nil)
    expect.truthy(progress_position ~= nil)
    expect.truthy(extended_position < progress_position)

    if HAS_RENDERER then
      expect.contains(text, "WARN[extended-range]")
    else
      expect.contains(text, "extended-range")
    end

    io.write("    CASE3 form=" .. (HAS_RENDERER and "rendered" or "bare")
      .. " ext_pos=" .. tostring(extended_position)
      .. " prog_pos=" .. tostring(progress_position) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. No seek
-- ---------------------------------------------------------------------------

describe("tui non-goal: no seek", function()
  it("4. left/right/a/d are no-ops and the source has no seek identifier", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()

    local steps = {
      { event = { "key", "enter" } },
      { advance = 200, event = { "key", "left" } },
      { event = { "key", "right" } },
      { event = { "key", "a" } },
      { advance = 400, event = { "key", "d" } },
      { event = { "key", "nop" } },
      { advance = 800, event = { "key", "s" } },
    }

    local result = tui.run({
      files = { V4 },
      read_file = read_bytes,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps),
    })

    expect.equal(result.exit_code, 0)

    -- No repeat and no skip: the position advanced exactly one event at a time.
    local values = progress_values(out)
    expect.sequence_equal(values, { 1, 2, 3, 4, 5 })

    local handle = assert(io.open(TUI_SOURCE, "rb"), "player/tui.lua is missing")
    local source = handle:read("*a")
    handle:close()
    expect.equal(source:find("seek", 1, true), nil)

    io.write("    CASE4 progress=" .. table.concat(values, ",")
      .. " source_has_seek=" .. tostring(source:find("seek", 1, true) ~= nil) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. No loop playback
-- ---------------------------------------------------------------------------

describe("tui non-goal: no loop playback", function()
  it("5. v5 loop fields are decoded but never drive playback", function()
    -- (a) the fixture really carries loop metadata.
    local decoded = decode.decode(read_bytes(V5))
    expect.equal(decoded.ok, true)
    expect.truthy(decoded.song.header.loop ~= nil)
    expect.truthy(decoded.song.header.max_loop_count ~= nil)
    expect.truthy(decoded.song.header.loop_start_tick ~= nil)

    -- (b) the TUI plays it exactly once.
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()
    local steps = {
      { event = { "key", "enter" } },
      { advance = 100000, event = { "key", "s" } },
    }

    local result = tui.run({
      files = { V5 },
      read_file = read_bytes,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps),
    })
    expect.equal(result.exit_code, 0)
    expect.sequence_equal(progress_values(out), { 1, 2, 3, 4, 5 })

    -- (c) even with the loop flag FORCED ON at the core level, the player fires
    -- each planned event exactly once: loop metadata is inert.
    local song = decode.decode(read_bytes(V5)).song
    song.header.loop = 1
    song.header.max_loop_count = 0
    song.header.loop_start_tick = 0

    local loop_clock = clock.new_virtual(0)
    local mock = speaker.mock("left")
    local fired = 0
    local session = ccnbs.play(song, {
      speakers = { mock },
      clock = loop_clock,
      on_event = function()
        fired = fired + 1
      end,
    })
    clock.advance_to(loop_clock, 1000000)
    expect.equal(fired, #session.plan)
    expect.equal(fired, 5)

    -- (d) the source carries no loop-playback identifier.
    local handle = assert(io.open(TUI_SOURCE, "rb"), "player/tui.lua is missing")
    local source = handle:read("*a")
    handle:close()
    expect.equal(source:find("loop_back", 1, true), nil)
    expect.equal(source:find("loopback", 1, true), nil)
    expect.equal(source:find("restart_playback", 1, true), nil)
    expect.equal(source:find("speakerlib", 1, true), nil)

    io.write("    CASE5 tui_progress=1..5 core_loop_on_fired=" .. tostring(fired) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 6. Stop works
-- ---------------------------------------------------------------------------

describe("tui transport: stop", function()
  it("6. the stop key cancels mid-playback and stops every speaker", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()

    local steps = {
      { event = { "key", "enter" } },
      { advance = 200, event = { "key", "s" } },
    }

    local result = tui.run({
      files = { V4 },
      read_file = read_bytes,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps),
    })

    expect.equal(result.exit_code, 0)
    expect.equal(result.stopped, true)
    expect.equal(has_method(left, "stop"), true)
    expect.equal(has_method(right, "stop"), true)

    -- Stopped mid-song: fewer than all five events progressed.
    local values = progress_values(out)
    expect.truthy(#values < 5)

    io.write("    CASE6 exit=" .. tostring(result.exit_code)
      .. " stopped=" .. tostring(result.stopped)
      .. " progress=" .. tostring(#values)
      .. " left_stop=" .. tostring(has_method(left, "stop"))
      .. " right_stop=" .. tostring(has_method(right, "stop")) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. Pause / resume keeps the UI responsive
-- ---------------------------------------------------------------------------

describe("tui transport: pause and resume", function()
  it("7. no events fire while paused; events resume afterwards", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()
    local marks = {}

    local steps = {
      { event = { "key", "enter" } },
      { advance = 1000, event = { "key", "nop" }, mark = "c1" },
      { event = { "key", "space" } },
      { advance = 6000, event = { "key", "nop" }, mark = "c2" },
      { event = { "key", "space" } },
      { advance = 9000, event = { "key", "nop" }, mark = "c3" },
      { event = { "key", "s" } },
    }

    local function on_step(_, step)
      if step.mark ~= nil then
        marks[step.mark] = count_progress(out)
      end
    end

    local result = tui.run({
      files = { SIMPLE },
      read_file = read_bytes,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps, on_step),
    })

    expect.equal(result.exit_code, 0)
    expect.truthy(marks.c1 ~= nil)
    expect.truthy(marks.c2 ~= nil)
    expect.truthy(marks.c3 ~= nil)

    -- Advancing the clock while paused fired nothing.
    expect.equal(marks.c2, marks.c1)
    -- Resuming let time move again and events fired.
    expect.truthy(marks.c3 > marks.c2)

    io.write("    CASE7 progress_marks c1=" .. tostring(marks.c1)
      .. " c2(paused)=" .. tostring(marks.c2)
      .. " c3(resumed)=" .. tostring(marks.c3) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. A bad file is handled
-- ---------------------------------------------------------------------------

describe("tui malformed input", function()
  it("8. a corrupt file yields a readable non-zero exit, never a raise", function()
    local out, write = new_capture()
    local pull = function()
      return "key", "enter"
    end

    local result = nil
    local ok = pcall(function()
      result = tui.run({
        files = { MALFORMED },
        write = write,
        pull = pull,
        speakers = {},
      })
    end)

    expect.equal(ok, true)
    expect.truthy(result ~= nil)
    expect.truthy(result.exit_code ~= 0)
    expect.contains(joined(out), "E_TRUNCATED")

    io.write("    CASE8 exit=" .. tostring(result.exit_code)
      .. " text=\"" .. joined(out):gsub("\n", " | ") .. "\"\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. Terminate protection
-- ---------------------------------------------------------------------------

describe("tui terminate", function()
  it("9. an injected terminate stops every speaker and escapes nothing", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()

    local steps = {
      { event = { "key", "enter" } },
      { event = { "terminate" } },
    }

    local result = nil
    local ok, err = pcall(function()
      result = tui.run({
        files = { V4 },
        read_file = read_bytes,
        speakers = { left, right },
        clock = vclock,
        write = write,
        pull = scripted(vclock, steps),
      })
    end)

    expect.equal(ok, true)
    expect.equal(has_method(left, "stop"), true)
    expect.equal(has_method(right, "stop"), true)

    io.write("    CASE9 pcall_ok=" .. tostring(ok)
      .. " left_stop=" .. tostring(has_method(left, "stop"))
      .. " right_stop=" .. tostring(has_method(right, "stop"))
      .. " exit=" .. tostring(result and result.exit_code)
      .. " err=" .. tostring(err) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. opts.max_events bounds the loop
-- ---------------------------------------------------------------------------

describe("tui event bound", function()
  it("10. opts.max_events makes run return instead of looping forever", function()
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local out, write = new_capture()

    -- Selection, then a pull that never stops offering neutral events.
    local steps = {
      { event = { "key", "enter" } },
    }

    local result = tui.run({
      files = { V4 },
      read_file = read_bytes,
      speakers = { left, right },
      clock = vclock,
      write = write,
      pull = scripted(vclock, steps),
      max_events = 3,
    })

    expect.equal(result.exit_code, 0)
    io.write("    CASE10 exit=" .. tostring(result.exit_code) .. " max_events=3\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. The entry program exists and is loadable
-- ---------------------------------------------------------------------------

describe("ccnbsplayer entry program", function()
  it("11. ccnbsplayer.lua is a valid Lua chunk (compiles, not executed)", function()
    local path = join(ROOT, "ccnbsplayer.lua")
    local chunk, load_error = loadfile(path)

    expect.truthy(chunk ~= nil)
    if chunk == nil then
      error("ccnbsplayer.lua did not compile: " .. tostring(load_error), 0)
    end
    expect.equal(type(chunk), "function")

    io.write("    CASE11 loadfile=\"" .. path .. "\" type=" .. type(chunk) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. The scripted-event-queue harness itself
-- ---------------------------------------------------------------------------

describe("tui scripted-event harness", function()
  it("12. drives only opts.pull and never touches the real event API", function()
    local saved_raw = os.pullEventRaw
    local saved_pull = os.pullEvent
    os.pullEventRaw = function()
      error("real os.pullEventRaw must not be called by the spec")
    end
    os.pullEvent = function()
      error("real os.pullEvent must not be called by the spec")
    end

    local ok = false
    local err = nil
    ok, err = pcall(function()
      local vclock = clock.new_virtual(0)
      local left = speaker.mock("left")
      local right = speaker.mock("right")
      local out, write = new_capture()
      local steps = {
        { event = { "key", "enter" } },
        { advance = 100000, event = { "key", "s" } },
      }

      local started = os.clock()
      local result = tui.run({
        files = { V4 },
        read_file = read_bytes,
        speakers = { left, right },
        clock = vclock,
        write = write,
        pull = scripted(vclock, steps),
      })
      local elapsed = os.clock() - started

      expect.equal(result.exit_code, 0)
      expect.truthy(elapsed < 5)
    end)

    os.pullEventRaw = saved_raw
    os.pullEvent = saved_pull

    expect.equal(ok, true)
    if not ok then
      error(err, 0)
    end

    io.write("    CASE12 injected_only ok=" .. tostring(ok) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. A custom-only song with ZERO speakers is explained, not silent
-- ---------------------------------------------------------------------------
-- Custom-instrument notes are refused at playback, so a song made ONLY of them
-- makes no sound.  With speakers attached ccnbs reports the refusal summary at
-- the end; with NO speaker attached the custom events are never routed, so that
-- summary never fires and the user would hear nothing with no explanation.  The
-- TUI must surface the load-time diagnostic itself.
-- ---------------------------------------------------------------------------

describe("tui custom-only with zero speakers", function()
  it("13. writes a custom-instrument diagnostic instead of silent playback", function()
    local vclock = clock.new_virtual(0)
    local out, write = new_capture()

    -- decode is stubbed to hand the TUI an all-custom song without a bespoke
    -- .nbs fixture; analyze and play stay REAL, so the diagnostic is exercised
    -- end to end through the real library.
    local saved_decode = ccnbs.decode
    ccnbs.decode = function()
      return {
        ok = true,
        song = {
          header = {
            name = "allcustom",
            tempo_ticks_per_second = 10,
            vanilla_instrument_count = 16,
          },
          layers = {},
          notes = {
            { tick = 0, layer = 0, instrument = 16, key = 45,
              velocity = 100, panning = 100, pitch = 0 },
            { tick = 1, layer = 0, instrument = 17, key = 45,
              velocity = 100, panning = 100, pitch = 0 },
          },
          custom_instruments = {},
        },
      }
    end

    local steps = {
      { event = { "key", "enter" } },
      { advance = 100000, event = { "key", "s" } },
    }

    local result
    local ok = pcall(function()
      result = tui.run({
        files = { "allcustom.nbs" },
        read_file = function() return "" end,
        speakers = {},              -- ZERO speakers: the trigger for the defect
        clock = vclock,
        write = write,
        pull = scripted(vclock, steps),
      })
    end)

    ccnbs.decode = saved_decode

    expect.equal(ok, true)
    expect.equal(result.exit_code, 0)
    expect.contains(joined(out), "custom-instrument")
    io.write("    CASE13 exit=" .. tostring(result.exit_code)
      .. " text=\"" .. joined(out):gsub("\n", " | ") .. "\"\n")
  end)
end)
