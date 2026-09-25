-- tests/nbs/instrument_table_spec.lua
--
-- Tier-1 spec for nbs/instrument_table.lua -- the map from an NBS instrument id
-- to the EXACT call the CC:Tweaked speaker must make.
--
-- FROZEN INTERFACE UNDER TEST
--   local instrument_table = require("nbs.instrument_table")
--   instrument_table.PLAY_NOTE_NAMES   array; index i (1..16) == instrument id (i-1)
--   instrument_table.PLAY_NOTE_COUNT   16
--   instrument_table.play_note_name(id)  -> one of the 16 names, or nil
--   instrument_table.play_sound_name(id) -> a full sound-event id, or nil
--   instrument_table.resolve(id, vanilla_instrument_count)
--     -> { kind = "play_note",  name = <one of the 16> }
--     |  { kind = "play_sound", name = "minecraft:block.note_block.<...>" }
--     |  { kind = "custom",     custom_index = <integer> }
--
-- NOTE THE LOCAL NAME: the brief's illustrative snippet calls this module `it`,
-- but `it` is the GLOBAL test registrar in this suite, so the spec must bind it
-- to a different local.  The interface itself is unchanged.
--
-- PRIMARY-SOURCE CHECK (why the mapping below is trusted)
-- -------------------------------------------------------
-- The brief warned that two things are commonly mis-transcribed online:
--   (a) ids 2 and 3 are frequently SWAPPED, and
--   (b) some tables OMIT `banjo` and shift the later ids.
-- Both were checked against tryashtar/nbs-functions nbsreader/Model.cs
-- (GetInstrumentName): its switch maps  2 -> block.note_block.basedrum,
-- 3 -> block.note_block.snare, 4 -> block.note_block.hat, 14 -> banjo,
-- 15 -> pling.  That is exactly the table below -- the swap and the omission
-- are both wrong.  (koca2000/NoteBlockAPI getSoundNameByInstrument agrees.)
--
-- TWO ASYMMETRIES THAT ARE DELIBERATE, NOT TYPOS
--   * id 4 is `hat` (the NBS UI calls it "Click").
--   * id 2 is `basedrum` as ONE word; id 3 is `snare`.
--
-- THE ORDERING SUBTLETY -- READ BEFORE TOUCHING resolve()
-- -------------------------------------------------------
-- Whether instrument ids 16..19 are "v6 trumpets" or "custom instruments"
-- depends ONLY on the file header's vanilla_instrument_count:
--   * v6 file: count == 20 -> ids 16..19 are VANILLA trumpets (play_sound),
--     ids 20+ are custom.
--   * v5 file: count == 16 -> ids 16..19 are ALREADY custom (custom_index
--     0..3).  Playing them as trumpets would invent sounds the file never
--     referenced.  The custom check (`id >= vanilla_instrument_count`) must
--     therefore run BEFORE the trumpet lookup.  Tests 12, 13 and 17 pin this.
--
-- TRUMPETS ARE playSound-ONLY
--   speaker.playNote accepts EXACTLY the 16 names in PLAY_NOTE_NAMES and THROWS
--   on any other string.  ids 16..19 are not in that set, so they must never
--   leak into PLAY_NOTE_NAMES (test 7 guards the "throw in game" bug).

local instrument_table = require("nbs.instrument_table")

-- ---------------------------------------------------------------------------
-- Expected mapping (see the primary-source note above)
-- ---------------------------------------------------------------------------

-- The full 16-name playNote set, as a SET so the array order stays free.
local EXPECTED_PLAY_NOTE_SET = {
  harp = true,
  bass = true,
  basedrum = true,
  snare = true,
  hat = true,
  guitar = true,
  flute = true,
  bell = true,
  chime = true,
  xylophone = true,
  iron_xylophone = true,
  cow_bell = true,
  didgeridoo = true,
  bit = true,
  banjo = true,
  pling = true,
}

-- id -> playNote name, asserted one id at a time by test 3.
local EXPECTED_BY_ID = {
  [0] = "harp",
  [1] = "bass",
  [2] = "basedrum",
  [3] = "snare",
  [4] = "hat",
  [5] = "guitar",
  [6] = "flute",
  [7] = "bell",
  [8] = "chime",
  [9] = "xylophone",
  [10] = "iron_xylophone",
  [11] = "cow_bell",
  [12] = "didgeridoo",
  [13] = "bit",
  [14] = "banjo",
  [15] = "pling",
}

-- id -> full sound-event id for the four v6 trumpets.
local EXPECTED_TRUMPETS = {
  [16] = "minecraft:block.note_block.trumpet",
  [17] = "minecraft:block.note_block.trumpet_exposed",
  [18] = "minecraft:block.note_block.trumpet_weathered",
  [19] = "minecraft:block.note_block.trumpet_oxidized",
}

local EXPECTED_PLAY_NOTE_COUNT = 16

