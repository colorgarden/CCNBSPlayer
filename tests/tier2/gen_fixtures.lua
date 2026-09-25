-- tests/tier2/gen_fixtures.lua
--
-- Reproducible generator for the FAILURE / EDGE-CASE fixtures used by the
-- Tier-2 harness (tests/tier2/).  Run once from the project root:
--
--     lua tests/tier2/gen_fixtures.lua
--
-- Every produced file is a plain, WELL-FORMED Note Block Studio .nbs v5 byte
-- stream (a v5 file so both playNote and the v6 playSound path exist in the
-- format, and so the custom-instrument boundary is the real one).  These
-- fixtures exist to exercise player/fanout.lua and player/dispatch.lua at their
-- edges; they are NOT malformed.  (Malformed inputs live in
-- tests/corpus/malformed/ and are produced by a different generator.)
--
-- WHY EACH FIXTURE LOOKS THE WAY IT DOES
--
--   capacity_10.nbs
--     Ten notes all start on NBS tick 0.  At the fixture's tempo
--     (tempo_raw = 1000 -> 10 ticks/second -> tick_ms = 100) tick 0 is one
--     instant, so analyze's peak 50 ms window holds all ten: peak_concurrent
--     = 10, all vanilla instrument 0 (id 0..15).  With MAX_NOTES_PER_TICK = 8,
--     nbs.speakers.required_count = ceil(10 / 8) = 2.  Every key is 45, which
--     maps to playNote pitch 12 (key - 33) -- safely inside the emulator's
--     0..24 acceptance window (docs/COMPAT.md), so the SAME fixture is usable
--     both to show a balanced 2-speaker split (dropped 0) and, with one
--     speaker, the deterministic 2-note drop.
--
--     Ten notes on ONE tick must occupy TEN DISTINCT LAYERS: the NBS note
--     encoding stores a per-note layer delta and a delta of zero terminates
--     the tick, so two notes cannot share a layer.  Hence layer_count = 10 and
--     layer indices 0..9.
--
--   custom_mix.nbs
--     Three notes on three consecutive ticks (so three separate 50 ms windows,
--     peak 1), all instrument 0 or 1 EXCEPT the middle one, which uses
--     instrument id 16 while the header declares vanilla_instrument_count = 16.
--     instrument_table.resolve(16, 16) therefore classifies it as "custom",
--     which player/dispatch.lua refuses with NO speaker call and exactly one
--     WARN[custom-instrument].  The two vanilla notes MUST still play, so the
--     fixture pins both halves of the refusal: the custom note is silent, the
--     surrounding notes are not.
--
-- Cobalt / Lua 5.2 constraints: no `//`, no bitwise operators, no utf8.*, no
-- os.exit / os.execute.  io.open(..., "wb") is the only writer used.

-- ---------------------------------------------------------------------------
-- Output directory: alongside this script, in fixtures/.
-- ---------------------------------------------------------------------------

local script = "tests/tier2/gen_fixtures.lua"
if arg and arg[0] then
  script = arg[0]
end
script = script:gsub("\\", "/")
local here = script:match("^(.*)/gen_fixtures%.lua$") or "tests/tier2"
local OUT_DIR = here .. "/fixtures"

-- ---------------------------------------------------------------------------
-- Byte builders (little-endian, matching nbs/reader.lua)
-- ---------------------------------------------------------------------------

local function s(...)
  return string.char(...)
end

-- i16(n): two little-endian bytes for a value in signed/unsigned range.
local function i16(n)
  if n < 0 then
    n = n + 65536
  end
  return s(n % 256, math.floor(n / 256) % 256)
end

-- i32(n): four little-endian bytes.
local function i32(n)
  if n < 0 then
    n = n + 4294967296
  end
  return s(n % 256,
           math.floor(n / 256) % 256,
           math.floor(n / 65536) % 256,
           math.floor(n / 16777216) % 256)
end

