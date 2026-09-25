-- tests/player/runtime_spec.lua
--
-- Tier-1 spec for player/runtime.lua -- the TERMINATE-PROTECTION seam.
--
-- In CC:Tweaked, os.pullEvent AUTO-TERMINATES the program when the user presses
-- Ctrl+T: it aborts with a "Terminated" error and every cleanup step is skipped,
-- leaving audio queued on the speakers and the transport in an undefined state.
-- os.pullEventRaw returns the "terminate" event to the caller instead, so the
-- program can stop its speakers before unwinding. player/runtime.lua owns that
-- discipline in ONE place.
--
-- This spec pins the FROZEN PUBLIC INTERFACE:
--   runtime.run(body, opts) -> { terminated = bool, result = any, error = str|nil }
--   runtime.cleanup(speakers, session) -> integer   (speakers stopped)
--   runtime.stop_speakers(speakers)    -> integer   (speakers stopped)
--
-- CONTRACT implemented by runtime.run (pinned by case 2):
--   * `body` is called as body(pull), where `pull` is the resolved event source:
--     opts.pull when supplied, else the global os.pullEventRaw read LAZILY at
--     call time. A body that wants to wait for events calls the pull it was
--     handed. If that call yields "terminate" as its first value, run unwinds
--     the body and runs cleanup.
--   * A terminate raised inside body (a real Ctrl+T landing mid-body) is caught
--     by shape: any raised error whose message contains "terminate" (case
--     insensitive) is a terminate.
--   * Any OTHER raised error is recorded in `error` and still runs cleanup, but
--     is NOT reported as a terminate.
--   * run NEVER re-raises.
--
-- Isolation: every test runs with os.pullEventRaw cleared (before_each) and the
-- previous value restored (after_each), so the global never leaks between specs.

local runtime = require("player.runtime")
local speaker = require("player.speaker")

-- ---------------------------------------------------------------------------
-- Project root + file helpers (same convention as tests/player/speaker_spec.lua)
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

-- ---------------------------------------------------------------------------
-- Global isolation: os.pullEventRaw
-- ---------------------------------------------------------------------------

local saved_pull = nil

before_each(function()
  saved_pull = os.pullEventRaw
  rawset(os, "pullEventRaw", nil)
end)

after_each(function()
  rawset(os, "pullEventRaw", saved_pull)
end)

-- ---------------------------------------------------------------------------
-- Test doubles
-- ---------------------------------------------------------------------------

