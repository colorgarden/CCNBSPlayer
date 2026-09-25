-- tests/player/mapping_spec.lua
--
-- Tier-1 spec for player/mapping.lua -- the ONE frozen place where NBS numbers
-- become CC:Tweaked speaker arguments.  Later layers (the scheduler, the
-- dispatcher, the fan-out) assert on the EXACT arguments handed to the speaker,
-- so this module must be a pure, total, documented function set with no hidden
-- state and no "helpful" corrections.
--
-- FROZEN PUBLIC INTERFACE (consumers depend on these EXACT names):
--   local mapping = require("player.mapping")
--   mapping.speaker_volume(volume_0_to_100)             -> number  0..3
--   mapping.pitch_semitones(key)                        -> integer, key - 33, UNCLAMPED
--   mapping.combined_volume(layer_volume, note_velocity) -> number 0..100
--   mapping.play_sound_pitch(key)                       -> number ratio 0.5..2.0
--   mapping.cents_to_semitones(pitch_cents)             -> number, cents / 100
--   mapping.NATIVE_MIN_KEY                              -- 33
--   mapping.NATIVE_MAX_KEY                              -- 57
--
-- The two deliberate, counter-intuitive decisions this spec pins down:
--   * pitch_semitones is NOT clamped: Minecraft accepts out-of-range note
--     pitches and community resource packs supply the samples.  Clamping would
--     silently break the extended-range feature; the user is warned elsewhere.
--   * Panning is dropped: CC:Tweaked's speaker has no per-note panning
--     argument, so the mapping never invents one.
--
-- EXACT RULES under test:
--   speaker_volume(v)   = clamp(round_half_up(v / 100 * 3), 0, 3)
--   combined_volume(l, n) = clamp((l * n) / 100, 0, 100)
--   pitch_semitones(k)  = k - 33                       (no clamp)
--   play_sound_pitch(k) = clamp(2 ^ ((k - 45) / 12), 0.5, 2.0)
--   cents_to_semitones(c) = c / 100                    (residual, dropped by caller)
--
-- No fixtures on disk: every case is an arithmetic table built in code.

local mapping = require("player.mapping")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- round_half_up: matches the module's documented rounding rule (Lua 5.2 has no
-- math.round, so spell it out).  floor(x + 0.5) rounds .5 upward.
local function round_half_up(x)
  return math.floor(x + 0.5)
end

-- is_finite: true for real numbers that are neither NaN nor +/-inf.
local function is_finite(value)
  if type(value) ~= "number" then
    return false
  end
  if value ~= value then
    return false
  end
  return value ~= math.huge and value ~= -math.huge
end

-- in_range: numeric value within [lo, hi], inclusive.
local function in_range(value, lo, hi)
  return type(value) == "number" and value >= lo and value <= hi
end

-- The boundary table the product decision specifies.  Verified against the
-- documented round_half_up rule so the spec fails loudly if either the rule or
-- the numbers ever drift apart.
local SPEAKER_VOLUME_TABLE = {
  { 0, 0 }, { 1, 0 }, { 16, 0 }, { 17, 1 },
  { 50, 2 }, { 83, 2 }, { 84, 3 }, { 100, 3 },
}

-- ---------------------------------------------------------------------------
-- 1. speaker_volume boundary table (and the rule behind it)
-- ---------------------------------------------------------------------------