-- Build a name -> occurrence-count table from an array.
local function count_occurrences(list)
  local counts = {}
  for _, value in ipairs(list) do
    counts[value] = (counts[value] or 0) + 1
  end
  return counts
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("nbs.instrument_table -- the 16 playNote names", function()
  it("1. PLAY_NOTE_COUNT is 16 and PLAY_NOTE_NAMES has 16 entries", function()
    expect.equal(instrument_table.PLAY_NOTE_COUNT, EXPECTED_PLAY_NOTE_COUNT)
    expect.equal(#instrument_table.PLAY_NOTE_NAMES, EXPECTED_PLAY_NOTE_COUNT)
  end)

  it("2. the name set EQUALS the expected 16, each present exactly once", function()
    local counts = count_occurrences(instrument_table.PLAY_NOTE_NAMES)

    -- Each expected name present exactly once...
    local distinct = 0
    for name in pairs(EXPECTED_PLAY_NOTE_SET) do
      expect.equal(counts[name], 1)
      distinct = distinct + 1
    end
    -- ...and no name beyond the expected set (the lengths must agree).
    expect.equal(distinct, EXPECTED_PLAY_NOTE_COUNT)

    local observed = 0
    for _ in pairs(counts) do
      observed = observed + 1
    end
    expect.equal(observed, EXPECTED_PLAY_NOTE_COUNT)
  end)

  it("3. play_note_name id-by-id 0..15, incl. the 2/3 swap trap and hat", function()
    for id = 0, 15 do
      expect.equal(instrument_table.play_note_name(id), EXPECTED_BY_ID[id])
    end

    -- The two classic traps, called out explicitly.
    expect.equal(instrument_table.play_note_name(2), "basedrum")
    expect.equal(instrument_table.play_note_name(3), "snare")
    expect.equal(instrument_table.play_note_name(4), "hat")
  end)

  it("4. play_note_name returns nil (never throws) outside 0..15", function()
    expect.equal(instrument_table.play_note_name(16), nil)
    expect.equal(instrument_table.play_note_name(-1), nil)
    expect.equal(instrument_table.play_note_name(99), nil)
  end)

  it("7. no trumpet id (16..19) leaked into PLAY_NOTE_NAMES", function()
    -- Passing any of these to speaker.playNote THROWS in game; they must be
    -- reachable only through play_sound_name/resolve.
    for id = 16, 19 do
      local trumpet = EXPECTED_TRUMPETS[id]
      local short = trumpet:match("note_block%.(.+)$")
      for _, name in ipairs(instrument_table.PLAY_NOTE_NAMES) do
        expect.falsy(name == short)
        expect.falsy(name:find("trumpet", 1, true) ~= nil)
      end
    end
  end)
end)

describe("nbs.instrument_table -- the v6 trumpet playSound names", function()
  it("5. play_sound_name maps 16..19 to the four trumpet sound events", function()
    for id = 16, 19 do
      expect.equal(instrument_table.play_sound_name(id), EXPECTED_TRUMPETS[id])
    end
  end)

  it("6. play_sound_name is nil for the legacy ids 0..15", function()
    expect.equal(instrument_table.play_sound_name(0), nil)
    expect.equal(instrument_table.play_sound_name(15), nil)
  end)
end)

describe("nbs.instrument_table.resolve -- vanilla-count boundary", function()
  it("8. resolve(0, 16) is a play_note of harp", function()
    expect.deep_equal(instrument_table.resolve(0, 16),
      { kind = "play_note", name = "harp" })
  end)

  it("9. resolve(15, 16) is a play_note of pling", function()
    expect.deep_equal(instrument_table.resolve(15, 16),
      { kind = "play_note", name = "pling" })
  end)

  it("10. resolve(16, 20) is a v6 trumpet play_sound", function()
    expect.deep_equal(instrument_table.resolve(16, 20),
      { kind = "play_sound", name = "minecraft:block.note_block.trumpet" })
  end)

  it("11. resolve(19, 20) is the oxidized trumpet play_sound", function()
    expect.deep_equal(instrument_table.resolve(19, 20),
      { kind = "play_sound", name = "minecraft:block.note_block.trumpet_oxidized" })
  end)

  it("12. resolve(20, 20) is the FIRST custom instrument of a v6 file", function()
    expect.deep_equal(instrument_table.resolve(20, 20),
      { kind = "custom", custom_index = 0 })
  end)

  it("13. resolve(16, 16) is CUSTOM, not a trumpet (the critical v5 case)", function()
    -- A v5 file declares 16 vanilla instruments, so id 16 is its first custom
    -- instrument.  Naming it a trumpet would play a sound the file never meant.
    expect.deep_equal(instrument_table.resolve(16, 16),
      { kind = "custom", custom_index = 0 })
  end)

  it("14. legacy v0: resolve(0, 10) is a play_note of harp", function()
    expect.deep_equal(instrument_table.resolve(0, 10),
      { kind = "play_note", name = "harp" })
  end)

  it("15. legacy v0: resolve(10, 10) is custom index 0", function()
    expect.deep_equal(instrument_table.resolve(10, 10),
      { kind = "custom", custom_index = 0 })
  end)

  it("16. legacy v0: resolve(11, 10) is custom index 1", function()
    expect.deep_equal(instrument_table.resolve(11, 10),
      { kind = "custom", custom_index = 1 })
  end)
end)

-- ---------------------------------------------------------------------------
-- 18-20. bucket_of -- the shared classifier (the ONE owner of the rule)
--
-- analyze.lua and resolve() must classify an (id, count) pair identically.
-- bucket_of is that single classifier; resolve() maps its answer to a call.
-- ---------------------------------------------------------------------------

describe("nbs.instrument_table.bucket_of -- the single classification owner", function()
  it("18. bucket_of is total over the cross product and agrees with resolve", function()
    local counts = { 10, 16, 17, 18, 19, 20 }
    local ids = { 0, 15, 16, 17, 19, 20, 25 }

    for _, count in ipairs(counts) do
      for _, id in ipairs(ids) do
        local bucket = instrument_table.bucket_of(id, count)
        expect.truthy(bucket == "vanilla" or bucket == "play_sound"
          or bucket == "custom")

        local kind = instrument_table.resolve(id, count).kind
        if kind == "play_note" then
          expect.equal(bucket, "vanilla")
        else
          expect.equal(bucket, kind)
        end
      end
    end
  end)

  it("19. DEFENSIVE: a nil or non-numeric vanilla count falls back to the documented 16 boundary, never raises", function()
    -- Documented contract: a missing/non-numeric count is treated as the
    -- v1..v5 boundary of 16 (ids 0..15 vanilla, 16+ custom).  analyze.lua has
    -- always classified a missing count that way, so both modules stay in step.
    expect.deep_equal(instrument_table.resolve(5, nil),
      { kind = "play_note", name = "guitar" })
    expect.deep_equal(instrument_table.resolve(16, nil),
      { kind = "custom", custom_index = 0 })
    expect.deep_equal(instrument_table.resolve(19, nil),
      { kind = "custom", custom_index = 3 })
    expect.deep_equal(instrument_table.resolve(5, "not a number"),
      { kind = "play_note", name = "guitar" })

    expect.equal(instrument_table.bucket_of(5, nil), "vanilla")
    expect.equal(instrument_table.bucket_of(15, nil), "vanilla")
    expect.equal(instrument_table.bucket_of(16, nil), "custom")
  end)

  it("20. a non-numeric instrument id is CUSTOM (total, never raises)", function()
    expect.equal(instrument_table.bucket_of(nil, 16), "custom")
    expect.equal(instrument_table.resolve(nil, 16).kind, "custom")
    expect.equal(instrument_table.resolve(nil, 16).custom_index, nil)
  end)
end)

describe("nbs.instrument_table.resolve -- fuzz sweep over ids 0..255", function()
  it("17. every id lands in exactly one kind, and the kind rules hold", function()
    -- vanilla_instrument_count 10 (v0), 16 (v1..v5) and 20 (v6).
    local counts = { 10, 16, 20 }

    for _, vanilla in ipairs(counts) do
      local seen_note, seen_sound, seen_custom = 0, 0, 0

      for id = 0, 255 do
        local ok, result = pcall(instrument_table.resolve, id, vanilla)
        expect.truthy(ok)
        expect.truthy(result ~= nil)

        local kind = result.kind
        expect.truthy(kind == "play_note" or kind == "play_sound"
          or kind == "custom")

        if kind == "play_note" then
          -- play_note only ever for the 16 legacy ids.
          expect.truthy(id < 16)
          expect.equal(result.name, EXPECTED_BY_ID[id])
          seen_note = seen_note + 1
        elseif kind == "play_sound" then
          -- play_sound only for ids 16..19, and only below the vanilla boundary
          -- (i.e. only for a v6-or-newer file where 19 < count).
          expect.truthy(id >= 16 and id <= 19)
          expect.truthy(19 < vanilla)
          expect.equal(result.name, EXPECTED_TRUMPETS[id])
          seen_sound = seen_sound + 1
        else -- custom
          -- custom always has a non-negative index below the file's vanilla set.
          expect.truthy(id >= vanilla)
          expect.equal(result.custom_index, id - vanilla)
          seen_custom = seen_custom + 1
        end
      end

      -- Exactly one kind per id, covering all 256 ids.
      expect.equal(seen_note + seen_sound + seen_custom, 256)

      -- Per-count expectations, made explicit for the three boundaries.
      if vanilla == 10 then
        expect.equal(seen_note, 10)
        expect.equal(seen_sound, 0)
        expect.equal(seen_custom, 246)
      elseif vanilla == 16 then
        expect.equal(seen_note, 16)
        expect.equal(seen_sound, 0)
        expect.equal(seen_custom, 240)
      else -- vanilla == 20
        expect.equal(seen_note, 16)
        expect.equal(seen_sound, 4)
        expect.equal(seen_custom, 236)
      end
    end
  end)
end)
