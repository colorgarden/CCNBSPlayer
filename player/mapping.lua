-- player/mapping.lua
--
-- The ONE frozen place where NBS numbers become CC:Tweaked speaker arguments.
--
-- Every later layer (plan/speaker/dispatch/fanout) asserts on the EXACT numbers
-- this module hands to `speaker.playNote` / `speaker.playSound`, so this module
-- is deliberately a set of PURE, TOTAL, documented functions with NO state and
-- NO "helpful" corrections.  Two product decisions below are counter-intuitive
-- and MUST be honoured exactly.
--
-- ---------------------------------------------------------------------------
-- 1. Volume formula
-- ---------------------------------------------------------------------------
-- NBS stores a per-layer volume (0..100) and a per-note velocity (0..100); the
-- audible combination is their product scaled back to 0..100:
--
--     combined_volume = (layer_volume * note_velocity) / 100
--
-- A legacy note has no stored velocity, so the decoder supplies 100 for it (the
-- neutral element), and combined_volume(layer, 100) == layer.
--
-- The speaker's own volume argument is a 0.0..3.0 scalar:
--
--     speaker_volume(v) = clamp(round_half_up(v / 100 * 3), 0, 3)
--
-- Rounding is HALF UP: `floor(x + 0.5)`, so 1.5 -> 2. This is documented and
-- pinned by tests/player/mapping_spec.lua.  Inputs outside 0..100 clamp.
--
-- ---------------------------------------------------------------------------
-- 2. Pitch (playNote semitones) is NOT CLAMPED -- product decision
-- ---------------------------------------------------------------------------
--     pitch_semitones(key) = key - 33
--
-- NBS key 33 (F#3) is semitone 0, key 45 (F#4) is 12, key 57 (F#5) is 24 -- a
-- two-octave native range -- but Minecraft's note-block pitch accepts
-- out-of-range values and community "extended range" resource packs supply the
-- extra samples.  Clamping to 0..24 here would SILENTLY BREAK the extended-range
-- feature this project promises, so we do NOT clamp: key 20 -> -13 and key 90
-- -> 57 are passed through verbatim.  Out-of-native-range notes are reported to
-- the user by a separate warning layer (not here) -- the mapping never decides
-- what is playable, it only translates.
--
-- ---------------------------------------------------------------------------
-- 3. Panning is DROPPED -- CC:Tweaked has no per-note panning
-- ---------------------------------------------------------------------------
-- NBS layers carry a panning value (0..200), but `speaker.playNote` and
-- `speaker.playSound` have no panning argument.  We therefore drop panning
-- entirely: this module deliberately exposes NO panning function and no caller
-- may invent an extra argument.  Stereo placement is simply not representable.
--
-- ---------------------------------------------------------------------------
-- 4. playSound pitch limitation (ratio, clamped to 0.5..2.0)
-- ---------------------------------------------------------------------------
--     play_sound_pitch(key) = clamp(2 ^ ((key - 45) / 12), 0.5, 2.0)
--
-- `speaker.playSound` takes a RATIO in 0.5..2.0 (about +/- one octave) around
-- the reference key 45 (F#4), which is ratio 1.0.  A note whose key lies far
-- outside that window cannot be represented faithfully: we clamp so it stays
-- audible but its pitch WILL be wrong.  This is preferable to throwing, and the
-- mismatch is surfaced by the warning layer, not hidden here.
--
-- cents_to_semitones(c) = c / 100 exposes the NBS per-note cents offset as an
-- explicit, testable residual.  `playNote`'s pitch argument is an INTEGER number
-- of semitones, so the caller DROPS this residual -- the drop is intentional and
-- kept separate from pitch_semitones() so it is visible rather than smuggled in.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8, no state.

local mapping = {}

-- The boundaries of the native NBS key range (a two-octave window).  Exposed so
-- the warning layer and tests share one definition.  These are NOT clamp bounds
-- for pitch_semitones -- see the module header.
mapping.NATIVE_MIN_KEY = 33
mapping.NATIVE_MAX_KEY = 57

-- The reference key for the playSound ratio: key 45 (F#4) maps to ratio 1.0.
local RATIO_REFERENCE_KEY = 45
-- The speaker's playSound pitch ratio window (about one octave either way).
local RATIO_MIN = 0.5
local RATIO_MAX = 2.0

-- clamp(value, lo, hi): returns value clamped into [lo, hi].  Used by the
-- bounded outputs only; pitch_semitones is intentionally left unbounded.
local function clamp(value, lo, hi)
  if value < lo then
    return lo
  end
  if value > hi then
    return hi
  end
  return value
end

-- round_half_up(x): floor(x + 0.5).  17/100*3 = 0.51 is the first volume that
-- rounds up to 1 (16/100*3 = 0.48 rounds down to 0), and 1.5 -> 2 at volume 50,
-- matching the boundary table in the spec.
local function round_half_up(x)
  return math.floor(x + 0.5)
end

-- mapping.speaker_volume(volume_0_to_100) -> number in 0..3
--
-- Scales an NBS 0..100 volume onto the speaker's 0.0..3.0 volume argument,
-- rounding half up and clamping out-of-range inputs.  See rule (1) above.
function mapping.speaker_volume(volume_0_to_100)
  return clamp(round_half_up(volume_0_to_100 / 100 * 3), 0, 3)
end

-- mapping.pitch_semitones(key) -> integer, key - 33, UNCLAMPED
--
-- Translates an NBS key to playNote's semitone offset.  DELIBERATELY NOT
-- CLAMPED: extended-range resource packs make out-of-range pitches meaningful,
-- and the warning layer -- not this function -- decides what to complain about.
-- See rule (2) above.
function mapping.pitch_semitones(key)
  return key - 33
end

-- mapping.combined_volume(layer_volume, note_velocity) -> number in 0..100
--
-- Combines the two 0..100 NBS volumes with the product formula, then clamps to
-- 0..100.  A legacy note's missing velocity is supplied as 100 by the decoder.
function mapping.combined_volume(layer_volume, note_velocity)
  return clamp((layer_volume * note_velocity) / 100, 0, 100)
end

-- mapping.play_sound_pitch(key) -> number ratio, clamped into 0.5..2.0
--
-- The ideal ratio is 2 ^ ((key - 45) / 12) around the key-45 reference; it is
-- clamped into playSound's 0.5..2.0 window.  Keys far from 45 are audible but
-- pitched wrong -- a documented limitation, see rule (4) above.
function mapping.play_sound_pitch(key)
  local ideal = 2 ^ ((key - RATIO_REFERENCE_KEY) / 12)
  return clamp(ideal, RATIO_MIN, RATIO_MAX)
end

-- mapping.cents_to_semitones(pitch_cents) -> number, pitch_cents / 100
--
-- Exposes the NBS cents offset as an explicit residual.  The caller DROPS it
-- when building the integer playNote pitch; keeping it here (and out of
-- pitch_semitones) makes that intentional drop visible and testable.
function mapping.cents_to_semitones(pitch_cents)
  return pitch_cents / 100
end

return mapping