describe("mapping.speaker_volume boundaries", function()
  it("1a. the documented round_half_up rule reproduces every boundary in the table", function()
    for _, pair in ipairs(SPEAKER_VOLUME_TABLE) do
      local input, expected = pair[1], pair[2]
      expect.equal(round_half_up(input / 100 * 3), expected)
    end
  end)

  it("1b. speaker_volume maps 0/1/16/17/50/83/84/100 to 0/0/0/1/2/2/3/3", function()
    for _, pair in ipairs(SPEAKER_VOLUME_TABLE) do
      local input, expected = pair[1], pair[2]
      expect.equal(mapping.speaker_volume(input), expected)
    end
  end)

  it("1c. the three headline anchors hold: 0 -> 0, 50 -> 2, 100 -> 3", function()
    expect.equal(mapping.speaker_volume(0), 0)
    expect.equal(mapping.speaker_volume(50), 2)
    expect.equal(mapping.speaker_volume(100), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. speaker_volume out-of-range input clamps into 0..3
-- ---------------------------------------------------------------------------

describe("mapping.speaker_volume out-of-range clamping", function()
  it("2. clamps -50 -> 0 and 500 -> 3", function()
    expect.equal(mapping.speaker_volume(-50), 0)
    expect.equal(mapping.speaker_volume(500), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. pitch_semitones native range
-- ---------------------------------------------------------------------------

describe("mapping.pitch_semitones native range", function()
  it("3. maps the native NBS range 33 -> 0, 45 -> 12, 57 -> 24", function()
    expect.equal(mapping.pitch_semitones(33), 0)
    expect.equal(mapping.pitch_semitones(45), 12)
    expect.equal(mapping.pitch_semitones(57), 24)
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. pitch_semitones is NOT clamped (extended-range resource-pack decision)
-- ---------------------------------------------------------------------------

describe("mapping.pitch_semitones extended range is UNCLAMPED", function()
  it("4a. passes out-of-native keys through verbatim: 20 -> -13, 32 -> -1, 58 -> 25, 90 -> 57", function()
    expect.equal(mapping.pitch_semitones(20), -13)
    expect.equal(mapping.pitch_semitones(32), -1)
    expect.equal(mapping.pitch_semitones(58), 25)
    expect.equal(mapping.pitch_semitones(90), 57)
  end)

  it("4b. a clamp would be caught: key 20 must NOT collapse to 0 / the native floor", function()
    expect.truthy(mapping.pitch_semitones(20) ~= 0)
    expect.truthy(mapping.pitch_semitones(20) ~= mapping.pitch_semitones(33))
    expect.truthy(mapping.pitch_semitones(90) ~= mapping.pitch_semitones(57))
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. combined_volume formula
-- ---------------------------------------------------------------------------

describe("mapping.combined_volume formula", function()
  it("5. (100,100)->100, (50,100)->50, (100,50)->50, (80,70)->56, (0,100)->0, (100,0)->0", function()
    expect.equal(mapping.combined_volume(100, 100), 100)
    expect.equal(mapping.combined_volume(50, 100), 50)
    expect.equal(mapping.combined_volume(100, 50), 50)
    expect.equal(mapping.combined_volume(80, 70), 56)
    expect.equal(mapping.combined_volume(0, 100), 0)
    expect.equal(mapping.combined_volume(100, 0), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 6. combined_volume clamps to 0..100
-- ---------------------------------------------------------------------------

describe("mapping.combined_volume clamping", function()
  it("6. (200,100) clamps to 100", function()
    expect.equal(mapping.combined_volume(200, 100), 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. play_sound_pitch centre and octave
-- ---------------------------------------------------------------------------

describe("mapping.play_sound_pitch anchors", function()
  it("7a. the reference key 45 (F#4) is ratio 1.0", function()
    expect.near(mapping.play_sound_pitch(45), 1.0, 1e-9)
  end)

  it("7b. one octave up, key 57 (F#5), is ratio 2.0", function()
    expect.near(mapping.play_sound_pitch(57), 2.0, 1e-9)
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. play_sound_pitch clamps into 0.5..2.0 for the whole key space
-- ---------------------------------------------------------------------------

describe("mapping.play_sound_pitch range clamping", function()
  it("8a. a very low key (20) clamps up to 0.5 and a very high key (90) clamps down to 2.0", function()
    expect.near(mapping.play_sound_pitch(20), 0.5, 1e-9)
    expect.near(mapping.play_sound_pitch(90), 2.0, 1e-9)
  end)

  it("8b. a sweep of keys 0..127 always stays within 0.5..2.0", function()
    for key = 0, 127 do
      local ratio = mapping.play_sound_pitch(key)
      expect.truthy(in_range(ratio, 0.5, 2.0))
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. play_sound_pitch monotonicity across the representable octave
-- ---------------------------------------------------------------------------

describe("mapping.play_sound_pitch monotonicity", function()
  it("9. over keys 45..57 the returned ratio is non-decreasing", function()
    local previous = mapping.play_sound_pitch(45)
    for key = 46, 57 do
      local current = mapping.play_sound_pitch(key)
      expect.truthy(current >= previous)
      previous = current
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. cents_to_semitones
-- ---------------------------------------------------------------------------

describe("mapping.cents_to_semitones", function()
  it("10. 0 -> 0, 100 -> 1, -50 -> -0.5, 37 -> 0.37", function()
    expect.equal(mapping.cents_to_semitones(0), 0)
    expect.equal(mapping.cents_to_semitones(100), 1)
    expect.equal(mapping.cents_to_semitones(-50), -0.5)
    expect.near(mapping.cents_to_semitones(37), 0.37, 1e-12)
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. Cents are DROPPED, explicitly: the integer pitch cannot carry them
-- ---------------------------------------------------------------------------

describe("mapping cents residual is dropped by the integer pitch", function()
  it("11. key 45 -> integer 12 semitones, while its +50c residual is a separate 0.5", function()
    -- The caller can observe the residual...
    expect.near(mapping.cents_to_semitones(50), 0.5, 1e-12)
    -- ...but pitch_semitones(45) is the integer 12 and carries no cents.
    expect.equal(mapping.pitch_semitones(45), 12)
    expect.truthy(mapping.pitch_semitones(45) % 1 == 0)
    expect.truthy(mapping.pitch_semitones(45) ~= 12.5)
    -- The two concerns stay separate: pitch_semitones never folds cents in.
    expect.equal(mapping.pitch_semitones(45), mapping.pitch_semitones(45))
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. Native key boundaries are exposed as constants
-- ---------------------------------------------------------------------------

describe("mapping native key constants", function()
  it("12. NATIVE_MIN_KEY is 33 and NATIVE_MAX_KEY is 57", function()
    expect.equal(mapping.NATIVE_MIN_KEY, 33)
    expect.equal(mapping.NATIVE_MAX_KEY, 57)
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. Totality fuzz: no call raises, every result is finite and in range
-- ---------------------------------------------------------------------------

describe("mapping totality fuzz", function()
  it("13. layer_volume x note_velocity x key sweep never raises and stays in range", function()
    local probes = { 0, 1, 50, 99, 100 }

    for _, layer_volume in ipairs(probes) do
      for _, note_velocity in ipairs(probes) do
        local ok_volume, volume = pcall(mapping.combined_volume, layer_volume, note_velocity)
        expect.truthy(ok_volume)
        expect.truthy(is_finite(volume))
        expect.truthy(in_range(volume, 0, 100))

        for key = 0, 127 do
          local ok_pitch, semitones = pcall(mapping.pitch_semitones, key)
          expect.truthy(ok_pitch)
          expect.truthy(is_finite(semitones))

          local ok_ratio, ratio = pcall(mapping.play_sound_pitch, key)
          expect.truthy(ok_ratio)
          expect.truthy(is_finite(ratio))
          expect.truthy(in_range(ratio, 0.5, 2.0))
        end
      end
    end

    for _, v in ipairs(probes) do
      local ok, volume = pcall(mapping.speaker_volume, v)
      expect.truthy(ok)
      expect.truthy(is_finite(volume))
      expect.truthy(in_range(volume, 0, 3))
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 14. Purity / determinism: no shared mutable state, order-independent answers
-- ---------------------------------------------------------------------------

describe("mapping purity and determinism", function()
  it("14a. calling each function twice returns identical results", function()
    expect.equal(mapping.speaker_volume(50), mapping.speaker_volume(50))
    expect.equal(mapping.pitch_semitones(20), mapping.pitch_semitones(20))
    expect.equal(mapping.combined_volume(80, 70), mapping.combined_volume(80, 70))
    expect.equal(mapping.play_sound_pitch(60), mapping.play_sound_pitch(60))
    expect.equal(mapping.cents_to_semitones(37), mapping.cents_to_semitones(37))
  end)

  it("14b. calling in different orders gives the same answers", function()
    local first = {
      mapping.speaker_volume(50),
      mapping.pitch_semitones(20),
      mapping.combined_volume(80, 70),
      mapping.play_sound_pitch(57),
      mapping.cents_to_semitones(37),
    }

    -- Same calls, reversed order: nothing was cached or mutated between them.
    local reversed = {
      mapping.cents_to_semitones(37),
      mapping.play_sound_pitch(57),
      mapping.combined_volume(80, 70),
      mapping.pitch_semitones(20),
      mapping.speaker_volume(50),
    }

    expect.equal(reversed[1], first[5])
    expect.equal(reversed[2], first[4])
    expect.equal(reversed[3], first[3])
    expect.equal(reversed[4], first[2])
    expect.equal(reversed[5], first[1])
  end)
end)
