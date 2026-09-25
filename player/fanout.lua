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
--     until that event is at least 50 ms away.  If no speaker is free it
--     evacuates the cheapest one (see ASSIGNMENT POLICY below); it is the most
--     constrained item and is never starved by notes that were visited first;
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
-- A `play_sound` needs a speaker with NOTHING else within 50 ms of it.  If one
-- exists, the first (ascending side) wins.  Otherwise the sound -- the MOST
-- CONSTRAINED item, because it monopolises a whole speaker-tick -- EVACUATES
-- the cheapest speaker: that speaker's live notes are relocated (ascending-side
-- least-loaded, exact 50 ms checks at each note's own time), and a note that
-- fits nowhere is dropped so the sound can take the span.  The sound always
-- outranks the notes in its span (nbs/speakers.lua budgets one whole speaker
-- per sound); this is what stops the visited order from starving it.  With two
-- vanilla notes and one trumpet in one window and two speakers, the trumpet
-- takes one speaker and the two notes share the other, instead of the trumpet
-- dropping because the notes were visited first.
--
-- A two-pass "sounds-first" walk was REJECTED: it would change which SIDE a
-- sound takes whenever a speaker is already free, and the frozen per-side
-- expectations (a note visited first takes the ascending speaker; the sound
-- takes the next free one) must not move.  The repair above leaves every
-- placement that already succeeds untouched.
--
-- Custom/unknown events are passed through to the first speaker; they consume
-- nothing and never trigger a drop.
--
-- ===========================================================================
-- DROP POLICY: DETERMINISTIC, AND IT PRESERVES THE EARLY PART OF THE SONG
-- ===========================================================================
-- An event that cannot be placed is DROPPED rather than overflowing a speaker.
-- Because the walk is in frozen (tick_index, layer_index, note_index) order and
-- earlier events always claim their slot first, the events that lose are the
-- LATER ones in that same tuple order.  Concretely: early ticks are retained
-- over late ticks, then lower layers over higher, then lower note indices over
-- higher -- the sole exception being a play_sound, which is the most
-- constrained item and outranks the notes it evacuates; those notes are still
-- the LATEST among the ones on the evacuated speaker.  `dropped_events` lists
-- the drops in the frozen order of the plan.
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
  --   times[k]   start times (ms) of speaker k's entries, in assignment order
  --              (the frozen plan is ascending; a relocation appends the
  --              relocated note's own -- older or equal -- time, which the
  --              window scans tolerate because they always re-check the real
  --              50 ms predicate)
  --   sounds[k]  parallel flag: true when that entry is a play_sound
  --   ids[k]     parallel frozen event index (1-based): decides WHICH note is
  --              evacuated when a sound needs the speaker -- the later
  --              (tick_index, layer_index, note_index) loses
  --   alive[k]   parallel flag: false once an entry was relocated away (it then
  --              lives on its new speaker only)
  --   head[k]    1-based index of speaker k's first entry that is not already
  --              known to be out of reach; everything before it is dead or at
  --              least 50 ms behind the current event.
  local times = {}
  local sounds = {}
  local ids = {}
  local alive = {}
  local head = {}
  for k = 1, total_speakers do
    times[k] = {}
    sounds[k] = {}
    ids[k] = {}
    alive[k] = {}
    head[k] = 1
  end

  -- owner[i] is set when event i is placed and cleared when an assigned note is
  -- later evacuated for a play_sound.  It is declared before the helpers below
  -- because the evacuation closure clears it.
  local owner = {}

  -- append(k, t, is_sound, id): record one entry on speaker k.
  local function append(k, t, is_sound, id)
    local list = times[k]
    local position = #list + 1
    list[position] = t
    sounds[k][position] = is_sound
    ids[k][position] = id
    alive[k][position] = true
  end

  -- retire(k, t): advance speaker k's head past dead entries and past entries
  -- that are already out of reach at time t (at least 50 ms behind it).  The
  -- walk is in non-decreasing t_ms order, so an entry 50 ms behind t is behind
  -- every later event too.  The test is the boundary of the same strict `< 50`
  -- predicate, on actual times.
  local function retire(k, t)
    local list = times[k]
    local flags = alive[k]
    local first = head[k]
    while first <= #list do
      if not flags[first] then
        first = first + 1
      elseif list[first] <= t and not within_window(list[first], t) then
        first = first + 1
      else
        break
      end
    end
    head[k] = first
  end

  -- live_count(k, t): how many of speaker k's LIVE entries share a 50 ms span
  -- with t.  After retire() the remaining entries are the live ones, so the
  -- abs() test only re-confirms what retirement already established.
  local function live_count(k, t)
    local list = times[k]
    local flags = alive[k]
    local count = 0
    for index = head[k], #list do
      if flags[index] and within_window(list[index], t) then
        count = count + 1
      end
    end
    return count
  end

  -- live_sound(k, t): is one of speaker k's LIVE entries a play_sound?
  local function live_sound(k, t)
    local list = times[k]
    local flags = alive[k]
    local flags_sound = sounds[k]
    for index = head[k], #list do
      if flags[index] and flags_sound[index]
        and within_window(list[index], t) then
        return true
      end
    end
    return false
  end

  -- count_within(k, t) / sound_within(k, t): scan speaker k's WHOLE history.
  -- A relocation can move a note at an OLDER time onto k, older than entries
  -- k's head already retired, so a head-relative scan is not enough there; the
  -- note's own 50 ms window must be checked against every entry k still has.
  local function count_within(k, t)
    local list = times[k]
    local flags = alive[k]
    local count = 0
    for index = 1, #list do
      if flags[index] and within_window(list[index], t) then
        count = count + 1
      end
    end
    return count
  end

  local function sound_within(k, t)
    local list = times[k]
    local flags = alive[k]
    local flags_sound = sounds[k]
    for index = 1, #list do
      if flags[index] and flags_sound[index]
        and within_window(list[index], t) then
        return true
      end
    end
    return false
  end

  -- live_notes_within(k, t): array indices of speaker k's LIVE play_notes that
  -- share a 50 ms span with t, ordered by frozen event index.  Used to empty a
  -- speaker for a play_sound: the earliest notes get first pick of the spare
  -- capacity, so a note that must be dropped is the LATEST (tick, layer, note)
  -- among them.  A live play_sound in the span makes the speaker ineligible;
  -- callers probe live_sound() first.
  local function live_notes_within(k, t)
    local list = times[k]
    local flags = alive[k]
    local flags_sound = sounds[k]
    local found = {}
    for index = head[k], #list do
      if flags[index] and not flags_sound[index]
        and within_window(list[index], t) then
        found[#found + 1] = index
      end
    end
    table.sort(found, function(a, b)
      return ids[k][a] < ids[k][b]
    end)
    return found
  end

  -- relocation_target(note_time, from): the FIRST speaker (ascending side,
  -- excluding `from`) that can take one more play_note at note_time -- no
  -- play_sound within that span and fewer than 8 notes already there.
  local function relocation_target(note_time, from)
    for k = 1, total_speakers do
      if k ~= from then
        retire(k, note_time)
        if not sound_within(k, note_time)
          and count_within(k, note_time) < MAX_NOTES_PER_WINDOW then
          return k
        end
      end
    end
    return nil
  end

  -- move(k, index, k2): relocate speaker k's entry `index` onto speaker k2.
  -- The owner map is part of the relocation: the emitted call now routes to k2.
  local function move(k, index, k2)
    local id = ids[k][index]
    append(k2, times[k][index], false, id)
    alive[k][index] = false
    owner[id] = speakers[k2]
  end

  -- free_for_sound(t): choose the speaker that gives up its span for a
  -- play_sound at t, evacuate its live notes, and return its index -- or nil
  -- when every speaker already holds a live play_sound in the span (then the
  -- sound has no speaker it could ever use and must drop).
  --
  -- CHOOSING THE SPEAKER: the cheapest one -- the speaker whose live notes
  -- leave the fewest notes with nowhere to go (its load minus the spare note
  -- slots left on the other speakers).  Ties break to the ascending side, so
  -- the outcome is deterministic.
  local function free_for_sound(t)
    local chosen = nil
    local chosen_drops = nil
    for k = 1, total_speakers do
      retire(k, t)
      if not live_sound(k, t) then
        local load = live_count(k, t)
        if load > 0 then
          local spare = 0
          for other = 1, total_speakers do
            if other ~= k and not live_sound(other, t) then
              local room = MAX_NOTES_PER_WINDOW - live_count(other, t)
              if room > 0 then
                spare = spare + room
              end
            end
          end
          local drops = load - spare
          if drops < 0 then
            drops = 0
          end
          if chosen == nil or drops < chosen_drops then
            chosen = k
            chosen_drops = drops
          end
        end
      end
    end
    if chosen == nil then
      return nil
    end

    -- Evacuate: relocate every live note of the span when a target exists;
    -- evict the ones that fit nowhere.  The sound is the most constrained item
    -- (one whole speaker-tick), so it takes priority over the notes.
    local notes = live_notes_within(chosen, t)
    for index = 1, #notes do
      local position = notes[index]
      local note_time = times[chosen][position]
      local target = relocation_target(note_time, chosen)
      if target ~= nil then
        move(chosen, position, target)
      else
        alive[chosen][position] = false
        owner[ids[chosen][position]] = nil
      end
    end
    return chosen
  end

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
        append(best, t, false, i)
        owner[i] = speakers[best]
      end

    elseif kind == "play_sound" then
      -- An empty speaker wins outright (first free speaker, ascending side),
      -- which keeps every placement that already worked exactly where it was.
      -- When none is empty, EVACUATE the cheapest speaker so a valid packing
      -- is not missed just because the notes were visited first.
      local best = nil
      for k = 1, total_speakers do
        retire(k, t)
        if live_count(k, t) == 0 then
          best = k
          break
        end
      end
      if best == nil then
        best = free_for_sound(t)
      end
      if best ~= nil then
        append(best, t, true, i)
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
