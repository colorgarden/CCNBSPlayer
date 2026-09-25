-- player/clock.lua
--
-- THE INJECTABLE CLOCK SEAM.
--
-- ---------------------------------------------------------------------------
-- WHY THIS MODULE MUST EXIST
-- ---------------------------------------------------------------------------
-- CraftOS-PC offers NO way to control or fake the clock: os.clock, os.epoch,
-- os.time and os.day all read the real system clock directly.  If the tempo
-- scheduler called those primitives itself, determinism would be impossible:
-- testing a three-minute song would take three minutes of wall time and every
-- timing assertion would be flaky.  So time is a DEPENDENCY, injected as a
-- clock value:
--
--   * clock.new_virtual(start_ms) -> a deterministic clock that only moves when
--     the test advances it.  Tests drive a whole song instantly and assert on
--     exact milliseconds.
--   * clock.new_os() -> the production adapter over the game clock.
--
-- This module is the SOLE permitted caller of os.epoch, os.startTimer,
-- os.pullEvent (for timers) and os.sleep.  Every other module receives a clock
-- and must never reach for the real clock itself.
--
-- ---------------------------------------------------------------------------
-- CLOCK PROTOCOL
-- ---------------------------------------------------------------------------
--   now_ms()              -> number, monotonically non-decreasing milliseconds
--   after(delay_sec, fn)  -> handle, run fn once after delay_sec seconds
--   cancel(handle)        -> boolean, true iff the handle was still pending
--   run_due()             -> integer, run every callback already due
--   sleep_until(deadline_ms)   -- CC:T adapter only; see below
--
-- clock.advance_to(vclock, target_ms) -> integer
--   Advance a VIRTUAL clock to target_ms, running every callback whose
--   deadline has been reached, and return how many ran.  Callbacks fire in
--   ASCENDING DEADLINE order; handles sharing a deadline fire in scheduling
--   order (stable).  The comparison is INCLUSIVE.  advance_to advances in
--   steps and re-scans after each callback, so a callback that schedules a new
--   callback inside the same interval is still honoured -- this is exactly what
--   the tempo scheduler does when it reschedules itself from inside a callback.
--   A target EARLIER than the current time is a no-op returning 0; the clock
--   never goes backwards.  advance_to never sleeps.
--
-- ERROR POLICY
--   A raising callback is caught with pcall, appended to `<vclock>.errors`
--   (entries { message = <string>, deadline = <number>, seq = <number> }), and
--   NEVER propagates out of run_due / advance_to.  One bad callback must not
--   corrupt the clock or wedge the queue; the clock stays usable and the
--   captured errors let a test assert on exactly what went wrong.
--
-- ---------------------------------------------------------------------------
-- CC:T ADAPTER ROUNDING CAVEAT
-- ---------------------------------------------------------------------------
-- The adapter maps onto CC:Tweaked primitives:
--     now_ms()            = os.epoch("ingame")          -- integer ms
--     after(delay, fn)    = os.startTimer(delay)        -- timer id
--     run_due()           = os.pullEvent("timer") drain
--     sleep_until(d_ms)   = os.sleep(max(0, d_ms - now_ms()) / 1000)
--
-- CAVEAT: os.startTimer rounds its delay UP to the next 0.05 s (one world
-- tick) boundary, so the adapter's wake-ups are only APPROXIMATE -- a timer
-- requested for 0.13 s fires near 0.15 s.  The adapter therefore must not be
-- trusted for exact musical timing; the tempo scheduler compensates by
-- anchoring each tick to the clock and by sleeping to an absolute deadline with
-- sleep_until rather than accumulating relative delays.
--
-- new_os() reads the global `os` ONLY inside its functions, never at require
-- time, so this module can be required (and its virtual clock used) in plain
-- desktop Lua where os.epoch does not exist.  The unit tests never pump the
-- adapter's events (there is no event loop in plain Lua); they assert only its
-- construction, interface shape and argument arithmetic against a stubbed
-- global os.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no real sleeping inside the virtual clock.

local clock = {}

-- ---------------------------------------------------------------------------
-- Virtual (deterministic) clock
-- ---------------------------------------------------------------------------

