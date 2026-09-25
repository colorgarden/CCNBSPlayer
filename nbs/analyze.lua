-- nbs/analyze.lua
--
-- PURE load-time analysis pass for a decoded Note Block Studio song.
--
-- FROZEN PUBLIC INTERFACE
--   local analyze = require("nbs.analyze")
--   analyze.analyze(song) -> result
--
--   `song` is the value produced by nbs.decode (fields used here: header,
--   notes); `result` has these EXACT field names:
--     total_notes              integer  #song.notes
--     ticks_per_second         number   header.tempo_ticks_per_second
--     tick_ms                  number   1000 / ticks_per_second
--     peak_concurrent          integer  max simultaneous notes in any 50 ms window
--     peak_window_ms           integer  50 (constant)
--     vanilla_notes_at_peak    integer  peak-window notes classified "vanilla"
--     play_sound_notes_at_peak integer  peak-window notes classified "play_sound"
--     has_extended_range       boolean  true when ANY key is outside 33..57
--     min_key, max_key         integer  over all notes (0 and 0 when there are none)
--     all_notes_custom         boolean  true when the song has notes but NONE of
--                                        them classify as vanilla/play_sound --
--                                        i.e. every note is refused at playback
--     loop = { loop, max_loop_count, loop_start_tick }  copied from the header
--
-- This module is a PURE function: it reads no clock, touches no peripheral, does
-- no file I/O and relies on no global mutable state, so calling it twice on the
-- same song yields byte-identical values.  It only READS `song`; it never mutates
-- its input.
--
-- ===========================================================================
-- THE INVARIANT MOST LIKELY TO BE DONE WRONG: NBS TICK != 50 ms GAME TICK
-- ===========================================================================
-- NBS stores tempo as `tempo_raw` in hundredths of a "tick per second", so
--
--     ticks_per_second = tempo_raw / 100
--     ONE NBS TICK     = 1000 / ticks_per_second  milliseconds
--
-- The Minecraft speaker ceiling (one note per instrument per game tick) is
-- enforced per GAME tick, and one game tick is 50 ms -- a DIFFERENT clock from
-- the NBS tick.  Conflating the two is the single most likely bug here.
--
-- Worked example: at 10 NBS ticks/second, `tick_ms` is 100, so every NBS tick
-- spans TWO 50 ms game windows.  Ten notes on one NBS tick share one instant
-- (one window, peak 10), while ten notes on ten CONSECUTIVE NBS ticks are 100 ms
-- apart (ten separate windows, peak 1).  The window test is on millisecond time,
-- never on tick distance.
--
-- PEAK ALGORITHM
--   1. Map each note to a start time in ms: t = note.tick * tick_ms.
--   2. Sort those times ascending.
--   3. Two-pointer sliding window: for each left index i, advance a right index
--      j while times[j] - times[i] < 50 (STRICT `<`, so a gap of exactly 50 ms
--      starts a new window).  The window holds j - i notes.
--   4. peak_concurrent is the maximum count over every left index; anchoring the
--      left edge on a note is complete (the maximum over all 50 ms windows is
--      always attained by a window whose left edge sits on some note).
--
-- INSTRUMENT BUCKETS (only the chosen peak window is classified)
--   The classification rule has ONE owner: nbs/instrument_table.bucket_of --
--   the same classifier player/plan.lua reaches through resolve().  A
--   re-implementation here (hardcoded 0..15 / 16..19 constants) previously
--   DISAGREED with resolve for vanilla counts 10 and 17..19, which
--   under-budgeted speakers for v6 trumpets and produced a bogus "speakers"
--   warning for legacy custom ids.  Delegating keeps the analyzer's budget
--   identical to the calls the player will actually make:
--     vanilla     below the file's vanilla boundary, id 0..15
--     play_sound  16..19 below that boundary (the v6 "trumpet" native sounds)
--     custom      anything else -- refused at playback, so it counts toward
--                 NEITHER bucket.  It still counts in peak_concurrent because
--                 it is a simultaneous note; it just must not inflate the
--                 speaker requirement for the buckets the player can schedule.
--
-- TIE-BREAK (deterministic)
--   When several distinct windows attain the same maximum, the reported bucket
--   split is taken from the EARLIEST window in time (the smallest left index).
--   The two-pointer loop only replaces the recorded peak on a STRICT increase,
--   so the first window to reach the maximum wins.
--
-- Lua 5.2 / Cobalt constraints honoured: no `//`, no bitwise operators, no
-- utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.

