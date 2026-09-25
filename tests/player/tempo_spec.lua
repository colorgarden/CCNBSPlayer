-- tests/player/tempo_spec.lua
--
-- Tier-1 spec for player/tempo.lua -- the DRIFT-CORRECTED TEMPO SCHEDULER.
-- Written FIRST, before player/tempo.lua exists (strict TDD: watch it fail).
--
-- WHY THIS MODULE EXISTS
-- ---------------------------------------------------------------------------
-- CC:Tweaked's os.startTimer(sec) (and os.sleep) round the requested delay UP
-- to the next 0.05 s world tick.  A tempo whose tick duration is NOT a multiple
-- of 50 ms -- e.g. 15 ticks/second -> 66.667 ms -- therefore cannot be
-- represented exactly.  A naive scheduler that repeatedly requests
-- after(tick_ms) accumulates the ~16.667 ms overshoot every tick and the song
-- drifts progressively late.  The fix is to schedule every tick against a
-- CUMULATIVE IDEAL timeline: tick N's deadline is start_ms + N*tick_ms, and the
-- requested delay is (ideal_deadline - now).  A rounded-up delay is compensated
-- by a shorter next request, so total drift stays BOUNDED instead of growing.
--
-- THE CLOCK CALLING-CONVENTION TRAP (VERIFIED BY EXECUTION)
-- ---------------------------------------------------------------------------
-- player/clock.lua methods are DOT-style: they do NOT take an explicit self.
--     vc.after(0.1, fn)      -- WORKS  (dot)
--     vc:after(0.1, fn)      -- FAILS  ("attempt to perform arithmetic on local
--                            --          'delay_sec' (a table value)")
-- This is the OPPOSITE of player/speaker.lua, whose record methods DO take self
-- and are called with a colon.  The two seams do NOT share a convention: do not
-- assume a clock object is colon-callable.  tempo.lua is also dot-style for its
-- own methods?  No -- tempo's FROZEN interface is colon-style (t:play, t:cancel,
-- t:stats) even though the clock it consumes is dot-style.  Mind the asymmetry.
--
-- FROZEN PUBLIC INTERFACE (asserted here)
--   local tempo = require("player.tempo")
--   tempo.new{ clock=, warn=, on_event= } -> t   (clock REQUIRED; no default)
--   t:play(events, on_event) -> handle           (never blocks)
--   t:cancel()                                   (idempotent)
--   t:stats() -> { ticks_scheduled, ideal_end_ms, actual_end_ms,
--                  max_drift_ms, clamped_ticks }
--   tempo.CLAMP_WARN_CODE = "tempo-clamp"
--   tempo.MIN_TIMER_MS    = 50
--   tempo.tick_ms(analysis) -> 1000 / analysis.ticks_per_second
--
-- No forbidden Cobalt constructs (no integer division, no bitwise operators,
-- no utf8).  The injected clock is the ONLY permitted time source.

local clock = require("player.clock")
local tempo = require("player.tempo")

-- ---------------------------------------------------------------------------
-- Project root (run.lua seeds package.path with "<root>/?.lua" first)
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

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a") or ""
  handle:close()
  return data
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- make_events(times): [{t_ms = times[i], id = i}, ...] in ARRAY order.
local function make_events(times)
  local events = {}
  for i = 1, #times do
    events[i] = { t_ms = times[i], id = i }
  end
  return events
end

-- rounding_clock(start_ms): a clock that wraps a virtual clock and rounds every
-- requested delay UP to the next 50 ms multiple, emulating os.startTimer's
-- 0.05 s world-tick quantisation.  The tiny epsilon treats a delay that is a
-- 50 ms multiple up to floating-point noise (e.g. 50.00000000000003) as that
-- multiple rather than overshooting it by a whole tick -- which is what the
-- real os.startTimer does for an exact multiple.  Returns wrapper, inner.
local function rounding_clock(start_ms)
  local inner = clock.new_virtual(start_ms)
  local wrapper = {}
  wrapper.errors = inner.errors

  function wrapper.now_ms()
    return inner.now_ms()
  end

  function wrapper.after(delay_sec, fn)
    local ms = delay_sec * 1000
    local steps = math.ceil(ms / 50 - 1e-6)
    if steps < 0 then
      steps = 0
    end
    return inner.after((steps * 50) / 1000, fn)
  end

  function wrapper.cancel(handle)
    return inner.cancel(handle)
  end

  function wrapper.run_due()
    return inner.run_due()
  end

  function wrapper.advance_to(target)
    return inner.advance_to(target)
  end

  return wrapper, inner
