-- player/fanout.lua
--
-- DETERMINISTIC MULTI-SPEAKER FAN-OUT WITH GRACEFUL DEGRADATION.
--
-- FROZEN PUBLIC INTERFACE
--   local fanout = require("player.fanout")
--
--   fanout.assign(events, analysis, speakers) -> assignment
--   fanout.play(events, analysis, speakers, dispatch) -> {
--       calls_made, refused, dropped, results,
--   }
--
--   `events`   the plan array from player/plan.lua (frozen (tick, layer, note)
--              order).  NEVER mutated.
--   `analysis` the result from nbs/analyze.lua.  NEVER mutated.
--   `speakers` an array of speaker records from player/speaker.lua, ALREADY in
--              ascending side order (speaker.discover sorts them).  NEVER
--              mutated.
--   `dispatch` a dispatcher from player/dispatch.lua (`d:event(event, record)`).
--
--   assignment = {
--     speakers       = <the speaker array it was given>,
--     required       = <integer>,   -- nbs.speakers.required_count(analysis)
--     found          = <integer>,   -- #speakers
--     dropped        = <integer>,   -- unplaceable events (consumers only)
--     dropped_events = <array>,     -- dropped events, in drop order
--     by_speaker     = { [side] = <array of events assigned to that speaker,
--                                  in frozen order> },
--     warning_code   = "speakers" | nil,   -- BARE code
--     warning_args   = { peak, required, found, dropped } | nil,
--   }
--
--   `play` returns calls_made (a speaker method returned), refused (a speaker
--   returned false -- a NORMAL CC:Tweaked refusal), dropped, and results (the
--   dispatch results, in call order).
--
-- ===========================================================================
-- THE CAPACITY UNIT IS A SLIDING 50 ms WINDOW -- NOT A BUCKET, NOT A TICK
-- ===========================================================================
-- A speaker's per-tick budget is measured on GAME time, and one Minecraft game
-- tick is 50 ms -- a DIFFERENT clock from the NBS tick (see nbs/analyze.lua).
-- The window here is therefore measured on `event.t_ms`: two events compete for
-- the SAME speaker-tick exactly when their start times are STRICTLY less than
-- 50 ms apart (`math.abs(t1 - t2) < 50`).  That is the SAME predicate
-- nbs/analyze.lua uses to compute `peak_concurrent`; the two modules must never
-- drift apart, or fanout will place events the analyzer did not budget for (and
-- the speaker, refusing the 9th call, silently loses them).
--
-- HISTORY -- WHY THIS IS NOT `floor(t_ms / 50)`: fixed buckets are NOT
-- equivalent to the sliding test.  t=40 and t=50 fall in buckets 0 and 1, yet
-- they are 10 ms apart and genuinely compete for one speaker-tick, so bucketing
-- allowed NINE notes on one speaker whenever a burst straddled a bucket edge.
-- The comparison below is against the ACTUAL assigned times, never a bucket.
-- A gap of exactly 50 ms starts a new span; a gap of 49 ms does not.
--
-- Per event, per speaker (measured against the events ALREADY assigned to that
-- speaker):
--   * a `play_note` consumes ONE of the speaker's MAX_NOTES_PER_TICK (8) slots:
--     it needs fewer than 8 notes already within 50 ms of it, and no play_sound;
--   * a `play_sound` consumes the ENTIRE speaker for that span -- it needs NO
--     event at all within 50 ms, and then closes the speaker to every event
--     until that event is at least 50 ms away;
--   * a `custom` event consumes NOTHING.  It is refused at dispatch, so it must
--     NEVER trigger a drop; it is passed through (assigned to the first speaker)
--     so the recorded call order stays a faithful projection of the plan.
--   * an unknown/missing `kind` likewise consumes nothing.
--
-- The plan's frozen order is ascending by (tick_index, layer_index, note_index)
-- and t_ms = tick_index * tick_ms, so the walk sees NON-DECREASING t_ms.  That
-- lets an entry that is already 50 ms (or more) behind the current event be
-- retired for good: it is behind every later event too.
--
-- ===========================================================================
-- ASSIGNMENT POLICY: STABLE GREEDY LEAST-LOADED, ASCENDING-SIDE TIE-BREAK
-- ===========================================================================
-- Walk the events in their given (frozen) order.  For each `play_note`, pick
-- the speaker with the FEWEST notes already within 50 ms of it; ties break to
-- the speaker whose `side` sorts FIRST.  Because `speakers` is already
-- ascending by side, iterating it from index 1 with a strict `<` improvement
-- test resolves a tie to the earliest speaker in the array.
--
-- A `play_sound` needs a speaker with NOTHING else within 50 ms of it; if no
-- speaker is free it is dropped.  With several free speakers the first
-- (ascending side) wins -- which least-loaded would also give, since all
-- candidates are at 0.
--
-- ===========================================================================
-- DROP POLICY: DETERMINISTIC, AND IT PRESERVES THE EARLY PART OF THE SONG
-- ===========================================================================
-- An event that cannot be placed is DROPPED rather than overflowing a speaker.
-- Because the walk is in frozen (tick_index, layer_index, note_index) order and
-- earlier events always claim their slot first, the events that lose are the
-- LATER ones in that same tuple order.  Concretely: early ticks are retained
-- over late ticks, then lower layers over higher, then lower note indices over
-- higher.  `dropped_events` lists them in the order they were dropped, which
-- (for a single overflowing window) is that same ascending order.
--
-- `dropped` counts only events that CONSUME capacity (play_note / play_sound):
-- a custom event is never "dropped".  Whenever `dropped > 0` OR
-- `found < required`, `warning_code` is the bare string "speakers" and
-- `warning_args` carries peak/required/found/dropped so the caller can render
-- e.g. "needs 2, found 1".  Formatting the code belongs to a later module.
--
-- ===========================================================================
-- DETERMINISM IS THE POINT
-- ===========================================================================
-- The Tier-2 integration test asserts an ORDERED recorded call sequence and
-- byte-identical output across repeated runs.  Therefore:
--   * `pairs` is NEVER used here -- not over events, not over speakers, not
--     over by_speaker.
--   * `by_speaker` is keyed by side for the caller's convenience, but the
--     EMITTED call order is produced by walking the events array in order and
--     routing each event to its assigned speaker -- never by iterating a table.
--   * This module ALLOCATES; it does not synchronise clocks.  CC:Tweaked
--     multi-speaker playback is best-effort, and that limitation is the
--     player's, not this allocator's.
--
-- Lua 5.2 / Cobalt constraints honoured: no `//`, no bitwise operators, no
-- utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.

