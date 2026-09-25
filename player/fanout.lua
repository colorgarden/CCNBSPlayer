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
-- THE CAPACITY UNIT IS A 50 ms WINDOW -- NOT A TICK, NOT THE WHOLE SONG
-- ===========================================================================
-- A speaker's per-tick budget is measured on GAME time, and one Minecraft game
-- tick is 50 ms -- a DIFFERENT clock from the NBS tick (see nbs/analyze.lua).
-- The window here is therefore measured on `event.t_ms`, is 50 ms wide, and is
-- discretised as `window = floor(t_ms / 50)` -- so two events compete ONLY when
-- their start times land in the SAME 50 ms window.  A gap of exactly 50 ms puts
-- them in different windows, matching analyze's STRICT `<` boundary.  The plan's
-- frozen order is ascending by tick_index, and t_ms = tick_index * tick_ms, so
-- the window index is non-decreasing across the walk.
--
-- Per window, per speaker:
--   * a `play_note` consumes ONE of the speaker's MAX_NOTES_PER_TICK (8) slots;
--   * a `play_sound` consumes the ENTIRE speaker for that window -- a speaker
--     cannot emit a playSound and anything else in the same game tick, so a
--     window that holds a play_sound is closed to every other event;
--   * a `custom` event consumes NOTHING.  It is refused at dispatch, so it must
--     NEVER trigger a drop; it is passed through (assigned to the first speaker)
--     so the recorded call order stays a faithful projection of the plan.
--   * an unknown/missing `kind` likewise consumes nothing.
--
-- ===========================================================================
-- ASSIGNMENT POLICY: STABLE GREEDY LEAST-LOADED, ASCENDING-SIDE TIE-BREAK
-- ===========================================================================
-- Walk the events in their given (frozen) order.  For each `play_note`, pick
-- the speaker with the FEWEST notes already assigned in that event's window;
-- ties break to the speaker whose `side` sorts FIRST.  Because `speakers` is
-- already ascending by side, iterating it from index 1 with a strict `<`
-- improvement test resolves a tie to the earliest speaker in the array.
--
-- A `play_sound` needs a speaker with NOTHING else in that window (window count
-- 0); if no speaker is empty it is dropped.  With several empty speakers the
-- first (ascending side) wins -- which least-loaded would also give, since all
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

-- The 50 ms window that `event.t_ms` falls in.  A missing/non-numeric t_ms is
-- treated as 0 so hostile input can never raise.
local function window_of(event)
  local t_ms = nil
  if type(event) == "table" then
    t_ms = event.t_ms
  end
  if type(t_ms) ~= "number" then
    t_ms = 0
  end
  return math.floor(t_ms / WINDOW_MS)
end

-- allocate(events, speakers) -> owner, where owner[i] is the speaker record
-- event i was assigned to, or nil when a capacity-consuming event was dropped.
-- Custom/unknown events with at least one speaker are assigned to speakers[1].
-- Pure, total and deterministic; never raises.
local function allocate(events, speakers)
  local total_events = #events
  local total_speakers = #speakers

  -- Per-speaker window bookkeeping, indexed by the speaker's array position so
  -- no hash-table iteration ever touches it.
  --   count[k]           notes assigned in speaker k's current window
  --   seen_window[k]     which window count[k] belongs to
  --   occupied_window[k] the window a play_sound closed for speaker k
  local count = {}
  local seen_window = {}
  local occupied_window = {}
  for k = 1, total_speakers do
    count[k] = 0
    seen_window[k] = nil
    occupied_window[k] = nil
  end

  local owner = {}

  for i = 1, total_events do
    local event = events[i]
    local kind = nil
    if type(event) == "table" then
      kind = event.kind
    end
    local window = window_of(event)

    if kind == "play_note" then
      -- Stable greedy least-loaded: strict `<` keeps the earliest (ascending
      -- side) speaker on a tie.
      local best = nil
      local best_count = nil
      for k = 1, total_speakers do
        if seen_window[k] ~= window then
          seen_window[k] = window
          count[k] = 0
        end
        if occupied_window[k] ~= window and count[k] < MAX_NOTES_PER_WINDOW then
          if best == nil or count[k] < best_count then
            best = k
            best_count = count[k]
          end
        end
      end
      if best ~= nil then
        count[best] = count[best] + 1
        owner[i] = speakers[best]
      end

    elseif kind == "play_sound" then
      -- Needs a speaker with NOTHING else in this window.  First empty speaker
      -- (ascending side) wins; if none is empty the event is dropped.
      local best = nil
      for k = 1, total_speakers do
        if seen_window[k] ~= window then
          seen_window[k] = window
          count[k] = 0
        end
        if best == nil and occupied_window[k] ~= window and count[k] == 0 then
          best = k
        end
      end
      if best ~= nil then
        occupied_window[best] = window
        count[best] = MAX_NOTES_PER_WINDOW
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
