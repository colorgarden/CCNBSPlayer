-- nbs/instrument_table.lua
--
-- Maps an NBS instrument id to the EXACT call the CC:Tweaked speaker must make.
--
-- This module answers ONE question: "which call, with which name?".  It owns no
-- volume and no pitch -- player/mapping.lua owns those -- so a caller can pair
-- the name returned here with its own volume/pitch arguments.
--
-- FROZEN PUBLIC INTERFACE (later layers depend on the exact shapes)
--   instrument_table.PLAY_NOTE_NAMES    array of the 16 legacy names;
--                                       index i (1..16) == instrument id (i-1)
--   instrument_table.PLAY_NOTE_COUNT    16
--   instrument_table.play_note_name(id)   -> name string, or nil outside 0..15
--   instrument_table.play_sound_name(id)  -> sound-event string, or nil
--   instrument_table.resolve(id, vanilla_instrument_count)
--     -> { kind = "play_note",  name = <one of the 16> }
--     |  { kind = "play_sound", name = "minecraft:block.note_block.<...>" }
--     |  { kind = "custom",     custom_index = <integer> }
--
-- WHY ids 16..19 ARE playSound-ONLY
--   speaker.playNote accepts EXACTLY the 16 names in PLAY_NOTE_NAMES and THROWS
--   on any other string.  The Minecraft 26/26.1 trumpet note-block sounds
--   (NBS ids 16..19) are NOT in that set, so passing them to playNote would
--   raise inside the game.  They are therefore reached only through
--   speaker.playSound with a full sound-event id.  Keeping them OUT of
--   PLAY_NOTE_NAMES is precisely what prevents the in-game throw.
--
-- WHY THE FILE'S vanilla_instrument_count DECIDES TRUMPET-vs-CUSTOM
--   Whether ids 16..19 mean "v6 trumpet" or "first custom instrument" depends
--   ONLY on the count in the file's own header, never on the id alone:
--     * A v6 file declares 20 -> ids 16..19 are vanilla trumpets (playSound)
--       and ids 20+ are custom.
--     * A v5 file declares 16 -> ids 16..19 are ALREADY custom (custom_index
--       0..3).  Treating them as trumpets would invent sounds the file never
--       referenced.
--   The custom test (`id >= vanilla_instrument_count`) must therefore run
--   FIRST, before the trumpet lookup.  Inverting that order is the subtle bug
--   this module exists to avoid.
--
-- NAME ASYMMETRIES THAT ARE DELIBERATE, NOT TYPOS
--   * id 4 is `hat` (the NBS UI labels it "Click").
--   * id 2 is `basedrum`, spelled as ONE word; id 3 is `snare`.
--   Verified against tryashtar/nbs-functions nbsreader/Model.cs
--   (GetInstrumentName) and koca2000/NoteBlockAPI getSoundNameByInstrument,
--   which both map 2 -> basedrum and 3 -> snare (the swapped chart is wrong).
--
-- TARGET INTERPRETER
--   Stock Lua 5.2 / CC:Tweaked Cobalt: no utf8.*, no bitwise operators, no
--   integer division, no os.exit.

local instrument_table = {}

-- The 16 names speaker.playNote accepts, indexed so that
-- PLAY_NOTE_NAMES[id + 1] is the name for instrument id `id` (0..15).
local PLAY_NOTE_NAMES = {
  "harp",           -- id 0
  "bass",           -- id 1
  "basedrum",       -- id 2  (one word)
  "snare",          -- id 3
  "hat",            -- id 4  (NBS calls this "Click")
  "guitar",         -- id 5
  "flute",          -- id 6
  "bell",           -- id 7
  "chime",          -- id 8
  "xylophone",      -- id 9
  "iron_xylophone", -- id 10
  "cow_bell",       -- id 11
  "didgeridoo",     -- id 12
  "bit",            -- id 13
  "banjo",          -- id 14
  "pling",          -- id 15
}

-- The four v6 trumpet sound events, keyed directly by id 16..19.  These are
-- playSound-only (see the module header).
local PLAY_SOUND_NAMES = {
  [16] = "minecraft:block.note_block.trumpet",
  [17] = "minecraft:block.note_block.trumpet_exposed",
  [18] = "minecraft:block.note_block.trumpet_weathered",
  [19] = "minecraft:block.note_block.trumpet_oxidized",
}

instrument_table.PLAY_NOTE_NAMES = PLAY_NOTE_NAMES
instrument_table.PLAY_NOTE_COUNT = 16

-- play_note_name(id) -> the playNote name, or nil when `id` is not in 0..15.
-- Never throws: a caller may probe any id (e.g. an out-of-range note) safely.
function instrument_table.play_note_name(id)
  if type(id) == "number" and id >= 0 and id <= 15 then
    return PLAY_NOTE_NAMES[id + 1]
  end
  return nil
end

-- play_sound_name(id) -> the trumpet sound-event id, or nil.  Only ids 16..19
-- have a playSound form; the legacy ids are playNote-only and return nil here.
function instrument_table.play_sound_name(id)
  if type(id) == "number" and id >= 16 and id <= 19 then
    return PLAY_SOUND_NAMES[id]
  end
  return nil
end

-- resolve(instrument_id, vanilla_instrument_count) -> a call descriptor.
--
-- ORDER MATTERS.  The custom check runs FIRST against the file's own vanilla
-- count, so a v5 file (count 16) classifies ids 16..19 as custom instead of
-- trumpets.  Only ids below the vanilla boundary can be legacy notes or v6
-- trumpets.
function instrument_table.resolve(instrument_id, vanilla_instrument_count)
  -- Custom: anything at or above the file's vanilla instrument count.  A later
  -- layer refuses these at playback and only needs custom_index for diagnostics.
  if instrument_id >= vanilla_instrument_count then
    return {
      kind = "custom",
      custom_index = instrument_id - vanilla_instrument_count,
    }
  end

  -- Vanilla legacy note-block instrument (0..15).
  if instrument_id < 16 then
    return { kind = "play_note", name = PLAY_NOTE_NAMES[instrument_id + 1] }
  end

  -- Vanilla v6 trumpet (16..19) below the boundary: playSound-only.
  return { kind = "play_sound", name = PLAY_SOUND_NAMES[instrument_id] }
end

return instrument_table
