-- tests/tier2/record.lua
--
-- TIER-2 INTEGRATION HARNESS -- the CraftOS-PC startup script.
--
-- This file runs INSIDE CraftOS-PC (headless) and is loaded through the
-- emulator's `--script` option by tests/tier2/run.ps1.  It drives the REAL
-- player modules against a REAL fixture on a REAL emulated speaker, records
-- every `peripheral` call, writes the recording to `result.txt`, and exits
-- through os.shutdown(N).
--
-- ---------------------------------------------------------------------------
-- WHY THE RESULT CHANNEL IS A FILE
-- ---------------------------------------------------------------------------
-- The headless renderer emits a screen-diff stream (the boot banner, "Welcome
-- to CraftOS-PC!" expanded character by character, hundreds of CR/LF).  It is
-- NOT reliably parseable, so the harness never parses stdout.  Instead it writes
-- a clean LF file with `fs.open`, which the host finds at
--     <--directory DIR>\computer\<ID>\result.txt
-- and run.ps1 passes `--id 0` so that path is deterministic.
--
-- ---------------------------------------------------------------------------
-- THE INTERCEPT POINT (and why this one)
-- ---------------------------------------------------------------------------
-- The only module in the project that touches the global `peripheral` is
-- player/speaker.lua; it calls peripheral.getNames(), peripheral.getType(side)
-- and (lazily) peripheral.wrap(side).  Wrap the GLOBAL to see those three, but
-- the actual notes reach hardware through the OBJECT returned by
-- peripheral.wrap -- so this script ALSO wraps that object.  Wrapping the
-- global alone would record discovery but miss every playNote/playSound/stop;
-- wrapping the object alone would miss which side was discovered.  Doing both
-- captures the full picture, and the object-level interception is what actually
-- records the speaker calls.
--
-- CraftOS-PC's peripheral.wrap(side) returns a table whose methods are called
-- WITHOUT an explicit self (`obj.playNote("harp", v, p)`).  player/speaker.lua
-- calls them WITH self (that is its frozen contract).  The proxy therefore
-- drops the self it receives from speaker.wrap and forwards only the real
-- arguments to the underlying CraftOS method.
--
-- ---------------------------------------------------------------------------
-- WHY os.shutdown IS MANDATORY
-- ---------------------------------------------------------------------------
-- A --script that returns without calling os.shutdown leaves the emulator in
-- its interactive shell and HANGS FOREVER.  Every path here calls os.shutdown:
-- 0 on success, 1 on any captured failure.  run.ps1 additionally enforces a
-- wall-clock timeout and kills the process on expiry.
--
-- ---------------------------------------------------------------------------
-- AUDIO TEARDOWN GRACE (empirically required)
-- ---------------------------------------------------------------------------
-- CraftOS-PC 2.8.3 crashes with an access violation (0xC0000005) at shutdown
-- if os.shutdown is reached while the emulated speaker still has queued audio;
-- a playNote followed immediately by os.shutdown reliably crashes, while a
-- playNote followed by ~1 s of rest exits 0.  The harness therefore sleeps a
-- fixed teardown grace AFTER the (instant, virtual-clock) playback and before
-- os.shutdown.  This is a fixed teardown wait, NOT waiting for the song: the
-- song itself is driven entirely by the virtual clock, synchronously.
--
-- ---------------------------------------------------------------------------
-- MULTI-SPEAKER ROUTING AND NON-CALL RECORD LINES (task-30)
-- ---------------------------------------------------------------------------
-- The harness attaches one speaker per side listed in /speakers.txt (written by
-- run.ps1 -SpeakerSides) and routes every planned event through the REAL
-- player.fanout.assign allocator, dispatching each event to the side it owns.
-- This is what makes an overflow fixture show a real DROP (a player decision)
-- rather than an emulator budget refusal, and what makes a two-speaker run show
-- a genuinely balanced split.
--
-- Besides the `CALL ...` lines, result.txt now carries these NON-CALL summary
-- lines (ignored by the projection comparator and by the CALL-consuming host
-- assertions, but asserted by tests/tier2/edge_cases.ps1):
--     ASSIGN required=<n> found=<n> dropped=<n> warning=<code|->
--     WARGS peak=<n> required=<n> found=<n> dropped=<n>     (only with a warning)
--     SPLIT <side> <placed-events>
--     DROPPED tick=<n> layer=<n> note=<n> kind=<kind>
--     WARN[<code>] <Chinese explanation>
--
-- Compatibility: this runs under Cobalt (Lua 5.2), so it uses no `//`, no
-- bitwise operators, no utf8.*, no goto, no os.exit.

-- ---------------------------------------------------------------------------
-- Module search path
-- ---------------------------------------------------------------------------
-- run.ps1 copies nbs/ and player/ into the computer's root, so a module such as
-- nbs.decode lives at /nbs/decode.lua and player.plan at /player/plan.lua.
-- Prefix that root explicitly, ahead of CraftOS's own /rom module path.
local ROOT = ""

do
  local prefix
  if ROOT == "" then
    prefix = "/"
  else
    prefix = "/" .. ROOT .. "/"
  end
  package.path = prefix .. "?.lua;" .. prefix .. "?/init.lua;" .. package.path
end

local FIXTURE_PATH = "/fixture.nbs"
-- ---------------------------------------------------------------------------
-- THE SPEAKER SET (single vs multi)
-- ---------------------------------------------------------------------------
-- run.ps1 writes a comma-separated side list to /speakers.txt.  This harness
-- attaches a speaker on each requested side and routes every event through the
-- REAL player.fanout.assign allocator, so the recorded CALL lines carry the
-- side the player chose -- not a fixed single side.  When /speakers.txt is
-- absent (e.g. running this script by hand) the harness attaches one speaker on
-- "back", which is exactly the historical behaviour.
local SPEAKER_SIDES_PATH = "/speakers.txt"
local DEFAULT_SPEAKER_SIDES = { "back" }
local AUDIO_DRAIN_SECONDS = 1.5

-- ---------------------------------------------------------------------------
-- Result channel
-- ---------------------------------------------------------------------------

-- Every recorded call, in chronological order, already formatted as one line.
local recorded = {}

-- While true, record_call is a no-op.  CraftOS's own peripheral.wrap calls back
-- into the global peripheral (getMethods/getType/call); those internal calls
-- must not pollute the recording, so proxy.wrap suppresses them.
local recording_suppressed = false

-- format_arg(value) -> a stable, greppable token for one argument.  Numbers are
-- normalised so an integral value never shows a trailing ".0" (1.0 -> "1") and
-- non-integers use a fixed six decimal places, keeping the recording
-- byte-identical across runs.
local function format_arg(value)
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

-- record_line(text): append one already-formatted line to the recording.  Used
-- for the assignment summary and the WARN[...] lines; CALL lines still go
-- through record_call.  Non-CALL lines are ignored by the projection comparator
-- and by every CALL-consuming host assertion, so they never perturb playback
-- comparisons.
local function record_line(text)
  if recording_suppressed then
    return
  end
  recorded[#recorded + 1] = text
end

-- record_call(side, method, ...): append one `CALL <side> <method> <args...>`
-- line.  `nil` side (getNames has none) is rendered as "-" so the line stays
-- fixed-width/greppable.
local function record_call(side, method, ...)
  if recording_suppressed then
    return
  end
  local parts = { "CALL", side or "-", method }
  local count = select("#", ...)
  local index = 1
  while index <= count do
    parts[#parts + 1] = format_arg(select(index, ...))
    index = index + 1
  end
  recorded[#recorded + 1] = table.concat(parts, " ")
end

-- collapse(text): keep a failure message on one line so it can safely follow
-- `STATUS fail:`.
local function collapse(text)
  return (tostring(text):gsub("[\r\n]+", " | "))
end

-- write_result(status): ALWAYS writes result.txt, even on the error path.
local function write_result(status)
  local handle = fs.open("result.txt", "w")
  if handle == nil then
    return false
  end
  handle.write(table.concat(recorded, "\n"))
  if #recorded > 0 then
    handle.write("\n")
  end
  handle.write("STATUS " .. collapse(status) .. "\n")
  handle.close()
  return true
end

-- ---------------------------------------------------------------------------
-- The peripheral recorder
-- ---------------------------------------------------------------------------

-- install_peripheral_recorder(): replace the global `peripheral` with a proxy
-- that records every call and delegates to the real emulated peripheral.
-- Returns false when no peripheral API exists in this environment.
local function install_peripheral_recorder()
  local real = rawget(_G, "peripheral")
  if type(real) ~= "table" then
    return false
  end

  -- proxy_object(side, object): wrap one peripheral object so its speaker
  -- methods are recorded.  A `self` passed by speaker.wrap is dropped before
  -- the underlying CraftOS method is called (see the header note).
  local function proxy_object(side, object)
    local proxy = {}

    local function forward(method)
      local fn = object[method]
      if type(fn) ~= "function" then
        return nil
      end
      return function(self, ...)
        record_call(side, method, ...)
        return fn(...)
      end
    end

    proxy.playNote = forward("playNote")
    proxy.playSound = forward("playSound")

    local stop_fn = object["stop"]
    if type(stop_fn) == "function" then
      proxy.stop = function(self)
        record_call(side, "stop")
        return stop_fn()
      end
    end

    return proxy
  end

  local proxy = {}

  function proxy.getNames()
    record_call(nil, "getNames")
    return real.getNames()
  end

  function proxy.getType(side)
    record_call(side, "getType")
    return real.getType(side)
  end

  function proxy.wrap(side)
    record_call(side, "wrap")
    -- Delegate, but hide the internal getMethods/getType/call that CraftOS's
    -- own wrap performs on the global peripheral.
    recording_suppressed = true
    local ok, object = pcall(real.wrap, side)
    recording_suppressed = false
    if not ok then
      error(object, 2)
    end
    if type(object) == "table" then
      return proxy_object(side, object)
    end
    return object
  end

  -- Pass everything else (getMethods, call, find, hasType, ...) straight
  -- through to the real peripheral API, so replacing the global does not break
  -- CraftOS internals that re-enter it.
  setmetatable(proxy, { __index = real })

  rawset(_G, "peripheral", proxy)
  return true
end

-- ---------------------------------------------------------------------------
-- Playback
-- ---------------------------------------------------------------------------

-- read_fixture() -> the raw .nbs bytes as a string.
local function read_fixture()
  local handle = fs.open(FIXTURE_PATH, "rb")
  if handle == nil then
    error("fixture not found inside the emulator at " .. FIXTURE_PATH, 0)
  end
  local bytes
  if type(handle.readAll) == "function" then
    bytes = handle.readAll()
  else
    bytes = handle.read()
  end
  handle.close()
  if type(bytes) ~= "string" then
    error("could not read bytes from " .. FIXTURE_PATH, 0)
  end
  return bytes
end

-- read_speaker_sides() -> array of side names.  Reads /speakers.txt (written by
-- run.ps1); falls back to the single "back" speaker when the file is absent or
-- unreadable, so a hand-run of this script keeps working.
local function read_speaker_sides()
  if type(fs) ~= "table" or type(fs.exists) ~= "function"
    or type(fs.open) ~= "function" then
    return DEFAULT_SPEAKER_SIDES
  end
  if not fs.exists(SPEAKER_SIDES_PATH) then
    return DEFAULT_SPEAKER_SIDES
  end
  local handle = fs.open(SPEAKER_SIDES_PATH, "r")
  if handle == nil then
    return DEFAULT_SPEAKER_SIDES
  end
  local content = handle.readAll()
  handle.close()

  local sides = {}
  for token in tostring(content):gmatch("[^,%s]+") do
    sides[#sides + 1] = token
  end
  if #sides == 0 then
    return DEFAULT_SPEAKER_SIDES
  end
  return sides
end

-- emit_assignment(assignment, records): write the fan-out decision to
-- result.txt as greppable summary lines.  These are NOT CALL lines; the
-- projection comparator ignores them, and they let the failure/edge specs assert
-- the routing, the drop identities and the real warning args.
local function emit_assignment(assignment, records)
  local warning = "-"
  if assignment.warning_code ~= nil then
    warning = tostring(assignment.warning_code)
  end
  record_line(string.format("ASSIGN required=%s found=%s dropped=%s warning=%s",
    tostring(assignment.required), tostring(assignment.found),
    tostring(assignment.dropped), warning))

  if assignment.warning_args ~= nil then
    local args = assignment.warning_args
    record_line(string.format(
      "WARGS peak=%s required=%s found=%s dropped=%s",
      tostring(args.peak), tostring(args.required),
      tostring(args.found), tostring(args.dropped)))
  end

  for index = 1, #records do
    local side = records[index].side
    local bucket = assignment.by_speaker[side]
    local count = 0
    if bucket ~= nil then
      count = #bucket
    end
    record_line(string.format("SPLIT %s %d", tostring(side), count))
  end

  for index = 1, #assignment.dropped_events do
    local event = assignment.dropped_events[index]
    record_line(string.format("DROPPED tick=%s layer=%s note=%s kind=%s",
      tostring(event.tick_index), tostring(event.layer_index),
      tostring(event.note_index), tostring(event.kind)))
  end
end

-- main(): reproduce a whole playback on the real modules.
local function main()
  install_peripheral_recorder()

  local sides = read_speaker_sides()

  -- Attach the emulated speakers.  Guarded so the script is harmless where
  -- periphemu is absent.
  if type(periphemu) == "table" and type(periphemu.create) == "function" then
    for index = 1, #sides do
      periphemu.create(sides[index], "speaker")
    end
  end

  local bytes = read_fixture()

  -- Load the REAL player code.  This harness deliberately drives the lower-level
  -- FROZEN modules directly rather than a top-level entry point (which is still
  -- under concurrent development), so the recording sits on stable interfaces:
  --     nbs.decode -> nbs.analyze -> player.plan -> player.dispatch
  -- onto a player/speaker record discovered from the live peripheral, with a
  -- player/clock virtual clock feeding player/tempo for scheduling.
  local decode = require("nbs.decode")
  local analyze = require("nbs.analyze")
  local plan = require("player.plan")
  local fanout = require("player.fanout")
  local dispatch = require("player.dispatch")
  local speaker = require("player.speaker")
  local clock = require("player.clock")
  local tempo = require("player.tempo")
  local warnings = require("player.warnings")

  local decoded = decode.decode(bytes)
  if not decoded.ok then
    local detail = "unknown"
    if decoded.error ~= nil then
      detail = tostring(decoded.error.code) .. " " .. tostring(decoded.error.msg)
    end
    error("decode failed: " .. detail, 0)
  end

  local analysis = analyze.analyze(decoded.song)
  local events = plan.plan(decoded.song, analysis)

  local records = speaker.discover()
  if #records == 0 then
    error("no speaker peripheral discovered (requested sides: "
      .. table.concat(sides, ",") .. ")", 0)
  end

  -- THE REAL ALLOCATOR decides which speaker owns each event and which events
  -- are DROPPED.  The harness then walks the events in the same frozen
  -- (tick, layer, note) order and dispatches each one to its owner -- so a drop
  -- here is a real player decision, not an emulator per-tick budget refusal.
  local assignment = fanout.assign(events, analysis, records)
  emit_assignment(assignment, records)

  local record_by_side = {}
  for index = 1, #records do
    record_by_side[records[index].side] = records[index]
  end

  -- Recover each event's owner by consuming the assignment's by_speaker buckets
  -- with a per-side cursor and matching the event BY IDENTITY -- exactly the
  -- rule tests/tier2/assert_order.lua projects with, so recording and projection
  -- cannot drift.
  local cursors = {}
  local function owner_side(event)
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

  local dispatcher = dispatch.new()
  local vclock = clock.new_virtual(0)

  local function on_event(event)
    local side = owner_side(event)
    if side == nil then
      -- Dropped by the allocator: it must make NO speaker call at all.
      return
    end
    local result = dispatcher:event(event, record_by_side[side])
    if result.error_message ~= nil then
      error(result.error_message, 0)
    end
  end

  local scheduler = tempo.new({ clock = vclock, on_event = on_event })
  scheduler:play(events, on_event)

  -- Advance the virtual clock synchronously past the last event.  Nothing here
  -- waits in real time for the song.
  local end_ms = 0
  for index = 1, #events do
    if events[index].t_ms > end_ms then
      end_ms = events[index].t_ms
    end
  end
  clock.advance_to(vclock, end_ms + 1)

  if #vclock.errors > 0 then
    error("a scheduled callback raised: "
      .. tostring(vclock.errors[1].message), 0)
  end

  local stats = scheduler:stats()
  if stats.ticks_scheduled ~= #events then
    error(string.format("scheduled %d of %d planned events",
      stats.ticks_scheduled, #events), 0)
  end

  -- Render the warnings the REAL dispatcher emitted (bare codes) through the
  -- REAL renderer, and add the load-time extended-range warning the analysis
  -- carries.  Each code is rendered at most once.
  local warn_lines = {}
  local renderer = warnings.new({
    emit = function(line)
      warn_lines[#warn_lines + 1] = line
    end,
  })
  local codes = dispatcher:warnings()
  for index = 1, #codes do
    renderer:report(codes[index])
  end
  if analysis.has_extended_range then
    renderer:report(warnings.CODES.EXTENDED_RANGE,
      { min_key = analysis.min_key, max_key = analysis.max_key })
  end
  -- The fan-out allocator's own warning (a bare "speakers" code with the real
  -- {peak, required, found, dropped}) rendered through the same once-only seam.
  if assignment.warning_code ~= nil then
    renderer:report(assignment.warning_code, assignment.warning_args)
  end
  for index = 1, #warn_lines do
    record_line(warn_lines[index])
  end
end

-- ---------------------------------------------------------------------------
-- Entry point: run, record, shut down.  NOTHING may return without shutdown.
-- ---------------------------------------------------------------------------

local ok, failure = pcall(main)

-- Fixed teardown grace -- see the header.  Applied on EVERY path (success AND
-- failure) because a failure that followed a playNote would otherwise reach
-- os.shutdown with audio still queued and crash the process.  NOT a wait for
-- the song: playback was already driven to completion by the virtual clock.
os.sleep(AUDIO_DRAIN_SECONDS)

if ok then
  local wrote = write_result("ok")
  if not wrote then
    os.shutdown(1)
    return
  end
  os.shutdown(0)
  return
end

local wrote = write_result("fail:" .. collapse(failure))
if not wrote then
  -- Last resort: the file channel itself is broken.
  write_result("fail:could not write result: " .. collapse(failure))
end
os.shutdown(1)
