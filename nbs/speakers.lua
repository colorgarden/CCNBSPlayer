-- nbs/speakers.lua
--
-- PURE formula for how many CC:Tweaked `speaker` peripherals a song needs, and
-- the comparison the player uses to warn about under-provisioning.
--
-- FROZEN PUBLIC INTERFACE
--   local speakers = require("nbs.speakers")
--
--   speakers.MAX_NOTES_PER_TICK               -- 8
--   speakers.required_count(analysis)         -> integer >= 0
--   speakers.assess(analysis, found_count)    -> {
--     required, found, sufficient, shortfall,
--     peak, vanilla_at_peak, play_sound_at_peak,
--   }
--
-- `analysis` is exactly the value produced by nbs.analyze.  This module is a
-- PURE formula: it NEVER recomputes the peak concurrency or re-splits the
-- instrument buckets -- analyze already did that.  It only reads the fields
-- `vanilla_notes_at_peak` and `play_sound_notes_at_peak` (plus, for assess,
-- `peak_concurrent`, which it copies straight through).  It reads no clock,
-- does no I/O, holds no mutable state, and never mutates its input, so calling
-- it twice yields the same answer.
--
-- ===========================================================================
-- THE FORMULA -- AND WHY THE SECOND TERM IS ADDITIVE, NOT DIVIDED
-- ===========================================================================
--   required = ceil(vanilla_notes_at_peak / 8) + play_sound_notes_at_peak
--
-- A CC:Tweaked speaker accepts up to `max_notes_per_tick` (8) `playNote` calls
-- per game tick, but only ONE `playSound` call per game tick.  A single
-- playSound note (the v6 "trumpet" family) therefore consumes an ENTIRE
-- speaker-tick on its own.  Consequences a future reader will try to "optimise"
-- away, and must not:
--
--   * The playSound count is added WHOLE.  Dividing it by 8 is wrong: the
--     speaker cannot pack eight playSound calls into one tick.
--   * It is NOT folded into the same ceiling as the playNote count.  Adding it
--     before the ceiling (ceil((vanilla + playSound) / 8)) is wrong: one
--     vanilla note plus one trumpet note needs TWO speakers, not one.  Getting
--     this wrong tells the user "one speaker is enough" while a note is
--     silently dropped.
--
-- Worked examples (verified by the test suite):
--   (vanilla=1, playSound=1) -> 2   -- NOT 1
--   (vanilla=8, playSound=1) -> 2
--   (vanilla=8, playSound=2) -> 3
--   (vanilla=0, playSound=8) -> 8   -- eight separate speaker-ticks
--   (vanilla=0, playSound=0) -> 0   -- ceil(0/8) + 0 == 0: silence needs none
--
-- CUSTOM INSTRUMENTS DO NOT COUNT.  A custom-instrument note is refused at
-- playback, so it must not inflate the requirement.  `vanilla_notes_at_peak`
-- and `play_sound_notes_at_peak` already exclude custom instrument ids, so
-- there is deliberately NO third term here.  A peak made only of custom notes
-- yields required == 0 even though `peak_concurrent` may be large; the formula
-- must never read `peak_concurrent`.
--
-- Lua 5.2 / Cobalt constraints honoured: no integer division, no bitwise
-- operators, no utf8.*, no math.maxinteger, no collectgarbage, no string.dump,
-- no os.exit -- and here an explicit math.floor-based ceiling instead of
-- math.ceil, so the arithmetic is unambiguous and Cobalt-safe.

local speakers = {}

-- Maximum `playNote` calls one speaker accepts per game tick.
speakers.MAX_NOTES_PER_TICK = 8

-- Integer ceiling of a/b for a >= 0, b > 0, without math.ceil or integer
-- division.  Written as arithmetic so it is unambiguous on Lua 5.2 / Cobalt:
--   ceil(a / b) == floor(a / b) + (1 when there is a remainder else 0)
local function ceil_div(a, b)
  return math.floor(a / b) + (a % b > 0 and 1 or 0)
end

-- required_count(analysis) -> integer >= 0
function speakers.required_count(analysis)
  local vanilla = analysis.vanilla_notes_at_peak or 0
  local play_sound = analysis.play_sound_notes_at_peak or 0

  -- vanilla notes: up to MAX_NOTES_PER_TICK share one speaker-tick.
  -- playSound notes: one whole speaker-tick EACH -- hence the additive term.
  return ceil_div(vanilla, speakers.MAX_NOTES_PER_TICK) + play_sound
end

-- assess(analysis, found_count) -> summary table
--
-- Bundles the formula with the comparison the player needs: `found_count` is
-- how many speakers are actually mounted.  A `found_count` of 0 is legal.
function speakers.assess(analysis, found_count)
  local found = found_count or 0
  local required = speakers.required_count(analysis)

  local shortfall = required - found
  if shortfall < 0 then
    shortfall = 0
  end

  return {
    required = required,
    found = found,
    sufficient = found >= required,
    shortfall = shortfall,
    peak = analysis.peak_concurrent,
    vanilla_at_peak = analysis.vanilla_notes_at_peak,
    play_sound_at_peak = analysis.play_sound_notes_at_peak,
  }
end

return speakers
