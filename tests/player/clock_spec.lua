-- tests/player/clock_spec.lua
--
-- Tier-1 spec for player/clock.lua -- the INJECTABLE CLOCK SEAM.
--
-- WHY THIS SEAM MUST EXIST
-- ---------------------------------------------------------------------------
-- CraftOS-PC gives us NO way to control or fake time: os.clock, os.epoch,
-- os.time and os.day all read the real system clock directly.  Without a seam
-- the tempo scheduler would have to sleep for real, so a three-minute song
-- would take three minutes to test and every timing assertion would be flaky
-- by construction.  Determinism can therefore come ONLY from injecting a
-- clock.  This module is the ONE place in the project allowed to touch the
-- game clock (os.epoch / os.startTimer / os.sleep); every other module takes a
-- clock value as a parameter.
--
-- FROZEN PUBLIC INTERFACE (the tempo scheduler and the runtime depend on it):
--   local clock = require("player.clock")
--
--   -- A clock is a table with:
--   --   now_ms()               -> number, monotonically non-decreasing ms
--   --   after(delay_sec, fn)   -> handle, schedule fn once after delay_sec
--   --   cancel(handle)         -> boolean, true iff the handle was pending
--   --   run_due()              -> integer, run every callback now due
--   --   (CC:T adapter only) sleep_until(deadline_ms) -> blocks to deadline
--
--   clock.new_virtual(start_ms) -> <virtual clock>   -- deterministic
--   clock.new_os()              -> <CC:T clock>       -- wraps the real clock
--   clock.advance_to(vclock, target_ms) -> integer    -- advance a virtual
--                                          clock, running due callbacks in
--                                          deadline order; returns how many ran
--
-- VIRTUAL CLOCK SEMANTICS PINNED HERE
-- ---------------------------------------------------------------------------
--   * Each handle records an ABSOLUTE deadline at scheduling time:
--         deadline = now_ms() + delay_sec * 1000
--   * advance_to(target) fires every handle whose deadline is <= target, in
--     ASCENDING DEADLINE order; identical deadlines fire in scheduling order
--     (stable).  The comparison is INCLUSIVE, so a callback due at exactly
--     target fires.
--   * advance_to advances in steps and re-scans after each callback, so a
--     callback that schedules a NEW callback due inside the same interval is
--     still honoured.  This is essential: the tempo scheduler reschedules
--     itself from inside a callback.
--   * now_ms() moves ONLY when advance_to runs; it NEVER reads the real clock.
--   * advance_to with a target EARLIER than the current time is a no-op that
--     returns 0 -- the clock never goes backwards.
--   * cancel(h) is true iff h was still pending (neither fired nor cancelled);
--     a second cancel, or a cancel after firing, is false.
--   * A raising callback is CAUGHT, recorded in vclock.errors (entries of the
--     shape { message = <string>, deadline = <number>, seq = <number> }), and
--     never propagates out of run_due / advance_to -- one bad callback must not
--     corrupt or wedge the clock.
--
-- CC:T ADAPTER SEMANTICS PINNED HERE
-- ---------------------------------------------------------------------------
--   new_os() reads the global `os` ONLY inside its functions, so the module is
--   requireable in plain Lua where os.epoch may not exist.  now_ms() uses
--   os.epoch("ingame"); after(delay_sec, fn) uses os.startTimer(delay_sec);
--   run_due() drains `timer` events via os.pullEvent("timer").  os.startTimer
--   rounds UP to the 0.05 s world tick, so the adapter's timing is only
--   APPROXIMATE and the tempo module compensates; sleep_until(deadline_ms)
--   converts the remaining milliseconds to seconds and calls os.sleep (clamped
--   at 0), letting the scheduler block precisely instead of spinning.
--
--   The adapter is deliberately NOT exercised in a way that blocks: there is no
--   real event pump in plain Lua.  Cases 12/13 install a fake GLOBAL os and
--   assert only construction, interface shape, and argument arithmetic; the
--   fake is restored in after_each.
--
-- No forbidden Cobalt constructs (no integer division, no bitwise operators).