end

-- ---------------------------------------------------------------------------
-- Fake-global-os teardown (a guard, not a stub the module should ever need).
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 1. tick_ms
-- ---------------------------------------------------------------------------

describe("tempo.tick_ms", function()
  it("1. maps ticks-per-second to ms: 10 -> 100, 15 -> 1000/15, 20 -> 50", function()
    expect.equal(tempo.tick_ms({ ticks_per_second = 10 }), 100)
    expect.near(tempo.tick_ms({ ticks_per_second = 15 }), 1000 / 15, 1e-9)
    expect.equal(tempo.tick_ms({ ticks_per_second = 20 }), 50)
    io.write("    CASE-1 tick_ms(15)=" .. tostring(tempo.tick_ms({ ticks_per_second = 15 })) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. Exact virtual clock -> zero drift
-- ---------------------------------------------------------------------------

describe("tempo on an exact virtual clock", function()
  it("2. events at 0/100/200/300 ms all fire and max_drift_ms == 0", function()
    local vc = clock.new_virtual()
    local fired = {}
    local t = tempo.new({ clock = vc })

    t:play(make_events({ 0, 100, 200, 300 }), function(ev)
      fired[#fired + 1] = ev.t_ms
    end)

    clock.advance_to(vc, 1000)

    expect.sequence_equal(fired, { 0, 100, 200, 300 })
    expect.equal(t:stats().max_drift_ms, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. Scheduler orders by ideal time, not array position
-- ---------------------------------------------------------------------------

describe("tempo event ordering", function()
  it("3. event t_ms supplied 300,100,200 still fire in ascending time order", function()
    local vc = clock.new_virtual()
    local order = {}
    local t = tempo.new({ clock = vc })

    t:play(make_events({ 300, 100, 200 }), function(ev)
      order[#order + 1] = ev.t_ms
    end)

    clock.advance_to(vc, 1000)

    expect.sequence_equal(order, { 100, 200, 300 })
  end)

  it("4. two events sharing t_ms = 100 supplied A then B fire A then B", function()
    local vc = clock.new_virtual()
    local order = {}
    local t = tempo.new({ clock = vc })

    t:play({ { t_ms = 100, id = "A" }, { t_ms = 100, id = "B" } }, function(ev)
      order[#order + 1] = ev.id
    end)

    clock.advance_to(vc, 1000)

    expect.sequence_equal(order, { "A", "B" })
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. THE DRIFT TEST -- the reason this module exists.
-- ---------------------------------------------------------------------------

-- build_rounding_song(count): a count-event song, one event per 1000/15 ms
-- (66.667 ms), event i at t_ms = i * (1000/15).  Runs it on a rounding clock
-- and returns stats, the fired order, the observed end drift and the bare warn
-- codes collected from the scheduler.
local function run_rounding_song(count)
  local tick = tempo.tick_ms({ ticks_per_second = 15 }) -- 66.666...
  local events = {}
  for i = 0, count - 1 do
    events[i + 1] = { t_ms = i * tick, index = i }
  end

  local rc = rounding_clock(0)
  local fired = {}
  local warns = {}
  local t = tempo.new({
    clock = rc,
    warn = function(code) warns[#warns + 1] = code end,
  })
  t:play(events, function(ev) fired[#fired + 1] = ev.index end)
  clock.advance_to(rc, 1000000)

  local stats = t:stats()
  local end_drift = math.abs(stats.actual_end_ms - stats.ideal_end_ms)
  return stats, fired, tick, end_drift, warns
end

describe("tempo drift correction under os.startTimer-like rounding", function()
  it("5. 500 events at 66.667 ms stay within one tick of the ideal timeline", function()
    local count = 500
    local stats, fired, tick, end_drift, warns = run_rounding_song(count)

    -- Every event fired exactly once, in order.
    expect.equal(#fired, count)
    local in_order = true
    for i = 1, count do
      if fired[i] ~= i - 1 then
        in_order = false
      end
    end
    expect.equal(in_order, true)
    expect.equal(stats.ticks_scheduled, count)

    -- End drift under ONE tick.
    expect.truthy(end_drift < tick)

    -- The NAIVE alternative would have accumulated 16.667 ms of overshoot per
    -- tick (100 - 66.667) over 500 ticks = 8333.5 ms.  The corrected scheduler
    -- stays under ~one tick, proving the cumulative-ideal correction works.
    local naive_bound = count * 16.667
    expect.truthy(naive_bound > end_drift)

    -- B2 REGRESSION GUARD: 66.667 ms is ABOVE the 50 ms timer granularity, so
    -- the rounding clock's compensating delays are normal scheduling -- not a
    -- clamp.  The old delay-based rule counted them (167 of 500!) and warned.
    expect.equal(#warns, 0)
    expect.equal(stats.clamped_ticks, 0)

    io.write("    CASE-5 count=" .. count
      .. " tick_ms=" .. tostring(tick)
      .. " ideal_end_ms=" .. tostring(stats.ideal_end_ms)
      .. " actual_end_ms=" .. tostring(stats.actual_end_ms)
      .. " end_drift_ms=" .. tostring(end_drift)
      .. " naive_bound_ms=" .. tostring(naive_bound)
      .. " max_drift_ms=" .. tostring(stats.max_drift_ms)
      .. " clamped_ticks=" .. tostring(stats.clamped_ticks)
      .. " warns=" .. tostring(#warns) .. "\n")
  end)

  it("6. max_drift_ms is bounded by one rounding step (<= 50), not growing with index", function()
    local stats, _, _, _, warns = run_rounding_song(500)
    expect.truthy(stats.max_drift_ms <= 50)
    expect.equal(#warns, 0)
    io.write("    CASE-6 max_drift_ms=" .. tostring(stats.max_drift_ms)
      .. " (bound=50) clamped_ticks=" .. tostring(stats.clamped_ticks)
      .. " warns=" .. tostring(#warns) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. Clamp warning fires once; every event still fires
-- ---------------------------------------------------------------------------

describe("tempo clamp warning", function()
  it("7. 20 ms spacing -> clamped_ticks > 0, warn called exactly once, all events fire", function()
    local times = {}
    for i = 0, 9 do
      times[i + 1] = i * 20 -- spacing well below MIN_TIMER_MS
    end

    local warns = {}
    local vc = clock.new_virtual()
    local fired = {}
    local t = tempo.new({
      clock = vc,
      warn = function(code) warns[#warns + 1] = code end,
    })

    t:play(make_events(times), function(ev) fired[#fired + 1] = ev.t_ms end)
    clock.advance_to(vc, 100000)

    local stats = t:stats()
    expect.truthy(stats.clamped_ticks > 0)
    expect.equal(#warns, 1)
    expect.equal(warns[1], tempo.CLAMP_WARN_CODE)
    expect.equal(#fired, #times)

    io.write("    CASE-7 clamped_ticks=" .. tostring(stats.clamped_ticks)
      .. " warns=" .. tostring(#warns)
      .. " code=" .. tostring(warns[1])
      .. " fired=" .. tostring(#fired) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. No clock grabbed implicitly
-- ---------------------------------------------------------------------------

describe("tempo.new requires an injected clock", function()
  it("8. tempo.new({}) raises an error naming the missing clock option", function()
    local message = expect.raises(function()
      tempo.new({})
    end, "clock")
    io.write("    CASE-8 missing-clock error=" .. message .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. cancel stops scheduling (and is idempotent)
-- ---------------------------------------------------------------------------

describe("tempo cancel", function()
  it("9. cancel mid-run halts all later events; a second cancel is a no-op", function()
    local vc = clock.new_virtual()
    local fired = {}
    local t = tempo.new({ clock = vc })

    t:play(make_events({ 0, 100, 200, 300 }), function(ev)
      fired[#fired + 1] = ev.t_ms
    end)

    clock.advance_to(vc, 150) -- fires 0 and 100; 200/300 remain pending
    local before = #fired
    expect.equal(before, 2)

    t:cancel()
    local second = t:cancel() -- idempotent, returns nothing, must not raise

    clock.advance_to(vc, 1000000)

    expect.equal(#fired, before)
    expect.equal(second, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. stats shape
-- ---------------------------------------------------------------------------

describe("tempo stats shape", function()
  it("10. every field present and numeric; ticks_scheduled equals event count", function()
    local vc = clock.new_virtual()
    local t = tempo.new({ clock = vc })
    local events = make_events({ 0, 100, 200 })
    t:play(events, function() end)
    clock.advance_to(vc, 1000)

    local stats = t:stats()
    expect.equal(type(stats.ticks_scheduled), "number")
    expect.equal(type(stats.ideal_end_ms), "number")
    expect.equal(type(stats.actual_end_ms), "number")
    expect.equal(type(stats.max_drift_ms), "number")
    expect.equal(type(stats.clamped_ticks), "number")
    expect.equal(stats.ticks_scheduled, #events)
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. Empty event list
-- ---------------------------------------------------------------------------

describe("tempo empty plan", function()
  it("11. play({}) completes immediately with no callbacks and no raise", function()
    local vc = clock.new_virtual()
    local called = false
    local t = tempo.new({ clock = vc })

    t:play({}, function() called = true end)
    clock.advance_to(vc, 1000)

    expect.equal(t:stats().ticks_scheduled, 0)
    expect.equal(called, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. A raising on_event does not stop playback
-- ---------------------------------------------------------------------------

describe("tempo tolerates a raising on_event", function()
  it("12. remaining events still fire and the raise surfaces in vc.errors", function()
    local vc = clock.new_virtual()
    local calls = 0
    local fired = {}
    local t = tempo.new({ clock = vc })

    t:play(make_events({ 0, 100, 200 }), function(ev)
      calls = calls + 1
      if calls == 1 then
        error("boom-on-event")
      end
      fired[#fired + 1] = ev.t_ms
    end)

    clock.advance_to(vc, 1000)

    expect.equal(t:stats().ticks_scheduled, 3)
    expect.sequence_equal(fired, { 100, 200 })
    expect.equal(#vc.errors, 1)
    expect.contains(vc.errors[1].message, "boom-on-event")

    io.write("    CASE-12 ticks_scheduled=" .. tostring(t:stats().ticks_scheduled)
      .. " captured_errors=" .. tostring(#vc.errors) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. Determinism / purity of the ideal maths
-- ---------------------------------------------------------------------------

describe("tempo determinism", function()
  it("13. two runs with identical inputs and fresh clocks produce identical stats", function()
    local function run_once()
      local vc = clock.new_virtual()
      local t = tempo.new({ clock = vc })
      t:play(make_events({ 0, 100, 250 }), function() end)
      clock.advance_to(vc, 10000)
      return t:stats()
    end

    expect.deep_equal(run_once(), run_once())
  end)
end)

-- ---------------------------------------------------------------------------
-- Guard: the injected clock is the ONLY permitted time source.
-- ---------------------------------------------------------------------------

describe("tempo never touches the real clock", function()
  it("14. a fake global os whose every function raises is never called", function()
    local function forbidden(name)
      return function() error(name .. " must not be called by tempo") end
    end

    _G.os = {
      epoch = forbidden("os.epoch"),
      startTimer = forbidden("os.startTimer"),
      sleep = forbidden("os.sleep"),
      pullEvent = forbidden("os.pullEvent"),
    }

    local ok, err = pcall(function()
      local vc = clock.new_virtual()
      local t = tempo.new({ clock = vc })
      t:play(make_events({ 0, 50, 120 }), function() end)
      clock.advance_to(vc, 1000)
    end)

    -- Restore before asserting so a failure cannot leak the fake into later tests.
    _G.os = saved_os
    saved_os = nil

    expect.equal(ok, true)
    expect.equal(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- 15-18. B2: the clamp warning is driven by the NOMINAL tick interval, never
-- by an individual zero/negative delay (which just means "due now").
-- ---------------------------------------------------------------------------

describe("tempo clamp warning is driven by the nominal tick interval", function()
  it("15. two simultaneous events (a chord) -> zero clamps, NO tempo-clamp warning", function()
    -- delay_ms == 0 for the second note of the chord is NOT a clamp: the event
    -- is due now.  The old rule warned here on virtually every song.
    local vc = clock.new_virtual()
    local warns = {}
    local order = {}
    local t = tempo.new({
      clock = vc,
      warn = function(code) warns[#warns + 1] = code end,
    })

    t:play({ { t_ms = 100, id = "A" }, { t_ms = 100, id = "B" } }, function(ev)
      order[#order + 1] = ev.id
    end)
    clock.advance_to(vc, 1000)

    expect.equal(t:stats().clamped_ticks, 0)
    expect.equal(#warns, 0)
    expect.sequence_equal(order, { "A", "B" })
    expect.equal(t:stats().ticks_scheduled, 2)
    io.write("    CASE-15 chord clamped_ticks="
      .. tostring(t:stats().clamped_ticks) .. " warns=" .. tostring(#warns)
      .. " fired=" .. tostring(#order) .. "\n")
  end)

  it("16. a single event at t_ms = 0 (the first note of a song) -> zero clamps, no warning", function()
    local vc = clock.new_virtual()
    local warns = {}
    local fired = 0
    local t = tempo.new({
      clock = vc,
      warn = function(code) warns[#warns + 1] = code end,
    })

    t:play({ { t_ms = 0, id = "first" } }, function() fired = fired + 1 end)
    clock.advance_to(vc, 1000)

    expect.equal(t:stats().clamped_ticks, 0)
    expect.equal(#warns, 0)
    expect.equal(fired, 1)
    expect.equal(t:stats().ticks_scheduled, 1)
    io.write("    CASE-16 t0 clamped_ticks="
      .. tostring(t:stats().clamped_ticks) .. " warns=" .. tostring(#warns)
      .. " fired=" .. tostring(fired) .. "\n")
  end)

  it("17. a genuinely sub-granularity tempo (20 ms per tick) warns exactly once; every event fires", function()
    -- opts.tick_ms = 20 is BELOW the 50 ms world-tick granularity: the clock
    -- cannot represent the requested tempo, so the clamp is real and is
    -- reported once for the run.
    local times = {}
    for i = 0, 9 do
      times[i + 1] = i * 20
    end

    local vc = clock.new_virtual()
    local warns = {}
    local fired = {}
    local t = tempo.new({
      clock = vc,
      tick_ms = 20,
      warn = function(code) warns[#warns + 1] = code end,
    })

    t:play(make_events(times), function(ev) fired[#fired + 1] = ev.t_ms end)
    clock.advance_to(vc, 100000)

    local stats = t:stats()
    expect.truthy(stats.clamped_ticks > 0)
    expect.equal(#warns, 1)
    expect.equal(warns[1], tempo.CLAMP_WARN_CODE)
    expect.sequence_equal(fired, times)
    expect.equal(stats.ticks_scheduled, #times)
    io.write("    CASE-17 sub-granularity clamped_ticks="
      .. tostring(stats.clamped_ticks) .. " warns=" .. tostring(#warns)
      .. " code=" .. tostring(warns[1]) .. " fired=" .. tostring(#fired) .. "\n")
  end)

  it("18. a normal 100 ms tempo -> ZERO tempo-clamp warnings (the assertion that catches B2)", function()
    local times = {}
    for i = 0, 9 do
      times[i + 1] = i * 100
    end

    local vc = clock.new_virtual()
    local warns = {}
    local fired = {}
    local t = tempo.new({
      clock = vc,
      tick_ms = 100,
      warn = function(code) warns[#warns + 1] = code end,
    })

    t:play(make_events(times), function(ev) fired[#fired + 1] = ev.t_ms end)
    clock.advance_to(vc, 100000)

    expect.equal(#warns, 0)
    expect.equal(t:stats().clamped_ticks, 0)
    expect.sequence_equal(fired, times)
    expect.equal(t:stats().ticks_scheduled, #times)
    io.write("    CASE-18 normal clamped_ticks="
      .. tostring(t:stats().clamped_ticks) .. " warns=" .. tostring(#warns)
      .. " fired=" .. tostring(#fired) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 19-20. B4 backstop: a corrupt (non-finite or non-positive) tick interval
-- must fail LOUDLY here too, and a NaN deadline must never reach the clock.
-- ---------------------------------------------------------------------------

describe("tempo rejects a corrupt tick interval instead of scheduling a dead deadline", function()
  it("19. tempo.new refuses tick_ms = 0, negative, NaN and infinity", function()
    local bad_values = { 0, -20, 0 / 0, math.huge }
    for index = 1, #bad_values do
      local vc = clock.new_virtual()
      local called, err = pcall(function()
        tempo.new({ clock = vc, tick_ms = bad_values[index] })
      end)
      expect.equal(called, false)
      expect.equal(type(err), "table")
      expect.equal(err.code, "E_BAD_TICK_MS")
      expect.truthy(type(err.msg) == "string" and #err.msg > 0)
      io.write("    CASE-19 refused tick_ms=" .. tostring(bad_values[index])
        .. " code=" .. tostring(err.code) .. "\n")
    end
  end)

  it("20. play refuses a non-finite event deadline: nothing is scheduled, nothing can hang", function()
    local vc = clock.new_virtual()
    local t = tempo.new({ clock = vc })

    local called, err = pcall(function()
      t:play({ { t_ms = 0 / 0, id = 1 } }, function() end)
    end)

    expect.equal(called, false)
    expect.equal(type(err), "table")
    expect.equal(err.code, "E_BAD_DELAY")
    expect.truthy(type(err.msg) == "string" and #err.msg > 0)

    -- The refusal happened BEFORE any clock request: advancing forever runs
    -- zero callbacks (contrast the pre-fix behaviour: a deadline that never
    -- fires).
    expect.equal(clock.advance_to(vc, 1000000), 0)
    expect.equal(t:stats().ticks_scheduled, 0)
    io.write("    CASE-20 refused NaN deadline code=" .. tostring(err.code)
      .. " callbacks=0\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 21. B4 positive control: a REAL in-range fixture still plays end to end.
-- ---------------------------------------------------------------------------

describe("tempo end-to-end on a real fixture (positive control)", function()
  it("21. v4.nbs decodes, plans and plays every event with no clamp warning", function()
    local decode = require("nbs.decode")
    local analyze = require("nbs.analyze")
    local plan = require("player.plan")

    local bytes = read_file(join(ROOT, "tests/fixtures/v4.nbs"))
    expect.truthy(bytes ~= nil)

    local decoded = decode.decode(bytes)
    expect.equal(decoded.ok, true)

    local analysis = analyze.analyze(decoded.song)
    local events = plan.plan(decoded.song, analysis)
    expect.truthy(#events > 0)

    local vc = clock.new_virtual()
    local warns = {}
    local fired = 0
    local t = tempo.new({
      clock = vc,
      tick_ms = analysis.tick_ms,
      warn = function(code) warns[#warns + 1] = code end,
    })
    t:play(events, function() fired = fired + 1 end)

    clock.advance_to(vc, events[#events].t_ms + 1)

    expect.equal(fired, #events)
    expect.equal(t:stats().ticks_scheduled, #events)
    expect.equal(t:stats().clamped_ticks, 0)
    expect.equal(#warns, 0)
    io.write("    CASE-21 v4.nbs tick_ms=" .. tostring(analysis.tick_ms)
      .. " events=" .. tostring(#events) .. " fired=" .. tostring(fired)
      .. " warns=" .. tostring(#warns) .. "\n")
  end)
end)
