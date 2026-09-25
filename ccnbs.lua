-- ccnbs.lua
--
-- THE PUBLIC LIBRARY MODULE -- the single entry point other people's scripts
-- `require`.  Everything below is a thin, non-blocking composition of the
-- already-built layers; no decode/analyze/plan/dispatch/fan-out/tempo logic is
-- re-implemented here.
--
-- WHY THIS FILE IS AT THE PROJECT ROOT (and not nbs/init.lua)
-- ---------------------------------------------------------------------------
-- `package.path` on the target is not guaranteed to contain `?/init.lua`, so a
-- package-style `nbs/init.lua` may not be found.  A root-level `ccnbs.lua`
-- resolves under the plain `./?.lua` pattern, which IS guaranteed.
--
-- FROZEN PUBLIC INTERFACE
--   local ccnbs = require("ccnbs")
--
--   ccnbs.decode(bytes)        -> nbs.decode.decode(bytes)
--   ccnbs.analyze(song)        -> nbs.analyze.analyze(song)
--   ccnbs.plan(song, analysis) -> player.plan.plan(song, analysis)
--   ccnbs.discover_speakers()  -> player.speaker.discover()
--   ccnbs.version              -> "1.0.0"
--   ccnbs.play(song, opts)     -> session
--
-- `opts` (all optional; the seams are injectable):
--   opts.speakers    array of speaker records; default player.speaker.discover()
--   opts.clock       a clock; default player.clock.new_os()
--   opts.on_warning  function(code, args), once per DISTINCT bare code
--   opts.on_progress function(info), info = { t_ms, index, total }
--   opts.on_event    function(event), called for every due event BEFORE dispatch
--
-- WARNING AGGREGATION -- THE KEY INTEGRATION REQUIREMENT
-- ---------------------------------------------------------------------------
-- Every warning class is surfaced through the SINGLE opts.on_warning(code, args)
-- callback, each BARE code AT MOST ONCE per session:
--   "extended-range"    analysis.has_extended_range; args { min_key, max_key }.
--                       Emitted at the START of play -- it is a load-time
--                       property, NOT a mid-playback event.
--   "speakers"          fan-out dropped something / found < required; args come
--                       straight from assignment.warning_args
--                       ({ peak, required, found, dropped }).
--   "custom-instrument" any custom event was refused; args { count = <n> }.
--   "play-sound-pitch"  a trumpet pitch was clamped (from dispatch).
--   "tempo-clamp"       a delay fell below the timer granularity (from tempo).
-- The source of each code is a DIFFERENT module.  This file collects them and
-- deduplicates BY CODE.  It does NOT format `WARN[...]` strings -- that is
-- player/warnings.lua's job -- and it prints nothing.
--
-- CONVENTION SPLIT (DELIBERATE -- do not "unify" it)
-- ---------------------------------------------------------------------------
--   * speaker records and the dispatcher are COLON-style:
--         rec:play_note(name, vol, pitch)   d:event(event, speaker)
--   * clock objects and the clock module are DOT-style:
--         vc.after(delay, fn)   vc.now_ms()   clock.advance_to(vc, target)
--     Calling a clock method with a colon passes the clock as the delay and
--     fails.  tempo's OWN methods are colon-style (t:play, t:cancel, t:stats)
--     even though the clock it consumes is dot-style.
--
-- NON-BLOCKING
-- ---------------------------------------------------------------------------
-- play() only schedules on the injected clock and returns immediately.  A test
-- drives a virtual clock with clock.advance_to; production uses the os clock
-- and its real timers.  This file never busy-waits, never sleeps, and never
-- touches the real clock directly -- player/tempo.lua owns pacing.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.
-- require touches the network nowhere.

local decode_module = require("nbs.decode")
local analyze_module = require("nbs.analyze")
local plan_module = require("player.plan")
local speaker_module = require("player.speaker")
local clock_module = require("player.clock")
local dispatch_module = require("player.dispatch")
local fanout_module = require("player.fanout")
local tempo_module = require("player.tempo")

local ccnbs = {}

-- The public version string.
ccnbs.version = "1.0.0"

-- Thin pass-throughs.  Each returns EXACTLY what the underlying module returns;
-- no wrapping, no normalisation, so the shapes stay identical.
ccnbs.decode = decode_module.decode
ccnbs.analyze = analyze_module.analyze
ccnbs.plan = plan_module.plan