-- lstr(text): i32 byte length followed by the raw bytes.
local function lstr(text)
  return i32(#text) .. text
end

-- ---------------------------------------------------------------------------
-- NBS v5 header (the exact field order nbs/header.lua parses)
-- ---------------------------------------------------------------------------

local function header(opts)
  return table.concat({
    s(0, 0),                          -- new-format sentinel
    s(5),                             -- version 5
    s(opts.vanilla),                  -- vanilla_instrument_count
    i16(opts.song_length),            -- v3+ stored length
    i16(opts.layer_count),            -- layer count
    lstr(opts.name or ""),            -- name
    lstr(""),                         -- author
    lstr(""),                         -- original_author
    lstr(""),                         -- description
    i16(opts.tempo_raw or 1000),      -- tempo (1000 -> 10 ticks/sec)
    s(0),                             -- autosave
    s(10),                            -- autosave_duration
    s(4),                             -- time_signature
    i32(0), i32(0), i32(0), i32(0), i32(0),
    lstr(""),                         -- midi_filename
    s(0),                             -- loop
    s(0),                             -- max_loop_count
    i16(0),                           -- loop_start_tick
  })
end

-- ---------------------------------------------------------------------------
-- NBS v5 sections
-- ---------------------------------------------------------------------------

-- note(instrument, key): a v5 note record (instrument/key/velocity/panning/
-- pitch).  velocity 100 and layer volume 100 give speaker volume 3.
local function note(instrument, key)
  return s(instrument, key, 100, 100) .. i16(0)
end

-- layer(name): a v5 layer record (name + lock + volume + panning).
local function layer(name)
  return lstr(name) .. s(0, 100, 100)
end

-- one note on its own tick/layer: tick delta, layer delta, note, layer end.
local function tick_with_note(tick_delta, instrument, key)
  return i16(tick_delta) .. i16(1) .. note(instrument, key) .. i16(0)
end

-- ---------------------------------------------------------------------------
-- Fixture 1: capacity_10.nbs -- peak 10, requires 2 speakers
-- ---------------------------------------------------------------------------

local function capacity_10()
  local notes = { i16(1) }                    -- one tick jump -> tick 0
  for _ = 0, 9 do
    notes[#notes + 1] = i16(1) .. note(0, 45)
  end
  notes[#notes + 1] = i16(0)                  -- end of layers for tick 0
  notes[#notes + 1] = i16(0)                  -- end of notes

  local layers = {}
  for index = 0, 9 do
    layers[#layers + 1] = layer("L" .. index)
  end

  return header({ vanilla = 16, song_length = 1, layer_count = 10,
                  name = "capacity 10" })
    .. table.concat(notes) .. table.concat(layers)
end

-- ---------------------------------------------------------------------------
-- Fixture 2: custom_mix.nbs -- vanilla, custom, vanilla on three ticks
-- ---------------------------------------------------------------------------

local function custom_mix()
  local notes = {
    tick_with_note(1, 0, 45),   -- tick 0, instrument 0 (harp)
    tick_with_note(1, 16, 45),  -- tick 1, instrument 16 (>= vanilla -> custom)
    tick_with_note(1, 1, 45),   -- tick 2, instrument 1 (bass)
    i16(0),                     -- end of notes
  }
  return header({ vanilla = 16, song_length = 3, layer_count = 1,
                  name = "custom mix" })
    .. table.concat(notes) .. layer("L0")
end

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

local written = 0

local function write_file(name, bytes)
  local path = OUT_DIR .. "/" .. name
  local handle, open_error = io.open(path, "wb")
  if not handle then
    error("cannot open " .. path .. " for writing: " .. tostring(open_error), 0)
  end
  handle:write(bytes)
  handle:close()
  written = written + 1
  io.write(string.format("%-22s %5d bytes\n", name, #bytes))
end

write_file("capacity_10.nbs", capacity_10())
write_file("custom_mix.nbs", custom_mix())

io.write(string.format("generated %d tier2 fixture(s) in %s\n", written, OUT_DIR))