local clock = require("player.clock")

-- ---------------------------------------------------------------------------
-- Fake-global-os teardown
-- ---------------------------------------------------------------------------
-- The runner only fires after_each when a test PASSES, so a failing stubbing
-- test could otherwise leak the fake.  before_each therefore re-installs the
-- saved global first, then saves the (real) global again; after_each restores.
local saved_os = nil

before_each(function()
  if saved_os ~= nil then
    _G.os = saved_os
    saved_os = nil
  end
  saved_os = _G.os
end)

after_each(function()
  if saved_os ~= nil then
    _G.os = saved_os
    saved_os = nil
  end
end)

-- install_fake_os(fake): replaces the global `os` for the current test.
local function install_fake_os(fake)
  _G.os = fake
  return fake
end

-- ---------------------------------------------------------------------------
-- 1. Monotonic start
-- ---------------------------------------------------------------------------

describe("clock.new_virtual monotonic start", function()
  it("1. defaults to 0 ms and honours an explicit start", function()
    local fresh = clock.new_virtual()
    expect.equal(fresh.now_ms(), 0)

    local later = clock.new_virtual(5000)
    expect.equal(later.now_ms(), 5000)
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. Firing order across distinct deadlines
-- ---------------------------------------------------------------------------

describe("virtual clock firing order", function()
  it("2. 300/100/200 ms fire in deadline order 100, 200, 300", function()
    local vc = clock.new_virtual()
    local order = {}

    vc.after(0.3, function() order[#order + 1] = 300 end)
    vc.after(0.1, function() order[#order + 1] = 100 end)
    vc.after(0.2, function() order[#order + 1] = 200 end)

    local ran = clock.advance_to(vc, 1000)

    expect.equal(ran, 3)
    expect.sequence_equal(order, { 100, 200, 300 })
    io.write("    CASE-2 order=[100,200,300] ran=" .. ran
      .. " now=" .. vc.now_ms() .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. Not before the deadline
-- ---------------------------------------------------------------------------

describe("virtual clock does not fire early", function()
  it("3. advance_to(99) runs none of the 100/200/300 ms callbacks", function()
    local vc = clock.new_virtual()
    local ran_count = 0
    local function bump() ran_count = ran_count + 1 end

    vc.after(0.1, bump)
    vc.after(0.2, bump)
    vc.after(0.3, bump)

    local ran = clock.advance_to(vc, 99)

    expect.equal(ran, 0)
    expect.equal(ran_count, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. Inclusive deadline comparison
-- ---------------------------------------------------------------------------

describe("virtual clock deadline is inclusive", function()
  it("4. a callback due at exactly 200 ms fires on advance_to(200)", function()
    local vc = clock.new_virtual()
    local fired = false

    vc.after(0.2, function() fired = true end)

    local ran = clock.advance_to(vc, 200)

    expect.equal(ran, 1)
    expect.equal(fired, true)
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. Stable order for identical deadlines
-- ---------------------------------------------------------------------------

describe("virtual clock stable order", function()
  it("5. three callbacks sharing a deadline fire in scheduling order", function()
    local vc = clock.new_virtual()
    local order = {}

    vc.after(0.1, function() order[#order + 1] = 1 end)
    vc.after(0.1, function() order[#order + 1] = 2 end)
    vc.after(0.1, function() order[#order + 1] = 3 end)

    clock.advance_to(vc, 1000)

    expect.sequence_equal(order, { 1, 2, 3 })
  end)
end)

-- ---------------------------------------------------------------------------
-- 6. Rescheduling INSIDE the same interval (the tempo scheduler's own pattern)
-- ---------------------------------------------------------------------------

describe("virtual clock reschedule inside an interval", function()
  it("6. a callback due at 100 ms schedules one at 150 ms; advance_to(200) runs BOTH", function()
    local vc = clock.new_virtual()
    local order = {}

    vc.after(0.1, function()
      order[#order + 1] = "first@100"
      vc.after(0.05, function()
        order[#order + 1] = "second@150"
      end)
    end)

    local ran = clock.advance_to(vc, 200)

    expect.equal(ran, 2)
    expect.sequence_equal(order, { "first@100", "second@150" })
    expect.equal(vc.now_ms(), 200)
    io.write("    CASE-6 order=[first@100,second@150] ran=" .. ran
      .. " now=" .. vc.now_ms() .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. run_due returns the number of callbacks it ran
-- ---------------------------------------------------------------------------

describe("virtual clock run_due count", function()
  it("7. a run that fires two callbacks returns 2; a later call returns 0", function()
    local vc = clock.new_virtual()

    vc.after(0, function() end)
    vc.after(0, function() end)

    expect.equal(vc.run_due(), 2)
    expect.equal(vc.run_due(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. cancel of a pending handle
-- ---------------------------------------------------------------------------

describe("virtual clock cancel pending", function()
  it("8. cancel returns true once, false the second time, and the callback never fires", function()
    local vc = clock.new_virtual()
    local fired = false

    local handle = vc.after(0.1, function() fired = true end)

    expect.equal(vc.cancel(handle), true)
    expect.equal(vc.cancel(handle), false)

    clock.advance_to(vc, 1000)
    expect.equal(fired, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. cancel after firing
-- ---------------------------------------------------------------------------

describe("virtual clock cancel after firing", function()
  it("9. cancelling a handle that already fired returns false", function()
    local vc = clock.new_virtual()

    local handle = vc.after(0.1, function() end)
    clock.advance_to(vc, 1000)

    expect.equal(vc.cancel(handle), false)
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. The clock never goes backwards
-- ---------------------------------------------------------------------------

describe("virtual clock never goes backwards", function()
  it("10. advance_to(400) after 1000 returns 0 and leaves now_ms() at 1000", function()
    local vc = clock.new_virtual()

    clock.advance_to(vc, 1000)

    expect.equal(clock.advance_to(vc, 400), 0)
    expect.equal(vc.now_ms(), 1000)
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. A raising callback is captured and does not break the clock
-- ---------------------------------------------------------------------------

describe("virtual clock tolerates a raising callback", function()
  it("11. the raise is captured in errors, other callbacks still run, time still advances", function()
    local vc = clock.new_virtual()
    local order = {}

    vc.after(0.1, function() order[#order + 1] = "a" end)
    vc.after(0.2, function() error("boom-42") end)
    vc.after(0.3, function() order[#order + 1] = "c" end)

    -- The raise must NOT propagate out of advance_to.
    local ok, ran = pcall(clock.advance_to, vc, 1000)

    expect.equal(ok, true)
    expect.equal(ran, 3)
    expect.sequence_equal(order, { "a", "c" })
    expect.equal(vc.now_ms(), 1000)
    expect.equal(#vc.errors, 1)
    expect.contains(vc.errors[1].message, "boom-42")
    expect.equal(vc.errors[1].deadline, 200)
    io.write("    CASE-11 captured errors=" .. #vc.errors
      .. " message=" .. vc.errors[1].message
      .. " now=" .. vc.now_ms() .. "\n")
  end)

  it("11b. run_due likewise captures the raise and keeps the clock usable", function()
    local vc = clock.new_virtual()

    vc.after(0, function() error("boom-run_due") end)
    vc.after(0, function() end)

    local ok, ran = pcall(vc.run_due, vc)

    expect.equal(ok, true)
    expect.equal(ran, 2)
    expect.equal(#vc.errors, 1)
    expect.contains(vc.errors[1].message, "boom-run_due")

    -- Still usable afterwards.
    local later = false
    vc.after(0.01, function() later = true end)
    clock.advance_to(vc, 100)
    expect.equal(later, true)
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. CC:T adapter construction, interface shape and now_ms/after arithmetic
-- ---------------------------------------------------------------------------

describe("clock.new_os adapter arithmetic", function()
  it("12. now_ms() reads os.epoch('ingame'); after(0.5, fn) calls os.startTimer(0.5)", function()
    local epoch_args = {}
    local timer_args = {}

    install_fake_os({
      epoch = function(what)
        epoch_args[#epoch_args + 1] = what
        return 12345
      end,
      startTimer = function(delay_sec)
        timer_args[#timer_args + 1] = delay_sec
        return 7
      end,
      sleep = function() end,
      pullEvent = function() return "timer", 7 end,
    })

    local adapter = clock.new_os()

    -- Interface shape.
    expect.equal(type(adapter.now_ms), "function")
    expect.equal(type(adapter.after), "function")
    expect.equal(type(adapter.cancel), "function")
    expect.equal(type(adapter.run_due), "function")
    expect.equal(type(adapter.sleep_until), "function")

    expect.equal(adapter.now_ms(), 12345)
    expect.sequence_equal(epoch_args, { "ingame" })

    local ran_early = false
    local handle = adapter.after(0.5, function() ran_early = true end)
    expect.sequence_equal(timer_args, { 0.5 })
    expect.equal(ran_early, false) -- after() only schedules; run_due dispatches
    expect.truthy(handle ~= nil)

    io.write("    CASE-12 epoch_args=[ingame] now_ms=12345 startTimer_args=[0.5]\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. sleep_until arithmetic (clamped at 0)
-- ---------------------------------------------------------------------------

describe("clock.new_os sleep_until arithmetic", function()
  it("13. now+250 ms sleeps 0.25 s; a past deadline sleeps 0 (never negative)", function()
    local sleep_args = {}

    install_fake_os({
      epoch = function() return 12345 end,
      startTimer = function() return 1 end,
      sleep = function(seconds) sleep_args[#sleep_args + 1] = seconds end,
      pullEvent = function() return "timer", 1 end,
    })

    local adapter = clock.new_os()

    adapter.sleep_until(adapter.now_ms() + 250)
    expect.near(sleep_args[1], 0.25, 1e-9)

    adapter.sleep_until(adapter.now_ms() - 100)
    expect.equal(sleep_args[2], 0)
    expect.truthy(sleep_args[2] >= 0)

    io.write("    CASE-13 sleep_args=[0.25, 0] (past deadline clamped)\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 14. Requireable and pure without a real os / without os.epoch
-- ---------------------------------------------------------------------------

describe("virtual clock never touches the real clock", function()
  it("14. require succeeds and a virtual clock works even when os.epoch raises", function()
    expect.truthy(clock ~= nil)
    expect.equal(type(clock.new_virtual), "function")

    local function forbidden(name)
      return function() error(name .. " must not be called by the virtual clock") end
    end

    install_fake_os({
      epoch = forbidden("os.epoch"),
      startTimer = forbidden("os.startTimer"),
      sleep = forbidden("os.sleep"),
      pullEvent = forbidden("os.pullEvent"),
    })

    local vc = clock.new_virtual(100)
    local fired = false
    vc.after(0.05, function() fired = true end)

    expect.equal(clock.advance_to(vc, 200), 1)
    expect.equal(fired, true)
    expect.equal(vc.now_ms(), 200)
  end)
end)

-- ---------------------------------------------------------------------------
-- 15. Zero-delay callback
-- ---------------------------------------------------------------------------

describe("virtual clock zero-delay callback", function()
  it("15. after(0, fn) fires on the next advance_to to the current time", function()
    local vc = clock.new_virtual(500)
    local fired = false

    vc.after(0, function() fired = true end)

    expect.equal(clock.advance_to(vc, 500), 1)
    expect.equal(fired, true)
    expect.equal(vc.now_ms(), 500)
  end)
end)