-- ccnbs.discover_speakers() -> ascending-side array of speaker records.  Lets a
-- caller pre-check how many speakers exist before calling play().
function ccnbs.discover_speakers()
  return speaker_module.discover()
end

-- ccnbs.play(song, opts) -> session
--
-- Composes the whole player behind one call and returns immediately.  See the
-- module header for the opts and warning contract.
function ccnbs.play(song, opts)
  opts = opts or {}

  local analysis = analyze_module.analyze(song)
  local events = plan_module.plan(song, analysis)
  local total = #events

  local speakers = opts.speakers
  if speakers == nil then
    speakers = speaker_module.discover()
  end

  local clock_obj = opts.clock
  if clock_obj == nil then
    clock_obj = clock_module.new_os()
  end

  local on_warning = opts.on_warning
  local on_event = opts.on_event
  local on_progress = opts.on_progress

  -- Once-per-code warning ledger.  A code is forwarded the FIRST time it is
  -- raised; later raises of the same code are swallowed here (dispatch and
  -- fan-out already dedup internally, this makes the guarantee unconditional).
  local warned = {}

  local function emit(code, args)
    if code == nil or warned[code] then
      return
    end
    warned[code] = true
    if on_warning ~= nil then
      on_warning(code, args)
    end
  end

  -- Deterministic fan-out over the frozen event order.  `assignment` is the
  -- caller-visible record; `by_speaker` lets us route each event by identity.
  local assignment = fanout_module.assign(events, analysis, speakers)

  -- Load-time properties FIRST: extended range is known before a single event
  -- fires, so it must not wait for mid-playback.
  if analysis.has_extended_range then
    emit("extended-range", {
      min_key = analysis.min_key,
      max_key = analysis.max_key,
    })
  end

  -- A fan-out shortfall / drop is also known up front, from the assignment.
  if assignment.warning_code ~= nil then
    emit(assignment.warning_code, assignment.warning_args)
  end

  -- event table -> assigned speaker record.  Plan events are distinct tables, so
  -- the identity key is unambiguous.  An event absent from the map was dropped.
  local route = {}
  local speaker_count = #speakers
  for index = 1, speaker_count do
    local record = speakers[index]
    local side = record.side
    local bucket = assignment.by_speaker[side]
    if bucket ~= nil then
      for position = 1, #bucket do
        route[bucket[position]] = record
      end
    end
  end

  local dispatcher = dispatch_module.new({})
  local fired = 0
  local custom_count = 0

  -- Deferred warnings that only know their final count once playback has run:
  -- "custom-instrument" reports how many custom events were actually refused.
  local function finish_warnings()
    if custom_count > 0 then
      emit("custom-instrument", { count = custom_count })
    end
  end

  local tempo_session = tempo_module.new({
    clock = clock_obj,
    -- tempo's warn callback hands back a BARE code with no args.
    warn = function(code)
      emit(code, {})
    end,
    on_event = function(event)
      fired = fired + 1

      -- on_event runs BEFORE dispatch, for every due event.
      if on_event ~= nil then
        on_event(event)
      end

      local target = route[event]
      if target ~= nil then
        -- COLON call: the dispatcher takes an explicit self.
        local result = dispatcher:event(event, target)
        if result ~= nil
          and result.warning_code == dispatch_module.WARN_PLAY_SOUND_PITCH then
          emit(dispatch_module.WARN_PLAY_SOUND_PITCH, {})
        end
        if event.kind == "custom" then
          custom_count = custom_count + 1
        end
      end

      if on_progress ~= nil then
        on_progress({ t_ms = event.t_ms, index = fired, total = total })
      end

      if fired >= total then
        finish_warnings()
      end
    end,
  })

  -- Schedule on the injected clock; returns immediately (never blocks).
  tempo_session:play(events)

  -- The session object handed back to the caller.
  local session = {}

  -- session.cancel(): stop playback; idempotent.  Also flushes the deferred
  -- "custom-instrument" warning so a cancelled session still reports what it saw.
  function session.cancel()
    if session._cancelled then
      return
    end
    session._cancelled = true
    tempo_session:cancel()
    finish_warnings()
  end

  -- session.is_playing(): true while events are still pending and not cancelled.
  function session.is_playing()
    if session._cancelled then
      return false
    end
    return fired < total
  end

  -- session.stats(): passed through verbatim from the tempo session.
  function session.stats()
    return tempo_session:stats()
  end

  session._cancelled = false

  -- Frozen public session fields.
  session.analysis = analysis
  session.plan = events
  session.assignment = assignment

  return session
end

return ccnbs