-- clock.new_virtual(start_ms) -> virtual clock
--
-- start_ms defaults to 0.  The returned clock's now_ms() moves ONLY when
-- clock.advance_to (or run_due) is called; it never consults the real clock.
function clock.new_virtual(start_ms)
  if start_ms == nil then
    start_ms = 0
  end

  local state = {
    now = start_ms,
    pending = {}, -- array of handles
    seq = 0,      -- scheduling sequence, for stable ordering
  }

  local vclock = {}
  vclock.errors = {} -- captured callback errors, oldest first

  -- earliest_due(limit): the pending handle with the smallest (deadline, seq)
  -- whose deadline is <= limit, or nil.  Handles that fired or were cancelled
  -- are ignored.  Linear scan is fine: schedules here are tiny.
  local function earliest_due(limit)
    local best = nil
    for index = 1, #state.pending do
      local handle = state.pending[index]
      if not handle.fired and not handle.cancelled and handle.deadline <= limit then
        if best == nil
          or handle.deadline < best.deadline
          or (handle.deadline == best.deadline and handle.seq < best.seq) then
          best = handle
        end
      end
    end
    return best
  end

  -- drain(limit): run every handle due at or before `limit`, advancing state.now
  -- to each fired deadline along the way, and re-scanning after every callback
  -- so newly scheduled work inside the interval is honoured.  Returns the
  -- number of callbacks run.  Raises from callbacks are captured, not thrown.
  local function drain(limit)
    local ran = 0
    while true do
      local handle = earliest_due(limit)
      if handle == nil then
        break
      end
      handle.fired = true
      if handle.deadline > state.now then
        state.now = handle.deadline
      end
      local ok, err = pcall(handle.fn)
      if not ok then
        vclock.errors[#vclock.errors + 1] = {
          message = tostring(err),
          deadline = handle.deadline,
          seq = handle.seq,
        }
      end
      ran = ran + 1
    end
    return ran
  end

  -- advance(target): move the clock forward to `target`, running everything due.
  function vclock.advance_to(target)
    if target < state.now then
      return 0 -- never go backwards
    end
    local ran = drain(target)
    if target > state.now then
      state.now = target
    end
    return ran
  end

  function vclock.now_ms()
    return state.now
  end

  function vclock.after(delay_sec, fn)
    state.seq = state.seq + 1
    local handle = {
      deadline = state.now + delay_sec * 1000,
      seq = state.seq,
      fn = fn,
      fired = false,
      cancelled = false,
    }
    state.pending[#state.pending + 1] = handle
    return handle
  end

  function vclock.cancel(handle)
    if handle == nil or handle.fired or handle.cancelled then
      return false
    end
    handle.cancelled = true
    return true
  end

  function vclock.run_due()
    return drain(state.now)
  end

  return vclock
end

-- clock.advance_to(vclock, target_ms) -> integer
--
-- Module-level entry point required by the frozen interface.  Delegates to the
-- virtual clock's own advance_to; a non-virtual clock (e.g. the os adapter) has
-- no advance_to and is rejected loudly.
function clock.advance_to(vclock, target_ms)
  if type(vclock) ~= "table" or type(vclock.advance_to) ~= "function" then
    error("clock.advance_to: expected a clock returned by clock.new_virtual", 2)
  end
  return vclock.advance_to(target_ms)
end

-- ---------------------------------------------------------------------------
-- CC:T (CraftOS) adapter
-- ---------------------------------------------------------------------------

-- clock.new_os() -> clock over the real game clock
--
-- The global `os` is read inside each function (never captured at require
-- time), so this module loads in plain Lua.  Timing is approximate because
-- os.startTimer rounds up to the 0.05 s world tick -- see the header caveat.
function clock.new_os()
  local adapter = {}
  adapter.errors = {}

  -- timer_id -> handle, for the timers we created.
  local pending = {}

  local function active_count()
    local count = 0
    for _, handle in pairs(pending) do
      if not handle.fired and not handle.cancelled then
        count = count + 1
      end
    end
    return count
  end

  function adapter.now_ms()
    return os.epoch("ingame")
  end

  function adapter.after(delay_sec, fn)
    local timer_id = os.startTimer(delay_sec)
    local handle = {
      timer_id = timer_id,
      fn = fn,
      fired = false,
      cancelled = false,
    }
    pending[timer_id] = handle
    return handle
  end

  function adapter.cancel(handle)
    if handle == nil or handle.fired or handle.cancelled then
      return false
    end
    handle.cancelled = true
    if handle.timer_id ~= nil then
      pending[handle.timer_id] = nil
    end
    return true
  end

  -- run_due(): drain `timer` events and dispatch the matching pending handles
  -- until no active handle remains.  It blocks on os.pullEvent by design -- in
  -- game that is how the program waits.  A raise from a timer callback is
  -- captured into adapter.errors rather than propagating.
  function adapter.run_due()
    local ran = 0
    while active_count() > 0 do
      local _, timer_id = os.pullEvent("timer")
      local handle = pending[timer_id]
      if handle ~= nil then
        pending[timer_id] = nil
        if not handle.cancelled and not handle.fired then
          handle.fired = true
          local ok, err = pcall(handle.fn)
          if not ok then
            adapter.errors[#adapter.errors + 1] = { message = tostring(err) }
          end
          ran = ran + 1
        end
      end
    end
    return ran
  end

  -- sleep_until(deadline_ms): block until an absolute deadline.  The remaining
  -- delay is clamped at 0 so a past deadline never produces a negative sleep.
  function adapter.sleep_until(deadline_ms)
    local remaining = (deadline_ms - adapter.now_ms()) / 1000
    if remaining < 0 then
      remaining = 0
    end
    os.sleep(remaining)
  end

  return adapter
end

return clock
