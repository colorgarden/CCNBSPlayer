-- player/tempo.lua
--
-- THE DRIFT-CORRECTED TEMPO SCHEDULER.
--
-- ---------------------------------------------------------------------------
-- WHY THIS MODULE EXISTS
-- ---------------------------------------------------------------------------
-- CC:Tweaked's timer primitive (os.startTimer -- used by the CC:T clock
-- adapter) rounds a requested delay UP to the next 0.05 s world tick.  A tempo
-- whose tick duration is NOT a multiple of 50 ms -- e.g. 15 ticks/second, i.e.
-- 66.667 ms per tick -- therefore CANNOT be represented exactly.  If a
-- scheduler repeatedly requested after(tick_ms) it would accumulate the
-- ~16.667 ms overshoot on every tick and the song would drift progressively
-- late: after 500 ticks the last event lands roughly 500 * 16.667 = 8.3 s past
-- where it belongs.
--
-- THE CUMULATIVE-IDEAL-TIMELINE RULE
-- ---------------------------------------------------------------------------
-- The scheduler never adds tick_ms to the previous delay.  Instead:
--
--   * An ANCHOR (start_ms = the clock reading when play() began) and a
--     MONOTONICALLY INCREASING index into the time-sorted event array are kept.
--   * For the next due event, ideal = start_ms + event.t_ms on the IDEAL
--     timeline, and the requested delay is (ideal - clock.now_ms()) / 1000.
--   * After the clock fires, the NEXT delay is recomputed from the ideal
--     timeline again -- never from the actual firing time.
--
-- A delay that was rounded UP is therefore compensated by a shorter next
-- request, so drift stays BOUNDED (about one rounding step) instead of growing
-- without limit.  This is the entire point of the module.
--
-- DELAYS BELOW THE TIMER GRANULARITY
-- ---------------------------------------------------------------------------
-- A required delay shorter than MIN_TIMER_MS (0.05 s) is still scheduled -- it
-- is neither silently rounded nor skipped -- but it is counted in
-- stats.clamped_ticks and reported ONCE per run via the optional warn callback
-- with the bare code CLAMP_WARN_CODE.  (On a virtual clock a sub-50 ms delay is
-- exact; on the real CC:T clock the primitive will round it up, hence the
-- warning.)
--
-- THE CLOCK SEAM AND ITS CALLING CONVENTION (VERIFIED TRAP)
-- ---------------------------------------------------------------------------
-- The clock is INJECTED through opts.clock; there is NO default.  Refusing to
-- silently grab the real clock is deliberate: it keeps this module testable and
-- every test honest.  This module never calls os.startTimer / os.sleep /
-- os.epoch / os.pullEvent itself -- the injected clock is the ONLY time source.
--
-- player/clock.lua's methods are DOT-style and take NO explicit self:
--     clock.after(vc, 0.1, fn)  or  vc.after(0.1, fn)   -- correct
--     vc:after(0.1, fn)                                  -- WRONG
-- Calling a clock method with a colon passes the clock as `delay_sec` and
-- fails.  This is the OPPOSITE of player/speaker.lua, whose methods DO take
-- self and are called with a colon -- the two seams do NOT share a convention.
-- By contrast this module's OWN frozen interface IS colon-style (t:play,
-- t:cancel, t:stats).  Do not let the clock's dot-style trip you up.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no blocking, no real sleeping.

local tempo = {}

-- The bare warning code emitted when a tick's delay is below MIN_TIMER_MS.
tempo.CLAMP_WARN_CODE = "tempo-clamp"

-- The os.startTimer world-tick granularity, in milliseconds.
tempo.MIN_TIMER_MS = 50

-- tempo.tick_ms(analysis) -> number
--
-- The nominal duration of one tick, exposed for consumers.  Analysis reports
-- ticks_per_second directly; the tempo itself is its reciprocal.
function tempo.tick_ms(analysis)
  return 1000 / analysis.ticks_per_second
end

-- stable_sort_by_t(events) -> array
--
-- Order events by ascending t_ms; events sharing a t_ms keep their original
-- ARRAY order (Lua's table.sort is not stable, so the original index is used
-- as the tie-break).  This is what lets the scheduler fire by ideal time while
-- preserving author-supplied order for simultaneous notes.
local function stable_sort_by_t(events)
  local indexed = {}
  for i = 1, #events do
    indexed[i] = { event = events[i], order = i }
  end
  table.sort(indexed, function(a, b)
    local ta = a.event.t_ms
    local tb = b.event.t_ms
    if ta ~= tb then
      return ta < tb
    end
    return a.order < b.order
  end)
  local sorted = {}
  for i = 1, #indexed do
    sorted[i] = indexed[i].event
  end
  return sorted
end

-- ---------------------------------------------------------------------------
-- Instance
-- ---------------------------------------------------------------------------