local instrument_table = require("nbs.instrument_table")
local mapping = require("player.mapping")

local analyze = {}

-- One Minecraft game tick, in milliseconds.  This is the speaker-ceiling window.
local PEAK_WINDOW_MS = 50

-- Native two-octave key range (33 = F#3, 45 = F#4, 57 = F#5), inclusive.
-- The NUMBERS are owned in ONE place: player/mapping.lua's public
-- NATIVE_MIN_KEY / NATIVE_MAX_KEY.  Referencing them here keeps the analyzer's
-- extended-range boundary identical to the mapping the player uses;
-- mapping.lua requires nothing, so this creates no require cycle.

-- analyze.analyze(song) -> result
function analyze.analyze(song)
  local header = song.header or {}
  local notes = song.notes or {}
  local total_notes = #notes

  local ticks_per_second = header.tempo_ticks_per_second
  local tick_ms = 1000 / ticks_per_second

  -- Key range + extended-range scan + playable-note count, over ALL notes
  -- (independent of the 50 ms window).
  local min_key = 0
  local max_key = 0
  local has_extended_range = false
  -- How many notes the player can actually schedule (vanilla or play_sound).
  -- A note that is neither is a custom instrument, refused at playback; when
  -- this stays 0 on a non-empty song the whole song is silent.
  local playable_notes = 0
  for index = 1, total_notes do
    local note = notes[index]
    local key = note.key
    if index == 1 then
      min_key = key
      max_key = key
    else
      if key < min_key then
        min_key = key
      end
      if key > max_key then
        max_key = key
      end
    end
    if key < mapping.NATIVE_MIN_KEY or key > mapping.NATIVE_MAX_KEY then
      has_extended_range = true
    end
    local bucket = instrument_table.bucket_of(note.instrument,
      header.vanilla_instrument_count)
    if bucket == "vanilla" or bucket == "play_sound" then
      playable_notes = playable_notes + 1
    end
  end

  -- Project every note to its start time in milliseconds, keeping the
  -- instrument alongside (needed to classify the chosen peak window).
  local items = {}
  for index = 1, total_notes do
    local note = notes[index]
    items[index] = {
      t = note.tick * tick_ms,
      instrument = note.instrument,
    }
  end

  table.sort(items, function(a, b)
    return a.t < b.t
  end)

  -- Two-pointer sliding window over the sorted times.  `j` is monotonic: as the
  -- left edge moves right the window can only extend, never retract, so a single
  -- forward pass is exact.
  local peak = 0
  local peak_left = nil
  local j = 1
  for i = 1, total_notes do
    if j < i then
      j = i
    end
    while j <= total_notes and items[j].t - items[i].t < PEAK_WINDOW_MS do
      j = j + 1
    end
    local count = j - i
    if count > peak then
      peak = count
      peak_left = i
    end
  end

  -- Classify only the chosen peak window.  A strict `>` above means the earliest
  -- window that attains the maximum is the one recorded.
  local vanilla_at_peak = 0
  local play_sound_at_peak = 0
  if peak_left ~= nil and peak > 0 then
    for index = peak_left, peak_left + peak - 1 do
      -- ONE classifier: the very same function player/plan.lua reaches through
      -- instrument_table.resolve, so the analyzer and the allocator can never
      -- disagree about which notes need a playNote and which need a playSound.
      local bucket = instrument_table.bucket_of(items[index].instrument,
        header.vanilla_instrument_count)
      if bucket == "vanilla" then
        vanilla_at_peak = vanilla_at_peak + 1
      elseif bucket == "play_sound" then
        play_sound_at_peak = play_sound_at_peak + 1
      end
    end
  end

  return {
    total_notes = total_notes,
    ticks_per_second = ticks_per_second,
    tick_ms = tick_ms,
    peak_concurrent = peak,
    peak_window_ms = PEAK_WINDOW_MS,
    vanilla_notes_at_peak = vanilla_at_peak,
    play_sound_notes_at_peak = play_sound_at_peak,
    has_extended_range = has_extended_range,
    min_key = min_key,
    max_key = max_key,
    -- True for a non-empty song in which EVERY note is refused at playback
    -- (custom instrument ids).  A plain boolean, derived from the whole song --
    -- NOT from the peak window, whose buckets can be 0/0 for a song that still
    -- has playable notes elsewhere.
    all_notes_custom = total_notes > 0 and playable_notes == 0,
    loop = {
      loop = header.loop,
      max_loop_count = header.max_loop_count,
      loop_start_tick = header.loop_start_tick,
    },
  }
end

return analyze