-- A speaker record whose stop() appends "stop:<side>" to an ordered log.
local function logging_speaker(side, log)
  local record = { side = side, stops = 0 }
  function record.stop(self)
    record.stops = record.stops + 1
    log[#log + 1] = "stop:" .. tostring(side)
    return true
  end
  return record
end

-- A speaker record whose stop() RAISES, to prove one bad speaker cannot block
-- the others.
local function raising_speaker(side)
  local record = { side = side }
  function record.stop(self)
    error("speaker " .. tostring(side) .. " exploded while stopping", 2)
  end
  return record
end

-- A session double with a :cancel() method.
local function fake_session()
  local session = { cancelled = 0 }
  function session.cancel(self)
    session.cancelled = session.cancelled + 1
  end
  return session
end

-- ---------------------------------------------------------------------------
-- 1-6. runtime.run -- the terminate / error decision table
-- ---------------------------------------------------------------------------

describe("runtime.run", function()
  it("1. normal completion returns the body result and does NOT clean up", function()
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local session = fake_session()

    local outcome = runtime.run(function()
      return "done"
    end, { speakers = { left, right }, session = session })

    expect.equal(outcome.terminated, false)
    expect.equal(outcome.result, "done")
    expect.equal(outcome.error, nil)
    -- Cleanup must not run on the happy path.
    expect.equal(#left.calls, 0)
    expect.equal(#right.calls, 0)
    expect.equal(session.cancelled, 0)

    io.write("    CASE1 normal: terminated=false result=\"done\" stops=0/0\n")
  end)

  it("2. terminate observed through opts.pull stops every speaker and cancels the session", function()
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local session = fake_session()
    local on_terminate_called = false

    local outcome = runtime.run(function(pull)
      pull()
      return "unreachable"
    end, {
      speakers = { left, right },
      session = session,
      pull = function()
        return "terminate"
      end,
      on_terminate = function()
        on_terminate_called = true
      end,
    })

    expect.equal(outcome.terminated, true)
    expect.equal(outcome.error, nil)
    -- Exactly one stop per speaker.
    expect.equal(#left.calls, 1)
    expect.equal(left.calls[1].method, "stop")
    expect.equal(#right.calls, 1)
    expect.equal(right.calls[1].method, "stop")
    -- Session cancelled exactly once, and on_terminate ran.
    expect.equal(session.cancelled, 1)
    expect.equal(on_terminate_called, true)

    io.write("    CASE2 terminate via pull: left.stops=1 right.stops=1 "
      .. "session.cancel=1 terminated=true\n")
  end)

  it("3. terminate raised inside body is caught, cleaned up and NOT re-raised", function()
    local left = speaker.mock("left")

    local outcome = runtime.run(function()
      error("Terminated")
    end, { speakers = { left } })

    expect.equal(outcome.terminated, true)
    expect.equal(outcome.error, nil)
    expect.equal(#left.calls, 1)
    expect.equal(left.calls[1].method, "stop")

    io.write("    CASE3 raised Terminated: terminated=true left.stops=1 re-raised=false\n")
  end)

  it("4. a real Ctrl+T error string variant is still treated as a terminate", function()
    local left = speaker.mock("left")

    local outcome = runtime.run(function()
      error("Terminated: press Ctrl+T")
    end, { speakers = { left } })

    expect.equal(outcome.terminated, true)
    expect.equal(outcome.error, nil)
    expect.equal(#left.calls, 1)

    io.write("    CASE4 raised \"Terminated: press Ctrl+T\": terminated=true left.stops=1\n")
  end)

  it("5. a non-terminate error still cleans up and is reported in error", function()
    local left = speaker.mock("left")
    local right = speaker.mock("right")

    local outcome = runtime.run(function()
      error("something else")
    end, { speakers = { left, right } })

    expect.truthy(type(outcome.error) == "string")
    expect.contains(outcome.error, "something else")
    -- Cleanup is NOT skipped on a crash: speakers must not be left queued.
    expect.equal(#left.calls, 1)
    expect.equal(left.calls[1].method, "stop")
    expect.equal(#right.calls, 1)
    expect.equal(right.calls[1].method, "stop")

    io.write("    CASE5 non-terminate error: error=\"" .. outcome.error
      .. "\" left.stops=1 right.stops=1\n")
  end)

  it("6. cleanup-on-error is NOT reported as a terminate", function()
    local left = speaker.mock("left")

    local outcome = runtime.run(function()
      error("something else")
    end, { speakers = { left } })

    expect.equal(outcome.terminated, false)
    expect.equal(#left.calls, 1)

    io.write("    CASE6 error path: terminated=false (distinct from terminate)\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 7-8. Module isolation and the injectable event seam
-- ---------------------------------------------------------------------------

describe("runtime module isolation", function()
  it("7. requires cleanly with no os.pullEventRaw present (no load-time read)", function()
    rawset(os, "pullEventRaw", nil)

    local cached = package.loaded["player.runtime"]
    package.loaded["player.runtime"] = nil
    local called, fresh = pcall(require, "player.runtime")
    package.loaded["player.runtime"] = cached or fresh

    if not called then
      error("require(\"player.runtime\") raised without os.pullEventRaw: "
        .. tostring(fresh), 2)
    end
    expect.equal(type(fresh), "table")

    -- A run that never touches the event source still works with no global.
    local outcome = fresh.run(function()
      return 7
    end, {})
    expect.equal(outcome.result, 7)

    io.write("    CASE7 no-global require + run: OK (result=7)\n")
  end)

  it("8. opts.pull is used and the global os.pullEventRaw is never called", function()
    rawset(os, "pullEventRaw", function()
      error("global os.pullEventRaw must not be called when opts.pull is supplied")
    end)

    local outcome = runtime.run(function(pull)
      return pull()
    end, {
      pull = function()
        return "key", 42
      end,
    })

    expect.equal(outcome.terminated, false)
    expect.equal(outcome.result, "key")

    io.write("    CASE8 injected seam used: result=\"key\" (global untouched)\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 9-13. Defensive cleanup helpers
-- ---------------------------------------------------------------------------

describe("runtime.stop_speakers / runtime.cleanup", function()
  it("9. a raising speaker does not block the others", function()
    local broken = raising_speaker("left")
    local healthy = speaker.mock("right")

    local stopped = runtime.stop_speakers({ broken, healthy })

    expect.equal(stopped, 1)
    -- The healthy speaker WAS stopped despite the earlier raise.
    expect.equal(#healthy.calls, 1)
    expect.equal(healthy.calls[1].method, "stop")

    io.write("    CASE9 raising speaker: stopped=1 healthy.stops=1 propagated=false\n")
  end)

  it("10. cleanup with no session does not raise", function()
    local left = speaker.mock("left")

    local called, stopped = pcall(runtime.cleanup, { left }, nil)

    expect.truthy(called)
    expect.equal(stopped, 1)
    expect.equal(#left.calls, 1)

    io.write("    CASE10 cleanup(nil session): OK stopped=1\n")
  end)

  it("11. on_terminate runs only AFTER every speaker has been stopped", function()
    local log = {}
    local left = logging_speaker("left", log)
    local right = logging_speaker("right", log)

    runtime.run(function()
      error("Terminated")
    end, {
      speakers = { left, right },
      on_terminate = function()
        log[#log + 1] = "on_terminate"
      end,
    })

    expect.equal(log[#log], "on_terminate")

    -- Every "stop:<side>" entry must precede the "on_terminate" entry.
    local last_stop_index = 0
    for index = 1, #log do
      if log[index]:sub(1, 5) == "stop:" then
        last_stop_index = index
      end
    end
    expect.truthy(last_stop_index > 0)
    expect.truthy(last_stop_index < #log)

    io.write("    CASE11 order: " .. table.concat(log, " -> ") .. "\n")
  end)

  it("12. zero speakers behaves normally and cleanup returns 0", function()
    local outcome = runtime.run(function()
      return "quiet"
    end, { speakers = {} })

    expect.equal(outcome.terminated, false)
    expect.equal(outcome.result, "quiet")

    local stopped = runtime.cleanup({}, nil)
    expect.equal(stopped, 0)

    io.write("    CASE12 zero speakers: run ok cleanup=0\n")
  end)

  it("13. stop_speakers returns the count and never touches a session", function()
    local left = speaker.mock("left")
    local right = speaker.mock("right")

    local stopped = runtime.stop_speakers({ left, right })

    expect.equal(stopped, 2)
    expect.equal(#left.calls, 1)
    expect.equal(#right.calls, 1)

    io.write("    CASE13 stop_speakers alone: stopped=2\n")
  end)
end)