local Tempo = {}
Tempo.__index = Tempo

-- tempo.new(opts) -> t
--
--   opts.clock    REQUIRED.  The injected clock seam (see player/clock.lua).
--   opts.warn     optional function(code); called with a BARE code, at most
--                 once per code per run.
--   opts.on_event optional function(event); default callback for play().
local function new(opts)
  opts = opts or {}
  local clock_obj = opts.clock
  if clock_obj == nil then
    error("tempo.new: opts.clock is required (no default clock; refusing to "
      .. "silently grab the real clock)", 2)
  end
  if type(clock_obj.now_ms) ~= "function" or type(clock_obj.after) ~= "function" then
    error("tempo.new: opts.clock must provide now_ms() and after(delay_sec, fn)", 2)
  end

  local self = setmetatable({}, Tempo)
  self.clock = clock_obj
  self.warn = opts.warn
  self.on_event = opts.on_event

  self.events = {}
  self.run_callback = nil
  self.start_ms = 0
  self.index = 1
  self.handle = nil
  self.cancelled = false
  self.warned = false
  self.metrics = nil

  return self
end

-- _warn_once(): emit CLAMP_WARN_CODE at most once for the current run.
function Tempo:_warn_once()
  if self.warned then
    return
  end
  self.warned = true
  if self.warn ~= nil then
    self.warn(tempo.CLAMP_WARN_CODE)
  end
end

-- _schedule_next(): queue the next event's one-shot callback on the clock.
--
-- The delay is ALWAYS (ideal - now), recomputed from the cumulative ideal
-- timeline -- never tick_ms added to a previous delay.  This is the anti-drift
-- rule in action.
function Tempo:_schedule_next()
  if self.cancelled then
    return
  end
  if self.index > #self.events then
    return
  end

  local event = self.events[self.index]
  local ideal = self.start_ms + event.t_ms
  local now = self.clock.now_ms()
  local delay_ms = ideal - now

  if delay_ms < tempo.MIN_TIMER_MS then
    self.metrics.clamped_ticks = self.metrics.clamped_ticks + 1
    self:_warn_once()
  end

  local self_ref = self
  -- DOT call: clock methods take no explicit self (see header).
  self.handle = self.clock.after(delay_ms / 1000, function()
    self_ref:_on_fire()
  end)
end

-- _on_fire(): one event's deadline was reached.
--
-- Progress (index, tick count, drift, end times) is updated and the NEXT event
-- is queued BEFORE the user callback runs, so a raising on_event is captured by
-- the clock and cannot stop playback.
function Tempo:_on_fire()
  if self.cancelled then
    return
  end
  local index = self.index
  if index > #self.events then
    return
  end

  local event = self.events[index]
  local ideal = self.start_ms + event.t_ms
  local actual = self.clock.now_ms()
  local drift = math.abs(actual - ideal)
  if drift > self.metrics.max_drift_ms then
    self.metrics.max_drift_ms = drift
  end

  self.index = index + 1
  self.metrics.ticks_scheduled = self.metrics.ticks_scheduled + 1
  if index == #self.events then
    self.metrics.ideal_end_ms = ideal
    self.metrics.actual_end_ms = actual
  end

  -- Queue the next event from the ideal timeline BEFORE on_event: this bounds
  -- drift and keeps playback alive even if on_event raises.
  self:_schedule_next()

  if self.run_callback ~= nil then
    self.run_callback(event)
  end
end

-- t:play(events, on_event) -> handle
--
-- Begin scheduling.  Each event is placed at start_ms + event.t_ms on the IDEAL
-- timeline; simultaneous events fire in array order.  Does NOT block: it only
-- schedules on the injected clock and returns the handle (self).
function Tempo:play(events, on_event)
  -- Make play idempotent-safe: cancel any previous run before starting a new one.
  self:cancel()

  self.events = stable_sort_by_t(events or {})
  self.run_callback = on_event or self.on_event
  self.start_ms = self.clock.now_ms()
  self.index = 1
  self.handle = nil
  self.cancelled = false
  self.warned = false
  self.metrics = {
    ticks_scheduled = 0,
    ideal_end_ms = 0,
    actual_end_ms = 0,
    max_drift_ms = 0,
    clamped_ticks = 0,
  }

  self:_schedule_next()
  return self
end

-- t:cancel()
--
-- Stop scheduling; idempotent.  Cancels the one pending clock handle (if any)
-- and flips a flag that makes any in-flight callback a no-op.
function Tempo:cancel()
  self.cancelled = true
  if self.handle ~= nil and self.clock.cancel ~= nil then
    self.clock.cancel(self.handle)
  end
  self.handle = nil
end

-- t:stats() -> table
--
-- Live metrics for the current (or most recent) run.
function Tempo:stats()
  return self.metrics
end

tempo.new = new

return tempo
