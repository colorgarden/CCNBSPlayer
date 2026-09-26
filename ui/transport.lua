-- ui/transport.lua
--
-- THE PLAYBACK BRIDGE THE NEW UI DRIVES (play / pause / resume / stop / seek +
-- progress).
--
-- ---------------------------------------------------------------------------
-- WHY THIS MODULE MUST EXIST
-- ---------------------------------------------------------------------------
-- The ccnbs library cannot pause and cannot seek.  `ccnbs.play(song_or_plan,
-- opts)` schedules on a clock and returns IMMEDIATELY, and the session it hands
-- back exposes only `cancel()`, `is_playing()` and `stats()`.  The new Basalt
-- UI nonetheless needs a transport: PLAY, PAUSE / RESUME, STOP, SEEK, and a
-- progress reading it can draw directly.  This module is that transport, and it
-- builds all of it on top of the CLOCK SEAM -- it never modifies the player.
--
-- ---------------------------------------------------------------------------
-- HOW PAUSE WORKS: A GATED CLOCK (the retired tui.lua's approach, followed)
-- ---------------------------------------------------------------------------
-- ccnbs schedules every note through the clock it is GIVEN, so time itself is
-- the seam.  For each playback this module wraps the injected base clock in a
-- GATED clock:
--   * now_ms() FREEZES while paused (and, on resume, subtracts the paused span,
--     so the timeline continues exactly where it froze instead of jumping);
--   * after(delay, fn) schedules on the base clock, but every callback is
--     routed through a gate that defers while paused;
--   * pause() cancels the armed base callbacks; resume() RE-ARMS them with the
--     remaining delay measured from the frozen now_ms().
-- The base clock is the ONLY timer source: nothing here sleeps, polls or spins.
-- This is the same mechanism the retired text UI (player/tui.lua, see
-- `git show HEAD~12:player/tui.lua`, "PAUSE / RESUME IS IMPLEMENTED THROUGH THE
-- CLOCK SEAM") proved, re-expressed as a small self-contained clock rather than
-- an inline closure because the UI drives several playbacks across a session.
--
-- ---------------------------------------------------------------------------
-- WHY A "SEEK" IS IMPLEMENTED AS A RESTART
-- ---------------------------------------------------------------------------
-- The player has no seek primitive, and the scheduler's arithmetic forbids the
-- obvious trick.  player/tempo.lua computes, for each event,
--     ideal  = start_ms + event.t_ms
--     delay  = ideal - clock.now_ms()
-- where start_ms = clock.now_ms() when play() began.  `event.t_ms` is therefore
-- measured from the START OF PLAYBACK, and the first event's delay is always
-- exactly `event.t_ms` -- an offset clock cannot change that, because the
-- offset cancels (start_ms is read from the same clock).  So keeping the
-- ORIGINAL absolute t_ms and only re-origining the clock does nothing.
--
-- The only correct move is to hand the scheduler a plan whose t_ms values are
-- REBASED to the seek target:
--   1. cancel the current session and silence the speakers (no zombies);
--   2. take the SUFFIX of the event array from the first event whose t_ms is at
--      or after the target (`_seek_index`);
--   3. copy that suffix and subtract the target from each t_ms (`_rebase`), so
--      the first event fires immediately and later ones fire (t - target) later;
--   4. play the rebased suffix through a FRESH gate whose timeline conceptually
--      begins at the target -- `position_base = target` restores the absolute
--      song position for `progress()`.
-- The full plan is never mutated (the copies are shallow), so duration and the
-- seek maths stay correct for the next seek.
--
-- ---------------------------------------------------------------------------
-- TIME IS THE SOURCE OF TRUTH, NOT EVENT COUNT
-- ---------------------------------------------------------------------------
-- `progress().frac` is derived from ELAPSED MILLISECONDS over the plan's total
-- duration, clamped to 0..1 (`_frac`); it is NEVER `index / total`.  A song
-- whose events are unevenly spaced therefore fills the bar smoothly instead of
-- jumping once per note.  `t_ms` is musical time: `position_base` plus the gate
-- reading minus the reading when the session began -- so it is frozen while
-- paused and continues from the same point afterwards.
--
-- ---------------------------------------------------------------------------
-- CONTRACTS AND POLICIES
-- ---------------------------------------------------------------------------
--   transport.configure(opts)  inject every seam (all optional):
--       opts.ccnbs      the library (default: lazy require("ccnbs"))
--       opts.clock      a base clock (default: lazy player.clock.new_os())
--       opts.speakers   speaker records to stop on stop/finish/replace
--       opts.on_progress function(info)  info = { t_ms, index, total }
--       opts.on_finish   function()      playback ended OR was cancelled
--   transport.play(events, analysis) -> { ok = true } | { ok = false,
--       error = { code, msg } }.  Replacing an active playback cancels it first.
--   transport.pause() / resume() / toggle()  idempotent, no-op when inapplicable.
--   transport.stop()            cancel + silence + reset; idempotent.
--   transport.seek(frac)        -> boolean; no-op when stopped, bad frac, or
--                               no plan.  Stays paused if it was paused.
--   transport.state()           "stopped" | "playing" | "paused".
--   transport.progress()        { t_ms, index, total, frac } -- frac is always a
--                               real number in 0..1, never nil, never NaN, so a
--                               UI can draw it directly.  `index`/`total` are
--                               the ccnbs EVENT counters (the plan length), NOT
--                               the denominator of `frac`.
--   transport.duration_ms()     total plan length in ms, or nil.
--
-- NOTHING HERE RAISES.  A transport that raised would take the whole UI down, so
-- every seam call is pcall-guarded and a failed play returns a typed failure.
--
-- LOAD SAFETY: `os`, `fs` and `term` are never read at require time -- the
-- default library and clock are resolved LAZILY on first use -- so this module
-- loads in plain desktop Lua (and in the load-safety spec, where those globals
-- are trapped).
--
-- PURE PARTS EXPORTED FOR TESTS: `_seek_index`, `_rebase`, `_frac`, `_duration`
-- are clock-free functions the spec pins directly.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit, no
-- sleeping, no blocking.

local transport = {}

-- ---------------------------------------------------------------------------
-- Injected seams (configure) and live playback state
-- ---------------------------------------------------------------------------

local config = {
  ccnbs = nil,
  clock = nil,
  speakers = nil,
  on_progress = nil,
  on_finish = nil,
}

-- The default base clock, created at most once, lazily.  Holding it avoids
-- wrapping a brand-new os clock on every play while still never touching the
-- real clock at load time.
local default_base_clock = nil

local state = {
  status = "stopped",
  session = nil,
  gate = nil,
  events = nil,        -- the FULL plan, never mutated
  analysis = nil,
  position_base = 0,   -- song ms at which the current session began (seek target)
  session_start = 0,   -- gate.now_ms() when the current session began
  index_base = 0,      -- events before the current suffix (seek)
  fired = 0,           -- events fired in the current session
  count_total = 0,     -- total events in the full plan
  duration = nil,      -- total plan length in ms, or nil
  finish_notified = false,
}

-- ---------------------------------------------------------------------------
-- Lazy seam resolution (never at require time)
-- ---------------------------------------------------------------------------

local function resolve_ccnbs()
  if config.ccnbs ~= nil then
    return config.ccnbs
  end
  local ok, mod = pcall(require, "ccnbs")
  if ok and type(mod) == "table" and type(mod.play) == "function" then
    return mod
  end
  return nil
end

local function resolve_base_clock()
  if config.clock ~= nil then
    return config.clock
  end
  if default_base_clock ~= nil then
    return default_base_clock
  end
  local ok, mod = pcall(require, "player.clock")
  if ok and type(mod) == "table" and type(mod.new_os) == "function" then
    local made_ok, made = pcall(mod.new_os)
    if made_ok then
      default_base_clock = made
      return default_base_clock
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Pure helpers (exported for the spec; no clock, no state)
-- ---------------------------------------------------------------------------

local function is_real_number(value)
  return type(value) == "number" and value == value
end

-- transport._duration(events) -> number | nil
--
-- The plan's total musical length: the GREATEST t_ms over its events (the
-- events may arrive time-sorted, but taking the maximum is order-independent and
-- cannot silently under-report if they are not).  nil when there are no
-- time-bearing events -- a seek/frac denominator of nil becomes 0 downstream, so
-- an empty plan can never divide by zero.
function transport._duration(events)
  if type(events) ~= "table" then
    return nil
  end
  local longest = nil
  for index = 1, #events do
    local event = events[index]
    if type(event) == "table" and is_real_number(event.t_ms) then
      if longest == nil or event.t_ms > longest then
        longest = event.t_ms
      end
    end
  end
  return longest
end

-- transport._seek_index(events, t_ms) -> integer
--
-- The index of the FIRST event whose t_ms is at or after the target, in ARRAY
-- order -- i.e. where the seek suffix begins.  Returns #events + 1 when the
-- target is past every event (an empty suffix).  A non-numeric / NaN target is
-- treated as 0 (the start) so the function never raises.
function transport._seek_index(events, t_ms)
  if type(events) ~= "table" then
    return 1
  end
  if not is_real_number(t_ms) then
    t_ms = 0
  end
  for index = 1, #events do
    local event = events[index]
    if type(event) == "table" and is_real_number(event.t_ms)
      and event.t_ms >= t_ms then
      return index
    end
  end
  return #events + 1
end

-- transport._rebase(events, from_index, target) -> array
--
-- A NEW array holding shallow COPIES of events[from_index .. #events] with
-- t_ms reduced by target (clamped at 0).  Copies, not aliases: the caller's plan
-- (kept for duration and the next seek) must never be mutated by a seek.
function transport._rebase(events, from_index, target)
  local out = {}
  if type(events) ~= "table" then
    return out
  end
  if not is_real_number(target) then
    target = 0
  end
  for index = from_index, #events do
    local event = events[index]
    if type(event) == "table" then
      local copy = {}
      for key, value in pairs(event) do
        copy[key] = value
      end
      if is_real_number(event.t_ms) then
        local rebased = event.t_ms - target
        if rebased < 0 then
          rebased = 0
        end
        copy.t_ms = rebased
      end
      out[#out + 1] = copy
    end
  end
  return out
end

-- transport._frac(elapsed, total) -> number in 0..1
--
-- elapsed / total, clamped to 0..1.  A missing, non-numeric or non-positive
-- denominator yields 0, so there is NEVER a divide-by-zero and NEVER a NaN.  The
-- clamp also doubles as the range clamp for a user-supplied seek fraction
-- (`_frac(frac, 1)`).
function transport._frac(elapsed, total)
  if not is_real_number(elapsed) or elapsed <= 0 then
    return 0
  end
  if not is_real_number(total) or total <= 0 then
    return 0
  end
  if elapsed >= total then
    return 1
  end
  return elapsed / total
end

-- ---------------------------------------------------------------------------
-- The gated clock (pause / resume through the clock seam)
-- ---------------------------------------------------------------------------

-- gated_clock(base) -> clock with now_ms / after / cancel / run_due / pause /
-- resume / is_paused.
--
-- Freezes musical time while paused and re-arms pending callbacks on resume
-- against the SAME frozen timeline, so the notes pick up exactly where they left
-- off.  The base clock is the only timer source.
local function gated_clock(base)
  local gate = {}
  gate._paused = false
  gate._paused_total = 0
  gate._pause_started = 0
  gate._items = {}

  function gate.now_ms()
    if gate._paused then
      return gate._pause_started - gate._paused_total
    end
    return base.now_ms() - gate._paused_total
  end

  local arm
  local function fire(item)
    item._armed = false
    if item._cancelled or item._fired then
      return
    end
    if gate._paused then
      return
    end
    local remaining = item._deadline - gate.now_ms()
    if remaining > 0.000001 then
      arm(item)
      return
    end
    item._fired = true
    item._fn()
  end

  arm = function(item)
    if item._cancelled or item._fired then
      return
    end
    if gate._paused then
      item._armed = false
      return
    end
    local remaining = item._deadline - gate.now_ms()
    if remaining < 0 then
      remaining = 0
    end
    item._armed = true
    item._handle = base.after(remaining / 1000, function()
      fire(item)
    end)
  end

  function gate.after(delay_sec, fn)
    local item = {
      _deadline = gate.now_ms() + delay_sec * 1000,
      _fn = fn,
    }
    gate._items[#gate._items + 1] = item
    arm(item)
    return item
  end

  function gate.cancel(item)
    if item == nil or item._cancelled or item._fired then
      return false
    end
    item._cancelled = true
    if item._armed and item._handle ~= nil and type(base.cancel) == "function" then
      base.cancel(item._handle)
    end
    item._armed = false
    return true
  end

  function gate.pause()
    if gate._paused then
      return false
    end
    gate._paused = true
    gate._pause_started = base.now_ms()
    for index = 1, #gate._items do
      local item = gate._items[index]
      if item._armed and item._handle ~= nil and type(base.cancel) == "function" then
        base.cancel(item._handle)
      end
      item._armed = false
    end
    return true
  end

  function gate.resume()
    if not gate._paused then
      return false
    end
    gate._paused_total = gate._paused_total + (base.now_ms() - gate._pause_started)
    gate._paused = false
    for index = 1, #gate._items do
      local item = gate._items[index]
      if not item._fired and not item._cancelled then
        arm(item)
      end
    end
    return true
  end

  function gate.is_paused()
    return gate._paused
  end

  function gate.run_due()
    if type(base.run_due) == "function" then
      return base.run_due()
    end
    return 0
  end

  return gate
end

-- ---------------------------------------------------------------------------
-- Cleanup helpers
-- ---------------------------------------------------------------------------

-- stop_speakers(): silence every injected speaker record, defensively.  A
-- speaker whose stop() raises must not prevent the others, and nothing may
-- propagate -- the same contract as player/runtime.stop_speakers, kept local so
-- this module owns no runtime dependency.
local function stop_speakers()
  local speakers = config.speakers
  if type(speakers) ~= "table" then
    return 0
  end
  local stopped = 0
  for _, record in ipairs(speakers) do
    if type(record) == "table" and type(record.stop) == "function" then
      local ok = pcall(record.stop, record)
      if ok then
        stopped = stopped + 1
      end
    end
  end
  return stopped
end

-- cancel_current(): cancel the live session (if any), never raising.  Idempotent
-- at the state level -- the reference is dropped first so a second call is inert.
local function cancel_current()
  local session = state.session
  state.session = nil
  if session ~= nil and type(session.cancel) == "function" then
    pcall(session.cancel, session)
  end
end

local function failure(code, msg)
  return {
    ok = false,
    error = { code = code, msg = msg },
  }
end

-- ---------------------------------------------------------------------------
-- Progress / finish wiring
-- ---------------------------------------------------------------------------

local function notify_finish()
  if state.finish_notified then
    return
  end
  state.finish_notified = true
  if type(config.on_finish) == "function" then
    pcall(config.on_finish)
  end
end

-- finish_natural(): playback reached its last event.  Cancel the (now spent)
-- session and silence the speakers so no handle or note survives, then report.
local function finish_natural()
  if state.status == "stopped" and state.session == nil then
    return
  end
  cancel_current()
  stop_speakers()
  state.status = "stopped"
  notify_finish()
end

-- handle_progress(info): the sink handed to ccnbs.play.  Records the event
-- counter, forwards to the UI, and treats the final index as end-of-playback.
local function handle_progress(info)
  if type(info) ~= "table" then
    return
  end
  if is_real_number(info.index) then
    state.fired = info.index
  end
  if type(config.on_progress) == "function" then
    pcall(config.on_progress, info)
  end
  if is_real_number(info.index) and is_real_number(info.total)
    and info.total > 0 and info.index >= info.total then
    finish_natural()
  end
end

-- ---------------------------------------------------------------------------
-- Session lifecycle
-- ---------------------------------------------------------------------------

-- start_session(plan, analysis, position_base, index_base) -> result
--
-- Build a fresh gate, snapshot the timeline origin, and hand the (already
-- prepared) plan to ccnbs.play.  A raising library becomes a typed failure
-- instead of taking the UI down.  On success `state.session` is live and the
-- status is "playing"; the caller may pause immediately (seek-while-paused).
local function start_session(plan, analysis, position_base, index_base)
  local base = resolve_base_clock()
  if base == nil or type(base.now_ms) ~= "function" or type(base.after) ~= "function" then
    return failure("E_TRANSPORT_NO_CLOCK",
      "transport.play: no usable base clock (inject opts.clock or provide "
        .. "player.clock.new_os())")
  end

  local ccnbs = resolve_ccnbs()
  if ccnbs == nil then
    return failure("E_TRANSPORT_NO_CCNBS",
      "transport.play: no usable ccnbs library (inject opts.ccnbs or provide "
        .. "the ccnbs module)")
  end

  local gate = gated_clock(base)
  state.gate = gate
  state.session_start = gate.now_ms()
  state.position_base = position_base or 0
  state.index_base = index_base or 0
  state.fired = 0

  local opts = {
    analysis = analysis,
    speakers = config.speakers,
    clock = gate,
    on_progress = handle_progress,
  }

  -- DOT call: ccnbs.play takes (song_or_plan, opts), no explicit self.
  local ok, session = pcall(ccnbs.play, plan, opts)
  if not ok then
    state.gate = nil
    return failure("E_TRANSPORT_PLAY_FAILED", tostring(session))
  end

  state.session = session
  state.status = "playing"
  return { ok = true }
end

-- ---------------------------------------------------------------------------
-- Public interface
-- ---------------------------------------------------------------------------

-- transport.configure(opts): inject the seams.  Only supplied fields override,
-- so a spec (or the UI) can re-wire one seam at a time.
function transport.configure(opts)
  opts = opts or {}
  if opts.ccnbs ~= nil then
    config.ccnbs = opts.ccnbs
  end
  if opts.clock ~= nil then
    config.clock = opts.clock
  end
  if opts.speakers ~= nil then
    config.speakers = opts.speakers
  end
  if opts.on_progress ~= nil then
    config.on_progress = opts.on_progress
  end
  if opts.on_finish ~= nil then
    config.on_finish = opts.on_finish
  end
  return transport
end

-- transport.play(events, analysis) -> { ok = true } | { ok = false, error }
--
-- Start (or RESTART) playback of a pre-planned event array.  Replacing an
-- active playback CANCELS it and silences the speakers first, so a restart can
-- never leave two sessions firing.  Broken input is validated BEFORE anything
-- is torn down, so a bad call leaves current playback untouched.
function transport.play(events, analysis)
  if type(events) ~= "table" then
    return failure("E_TRANSPORT_PLAY_INPUT",
      "transport.play: events must be an array of plan events; got "
        .. type(events))
  end
  if analysis ~= nil and type(analysis) ~= "table" then
    return failure("E_TRANSPORT_PLAY_INPUT",
      "transport.play: analysis must be a table or nil; got " .. type(analysis))
  end

  -- Replace: cancel and silence the previous playback before starting anew.
  cancel_current()
  stop_speakers()

  state.events = events
  state.analysis = analysis or {}
  state.count_total = #events
  state.duration = transport._duration(events)
  state.finish_notified = false

  local result = start_session(events, state.analysis, 0, 0)
  if not result.ok then
    state.status = "stopped"
    state.session = nil
    state.gate = nil
    state.events = nil
    state.analysis = nil
    state.count_total = 0
    state.duration = nil
  end
  return result
end

-- transport.pause(): freeze musical time.  No-op unless playing; idempotent.
function transport.pause()
  if state.status ~= "playing" or state.gate == nil then
    return false
  end
  state.gate.pause()
  state.status = "paused"
  return true
end

-- transport.resume(): continue from the frozen point.  No-op unless paused.
function transport.resume()
  if state.status ~= "paused" or state.gate == nil then
    return false
  end
  state.gate.resume()
  state.status = "playing"
  return true
end

-- transport.toggle(): pause when playing, resume when paused, else inert.
function transport.toggle()
  if state.status == "paused" then
    transport.resume()
  elseif state.status == "playing" then
    transport.pause()
  end
  return state.status
end

-- transport.stop(): cancel, silence, reset.  Idempotent.
function transport.stop()
  if state.status == "stopped" and state.session == nil then
    return false
  end

  cancel_current()
  stop_speakers()

  state.status = "stopped"
  state.gate = nil
  state.events = nil
  state.analysis = nil
  state.position_base = 0
  state.session_start = 0
  state.index_base = 0
  state.fired = 0
  state.count_total = 0
  state.duration = nil

  notify_finish()
  return true
end

-- transport.seek(frac) -> boolean
--
-- Restart playback at `frac` (0..1) of the current plan.  No-op when stopped,
-- when there is no plan, or when frac is not a real number; frac is clamped to
-- 0..1 so the ends are always safe.  A paused transport STAYS paused.  The seek
-- is a restart (see the header) that cancels the old session first, so exactly
-- one session is ever live.
function transport.seek(frac)
  if state.status ~= "playing" and state.status ~= "paused" then
    return false
  end
  if not is_real_number(frac) then
    return false
  end
  local duration = state.duration
  if not is_real_number(duration) then
    return false
  end
  local events = state.events
  if type(events) ~= "table" or #events == 0 then
    return false
  end

  -- _frac(x, 1) clamps x into 0..1 (and turns a non-positive x into 0).
  local clamped = transport._frac(frac, 1)
  local target = clamped * duration
  local start_index = transport._seek_index(events, target)
  if start_index > #events then
    return false
  end

  local was_paused = (state.status == "paused")
  local plan = transport._rebase(events, start_index, target)
  if #plan == 0 then
    return false
  end

  -- Replace the live playback, then (if it was paused) immediately re-freeze.
  cancel_current()
  stop_speakers()
  state.finish_notified = false

  local result = start_session(plan, state.analysis, target, start_index - 1)
  if not result.ok then
    state.status = "stopped"
    state.session = nil
    state.gate = nil
    return false
  end

  if was_paused then
    state.gate.pause()
    state.status = "paused"
  end
  return true
end

-- transport.state() -> "stopped" | "playing" | "paused"
function transport.state()
  return state.status
end

-- transport.duration_ms() -> number | nil
function transport.duration_ms()
  if is_real_number(state.duration) then
    return state.duration
  end
  return nil
end

-- transport.progress() -> { t_ms, index, total, frac }
--
-- Never nil, never NaN.  `t_ms` is frozen while paused and continues from the
-- same point on resume.  `frac` is time-based (elapsed ms over total ms), while
-- `index`/`total` are the EVENT counters the UI may show alongside it.
function transport.progress()
  local t_ms = 0
  if state.gate ~= nil and type(state.gate.now_ms) == "function" then
    local now = state.gate.now_ms()
    if is_real_number(now) then
      t_ms = state.position_base + (now - state.session_start)
    end
  end
  if not is_real_number(t_ms) or t_ms < 0 then
    t_ms = 0
  end
  if is_real_number(state.duration) and t_ms > state.duration then
    t_ms = state.duration
  end

  local total = state.count_total
  if not is_real_number(total) or total < 0 then
    total = 0
  end

  local index = state.index_base + state.fired
  if not is_real_number(index) or index < 0 then
    index = 0
  end
  if index > total then
    index = total
  end

  return {
    t_ms = t_ms,
    index = index,
    total = total,
    frac = transport._frac(t_ms, state.duration),
  }
end

return transport
