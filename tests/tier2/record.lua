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
local SPEAKER_SIDE = "back"
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

-- main(): reproduce a whole playback on the real modules.
local function main()
  install_peripheral_recorder()

  -- Attach the emulated speaker.  Guarded so the script is harmless where
  -- periphemu is absent.
  if type(periphemu) == "table" and type(periphemu.create) == "function" then
    periphemu.create(SPEAKER_SIDE, "speaker")
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
  local dispatch = require("player.dispatch")
  local speaker = require("player.speaker")
  local clock = require("player.clock")
  local tempo = require("player.tempo")

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
    error("no speaker peripheral discovered (expected one on side '"
      .. SPEAKER_SIDE .. "')", 0)
  end

  local dispatcher = dispatch.new()
  local vclock = clock.new_virtual(0)

  local function on_event(event)
    local result = dispatcher:event(event, records[1])
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