local nbs_speakers = require("nbs.speakers")

local fanout = {}

-- One Minecraft game tick, in milliseconds.  The capacity window.
local WINDOW_MS = 50

-- The per-window playNote budget of one speaker (8).  Read from the frozen
-- formula module rather than re-declaring it.
local MAX_NOTES_PER_WINDOW = nbs_speakers.MAX_NOTES_PER_TICK

-- consumes(kind): true only for the kinds that occupy speaker capacity.  Custom
-- and unknown kinds consume nothing and must never cause a drop.
local function consumes(kind)
  return kind == "play_note" or kind == "play_sound"
end

-- time_of(event): the event's start time in ms.  A missing/non-numeric t_ms is
-- treated as 0 so hostile input can never raise.
local function time_of(event)
  local t_ms = nil
  if type(event) == "table" then
    t_ms = event.t_ms
  end
  if type(t_ms) ~= "number" then
    t_ms = 0
  end
  return t_ms
end

-- within_window(a, b): THE capacity predicate.  Two events compete for one
-- speaker-tick exactly when their start times are STRICTLY less than one 50 ms
-- game tick apart.  This must stay identical to the strict `< 50` test in
-- nbs/analyze.lua; drift between the two is what let fanout overload a speaker
-- the analyzer had already budgeted for.
local function within_window(a, b)
  return math.abs(a - b) < WINDOW_MS
end

-- allocate(events, speakers) -> owner, where owner[i] is the speaker record
-- event i was assigned to, or nil when a capacity-consuming event was dropped.
-- Custom/unknown events with at least one speaker are assigned to speakers[1].
-- Pure, total and deterministic; never raises.
local function allocate(events, speakers)
  local total_events = #events
  local total_speakers = #speakers

  -- Per-speaker sliding-window bookkeeping, indexed by the speaker's array
  -- position so no hash-table iteration ever touches it.
  --   times[k]   start times (ms) of the events assigned to speaker k, in
  --              assignment order (non-decreasing: the frozen plan is ascending)
  --   sounds[k]  parallel flag: true when that entry is a play_sound
  --   head[k]    1-based index of speaker k's first entry that can still share
  --              a window with the current event; everything before it is at
  --              least 50 ms behind and can never compete again.
  local times = {}
  local sounds = {}
  local head = {}
  for k = 1, total_speakers do
    times[k] = {}
    sounds[k] = {}
    head[k] = 1
  end

  -- retire(k, t): drop speaker k's entries that are already out of reach at
  -- time t.  The walk is in non-decreasing t_ms order, so once an entry is
  -- 50 ms (or more) behind t it is behind every later event too.  The test is
  -- the boundary of the same strict `< 50` predicate, on actual times.
  local function retire(k, t)
    local list = times[k]
    local first = head[k]
    while first <= #list and list[first] <= t
      and not within_window(list[first], t) do
      first = first + 1
    end
    head[k] = first
  end

  -- live_count(k, t): how many of speaker k's entries share a 50 ms span with
  -- t.  After retire() the remaining entries are the live ones, so the abs()
  -- test only re-confirms what retirement already established.
  local function live_count(k, t)
    local list = times[k]
    local count = 0
    for index = head[k], #list do
      if within_window(list[index], t) then
        count = count + 1
      end
    end
    return count
  end

  -- live_sound(k, t): is one of speaker k's live entries a play_sound?
  local function live_sound(k, t)
    local list = times[k]
    local flags = sounds[k]
    for index = head[k], #list do
      if flags[index] and within_window(list[index], t) then
        return true
      end
    end
    return false
  end

  local owner = {}

  for i = 1, total_events do
    local event = events[i]
    local kind = nil
    if type(event) == "table" then
      kind = event.kind
    end
    local t = time_of(event)

    if kind == "play_note" then
      -- Stable greedy least-loaded: count the notes already within 50 ms of
      -- this event; a strict `<` improvement test keeps the earliest
      -- (ascending side) speaker on a tie.
      local best = nil
      local best_count = nil
      for k = 1, total_speakers do
        retire(k, t)
        if not live_sound(k, t) then
          local load = live_count(k, t)
          if load < MAX_NOTES_PER_WINDOW
            and (best == nil or load < best_count) then
            best = k
            best_count = load
          end
        end
      end
      if best ~= nil then
        local list = times[best]
        list[#list + 1] = t
        sounds[best][#sounds[best] + 1] = false
        owner[i] = speakers[best]
      end

    elseif kind == "play_sound" then
      -- Needs a speaker with NOTHING within 50 ms.  First free speaker
      -- (ascending side) wins; if none is free the event is dropped.
      local best = nil
      for k = 1, total_speakers do
        retire(k, t)
        if live_count(k, t) == 0 then
          best = k
          break
        end
      end
      if best ~= nil then
        local list = times[best]
        list[#list + 1] = t
        sounds[best][#sounds[best] + 1] = true
        owner[i] = speakers[best]
      end

    else
      -- custom / unknown: consumes nothing.  Route to the first speaker so the
      -- recorded call order stays a faithful projection; dispatch refuses it.
      if total_speakers >= 1 then
        owner[i] = speakers[1]
      end
    end
  end

  return owner
end

-- fanout.assign(events, analysis, speakers) -> assignment.  Pure, total and
-- deterministic: it only reads its inputs and never uses `pairs` for order.
function fanout.assign(events, analysis, speakers)
  if type(events) ~= "table" then
    events = {}
  end
  if type(speakers) ~= "table" then
    speakers = {}
  end
  if type(analysis) ~= "table" then
    analysis = {}
  end

  local owner = allocate(events, speakers)

  -- Initialise every side key up front so callers can index by speaker side
  -- without a nil check, including sides with no events.
  local by_speaker = {}
  for k = 1, #speakers do
    local side = speakers[k].side
    if type(side) == "string" and by_speaker[side] == nil then
      by_speaker[side] = {}
    end
  end

  local dropped_events = {}
  local dropped = 0
  for i = 1, #events do
    local event = events[i]
    local assigned = owner[i]
    if assigned ~= nil then
      local side = assigned.side
      if type(side) == "string" then
        local bucket = by_speaker[side]
        if bucket == nil then
          bucket = {}
          by_speaker[side] = bucket
        end
        bucket[#bucket + 1] = event
      end
    else
      local kind = nil
      if type(event) == "table" then
        kind = event.kind
      end
      if consumes(kind) then
        dropped = dropped + 1
        dropped_events[#dropped_events + 1] = event
      end
    end
  end

  local required = nbs_speakers.required_count(analysis)
  local found = #speakers

  local warning_code = nil
  local warning_args = nil
  if dropped > 0 or found < required then
    warning_code = "speakers"
    warning_args = {
      peak = analysis.peak_concurrent,
      required = required,
      found = found,
      dropped = dropped,
    }
  end

  return {
    speakers = speakers,
    required = required,
    found = found,
    dropped = dropped,
    dropped_events = dropped_events,
    by_speaker = by_speaker,
    warning_code = warning_code,
    warning_args = warning_args,
  }
end

-- fanout.play(events, analysis, speakers, dispatch) -> playback summary.
--
-- Reuses the SAME allocation as assign(), then emits calls by walking the events
-- in frozen order, routing each event to its assigned speaker.  Custom events
-- reach dispatch (which refuses them) but make no call.  Dropped events are not
-- dispatched.  `analysis` is part of the frozen signature and is otherwise
-- unused here.
function fanout.play(events, analysis, speakers, dispatch)
  if type(events) ~= "table" then
    events = {}
  end
  if type(speakers) ~= "table" then
    speakers = {}
  end

  local owner = allocate(events, speakers)

  local can_dispatch = type(dispatch) == "table"
    and type(dispatch.event) == "function"

  local calls_made = 0
  local refused = 0
  local dropped = 0
  local results = {}

  for i = 1, #events do
    local event = events[i]
    local assigned = owner[i]
    if assigned ~= nil and can_dispatch then
      local result = dispatch:event(event, assigned)
      results[#results + 1] = result
      if type(result) == "table" then
        if result.called then
          calls_made = calls_made + 1
        end
        if result.refused then
          refused = refused + 1
        end
      end
    else
      local kind = nil
      if type(event) == "table" then
        kind = event.kind
      end
      if consumes(kind) then
        dropped = dropped + 1
      end
    end
  end

  return {
    calls_made = calls_made,
    refused = refused,
    dropped = dropped,
    results = results,
  }
end

return fanout
