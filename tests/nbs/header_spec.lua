-- tests/nbs/header_spec.lua
--
-- Tier-1 spec for nbs/header.lua -- the .nbs header parser for the legacy v0
-- layout and the Open Note Block Studio layouts v1..v6.
--
-- FROZEN CONTRACT UNDER TEST
-- --------------------------
--   local header = require("nbs.header")
--   header.parse(reader) -> header_table
--
--   header_table fields (exact names):
--     version                  integer 0..6 (0 == legacy)
--     vanilla_instrument_count integer (index at which custom instruments start)
--     song_length              integer, or nil for v1/v2
--     layer_count              integer
--     name, author, original_author, description   strings, BYTE-EXACT
--     midi_filename            string (may be "")
--     tempo_raw                integer (raw signed i16)
--     tempo_ticks_per_second   number = tempo_raw / 100
--     autosave                 integer
--     autosave_duration        integer
--     time_signature           integer
--     minutes_spent, left_clicks, right_clicks, blocks_added, blocks_removed
--     loop                     integer 0/1, or nil when version < 4
--     max_loop_count           integer, or nil when version < 4
--     loop_start_tick          integer, or nil when version < 4
--     format                   "legacy" for v0, "new" otherwise
--
-- FORMAT DETECTION: read the FIRST i16.  If it is 0 the stream is NEW format
-- and the next byte is the version.  Otherwise it is LEGACY v0 and that i16 is
-- the song length (there is no version byte and no vanilla-instrument byte).
--
-- FIXTURE LAYOUT (built in code, no external files)
-- -------------------------------------------------
-- Helpers below build the byte strings.  `s(...)` = string.char(...);
-- `i16(n)` / `i32(n)` emit LITTLE-ENDIAN two's-complement for a value in range;
-- `lstr(text)` = i32 byte length followed by the RAW bytes.
--
-- NEW-format stream (v1..v6), exactly the field order the parser must consume:
--   i16 0                              -- format marker
--   u8  version
--   u8  vanilla_instrument_count
--   i16 song_length                    -- only when version >= 3
--   i16 layer_count
--   str name, str author, str original_author, str description
--   i16 tempo_raw
--   u8  autosave, u8 autosave_duration, u8 time_signature
--   i32 minutes_spent, i32 left_clicks, i32 right_clicks,
--   i32 blocks_added, i32 blocks_removed
--   str midi_filename
--   u8  loop, u8 max_loop_count, i16 loop_start_tick   -- only when version >= 4
--
-- Example: a v5 header named "T", 1 layer, 10 tps begins
--   s(0,0, 5,16, 5,0, 1,0) then lstr("T") ...
-- (i16 0; version 5; vanilla 16; song_length 5; layer_count 1; then the name).
--
-- LEGACY v0 stream, exactly the field order the parser must consume:
--   i16 song_length       -- the first i16 (NON-ZERO; also the format marker)
--   i16 layer_count
--   str name, str author, str original_author, str description
--   i16 tempo_raw
--   u8  autosave, u8 autosave_duration, u8 time_signature
--   i32 minutes_spent, i32 left_clicks, i32 right_clicks,
--   i32 blocks_added, i32 blocks_removed
--   str midi_filename
--   (no loop fields -> loop/max_loop_count/loop_start_tick are nil)
--
-- SIGNED-INT16 WRAPAROUND -- SEE test 10
-- --------------------------------------
-- The task brief quotes a reconstruction rule with the literal constant -32768
-- and states that raw 0xFFFF (-1) becomes 65537.  Those two claims cannot both
-- be true, and neither matches the cited reference.  The reference parser
-- OpenNBS/nbs.js defines BufferWrapper.MIN_SHORT = -32767 and MAX_SHORT = 32767
-- (src/buffer/wrapper.ts) and reconstructs as:
--
--     difference = -1 * (MIN_SHORT - size) + 2
--     size       = MAX_SHORT + difference
--
-- which is algebraically the UNSIGNED reinterpretation, size + 65536, i.e. the
-- "intended unsigned value" the brief describes: 0x8000 -> 32768, 0xFFFF ->
-- 65535.  The brief's own first expectation (32768) agrees with this; its
-- second expectation (65537) does not (and would require a different offset
-- than the first, which no single linear rule can produce).  This spec therefore
-- locks the reference behaviour: 32768 and 65535.  See the evidence file
-- .omo/evidence/task-7-ccnbsplayer.txt for the full derivation.
--
-- Typed errors: overruns propagate from nbs.reader as a table with
-- .code == "E_TRUNCATED"; an out-of-range version raises a table with
-- .code == "E_UNSUPPORTED_VERSION".  We inspect the raised tables directly with
-- pcall (as reader_spec.lua does), because expect.raises() only sees the
-- flattened string form.

local reader = require("nbs.reader")
local header = require("nbs.header")

-- ---------------------------------------------------------------------------
-- Fixture builders
-- ---------------------------------------------------------------------------

-- s(...) -> string: the given byte values as a Lua byte string.
local function s(...)
  return string.char(...)
end

-- i16(n) -> two little-endian bytes for a value in -32768..65535.
local function i16(n)
  if n < 0 then
    n = n + 65536
  end
  return s(n % 256, math.floor(n / 256) % 256)
end

-- i32(n) -> four little-endian bytes for a non-negative value.
local function i32(n)
  if n < 0 then
    n = n + 4294967296
  end
  return s(n % 256,
           math.floor(n / 256) % 256,
           math.floor(n / 65536) % 256,
           math.floor(n / 16777216) % 256)
end

-- lstr(text) -> i32 length prefix followed by the RAW bytes of text.
local function lstr(text)
  return i32(#text) .. text
end

-- new_header(opts) -> a complete NEW-format header byte string.
-- Version is mandatory; every other field has a harmless default.  `*_bytes`
-- options let a test inject raw bytes (used by the wraparound cases).
local function new_header(opts)
  opts = opts or {}
  local version = opts.version
  local parts = {
    s(0, 0),                             -- format marker: first i16 == 0
    s(version),                          -- u8 version
    s(opts.vanilla_instrument_count or 16), -- u8 vanilla instrument count
  }
  if version >= 3 then
    parts[#parts + 1] = opts.song_length_bytes or i16(opts.song_length or 0)
  end
  parts[#parts + 1] = i16(opts.layer_count or 1)
  parts[#parts + 1] = lstr(opts.name or "")
  parts[#parts + 1] = lstr(opts.author or "")
  parts[#parts + 1] = lstr(opts.original_author or "")
  parts[#parts + 1] = lstr(opts.description or "")
  parts[#parts + 1] = opts.tempo_bytes or i16(opts.tempo_raw or 1000)
  parts[#parts + 1] = s(opts.autosave or 0)
  parts[#parts + 1] = s(opts.autosave_duration or 10)
  parts[#parts + 1] = s(opts.time_signature or 4)
  parts[#parts + 1] = i32(opts.minutes_spent or 0)
  parts[#parts + 1] = i32(opts.left_clicks or 0)
  parts[#parts + 1] = i32(opts.right_clicks or 0)
  parts[#parts + 1] = i32(opts.blocks_added or 0)
  parts[#parts + 1] = i32(opts.blocks_removed or 0)
  parts[#parts + 1] = lstr(opts.midi_filename or "")
  if version >= 4 then
    parts[#parts + 1] = s(opts.loop or 0)
    parts[#parts + 1] = s(opts.max_loop_count or 0)
    parts[#parts + 1] = opts.loop_start_bytes or i16(opts.loop_start_tick or 0)
  end
  return table.concat(parts)
end

-- legacy_header(opts) -> a complete LEGACY v0 header byte string.
local function legacy_header(opts)
  opts = opts or {}
  local parts = {
    opts.song_length_bytes or i16(opts.song_length or 0), -- first i16 (non-zero)
    i16(opts.layer_count or 1),
    lstr(opts.name or ""),
    lstr(opts.author or ""),
    lstr(opts.original_author or ""),
    lstr(opts.description or ""),
    opts.tempo_bytes or i16(opts.tempo_raw or 1000),
    s(opts.autosave or 0),
    s(opts.autosave_duration or 10),
    s(opts.time_signature or 4),
    i32(opts.minutes_spent or 0),
    i32(opts.left_clicks or 0),
    i32(opts.right_clicks or 0),
    i32(opts.blocks_added or 0),
    i32(opts.blocks_removed or 0),
    lstr(opts.midi_filename or ""),
  }
  return table.concat(parts)
end

local function parse(bytes)
  return header.parse(reader.new(bytes))
end

-- pcall wrapper: asserts the call raised, that the raised value is a TABLE and
-- returns it so the caller can inspect `.code`.
local function capture(fn)
  local ok, err = pcall(fn)
  expect.falsy(ok)
  expect.equal(type(err), "table")
  return err
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("nbs.header format detection", function()
  it("1. NEW format: leading i16 0 then version byte 5", function()
    local h = parse(new_header({ version = 5 }))
    expect.equal(h.version, 5)
    expect.equal(h.format, "new")
  end)

  it("2. LEGACY format: a non-zero leading i16 is the song length", function()
    -- \200\1 is little-endian 456; the following i16 is layer_count.
    local h = parse(legacy_header({ song_length = 456, layer_count = 3 }))
    expect.equal(h.version, 0)
    expect.equal(h.format, "legacy")
    expect.equal(h.song_length, 456)
    expect.equal(h.vanilla_instrument_count, 10)
    expect.equal(h.layer_count, 3)
  end)
end)

describe("nbs.header song_length presence rules", function()
  it("3. v3 stores song_length", function()
    local h = parse(new_header({ version = 3, song_length = 3000 }))
    expect.equal(h.song_length, 3000)
  end)

  it("4. v1 has NO stored song_length (nil) and layer_count stays correct", function()
    -- If the parser wrongly consumed two bytes for a length, layer_count would
    -- be garbage.  It must read the layer_count i16 straight after the version.
    local h = parse(new_header({ version = 1, layer_count = 7 }))
    expect.equal(h.song_length, nil)
    expect.equal(h.layer_count, 7)
  end)

  it("5. v2 has NO stored song_length (nil)", function()
    local h = parse(new_header({ version = 2, layer_count = 5 }))
    expect.equal(h.song_length, nil)
    expect.equal(h.layer_count, 5)
  end)
end)

describe("nbs.header loop fields", function()
  it("6. loop fields absent below v4", function()
    local h = parse(new_header({ version = 3 }))
    expect.equal(h.loop, nil)
    expect.equal(h.max_loop_count, nil)
    expect.equal(h.loop_start_tick, nil)
  end)

  it("7. loop fields present at v4", function()
    local h = parse(new_header({
      version = 4,
      loop = 1,
      max_loop_count = 3,
      loop_start_tick = 64,
    }))
    expect.equal(h.loop, 1)
    expect.equal(h.max_loop_count, 3)
    expect.equal(h.loop_start_tick, 64)
  end)
end)

describe("nbs.header scalar fields", function()
  it("8. tempo maths: tempo_raw / 100", function()
    local a = parse(new_header({ version = 5, tempo_raw = 1000 }))
    expect.equal(a.tempo_raw, 1000)
    expect.equal(a.tempo_ticks_per_second, 10)

    local b = parse(new_header({ version = 5, tempo_raw = 1500 }))
    expect.equal(b.tempo_raw, 1500)
    expect.equal(b.tempo_ticks_per_second, 15)
  end)

  it("9. strings are byte-exact and an empty description is \"\"", function()
    local name = s(128, 147, 255)
    local h = parse(new_header({ version = 5, name = name, description = "" }))

    expect.equal(h.name, name)
    expect.equal(#h.name, 3)
    expect.equal(string.byte(h.name, 1), 128)
    expect.equal(string.byte(h.name, 2), 147)
    expect.equal(string.byte(h.name, 3), 255)
    expect.equal(h.description, "")
  end)

  it("10. signed i16 wraparound reconstructs the unsigned tick count", function()
    -- See the file header.  The mandated rule, with the reference parser's
    -- actual constants (MIN_SHORT = -32767, MAX_SHORT = 32767), is the unsigned
    -- reinterpretation: 0x8000 -> 32768, 0xFFFF -> 65535.  (The brief's stated
    -- 65537 is not reachable by any single linear rule and contradicts its own
    -- "intended unsigned value" description; documented in the evidence file.)

    -- 0x8000 read as i16 is -32768.
    local legacy_neg_max = parse(legacy_header({ song_length_bytes = s(0, 128) }))
    expect.equal(legacy_neg_max.song_length, 32768)

    -- 0xFFFF read as i16 is -1.
    local legacy_neg_one = parse(legacy_header({ song_length_bytes = s(255, 255) }))
    expect.equal(legacy_neg_one.song_length, 65535)

    -- The same reconstruction must apply on the new-format v3+ path.
    local new_neg_max = parse(new_header({ version = 3, song_length_bytes = s(0, 128) }))
    expect.equal(new_neg_max.song_length, 32768)

    local new_neg_one = parse(new_header({ version = 3, song_length_bytes = s(255, 255) }))
    expect.equal(new_neg_one.song_length, 65535)
  end)

  it("11. all five i32 statistics counters read correctly", function()
    local h = parse(new_header({
      version = 5,
      minutes_spent = 5,
      left_clicks = 186,
      right_clicks = 3,
      blocks_added = 26,
      blocks_removed = 0,
    }))
    expect.equal(h.minutes_spent, 5)
    expect.equal(h.left_clicks, 186)
    expect.equal(h.right_clicks, 3)
    expect.equal(h.blocks_added, 26)
    expect.equal(h.blocks_removed, 0)
  end)
end)

describe("nbs.header versions and errors", function()
  it("12. unsupported version byte raises E_UNSUPPORTED_VERSION", function()
    local err = capture(function()
      return header.parse(reader.new(s(0, 0, 9, 16)))
    end)
    expect.equal(err.code, "E_UNSUPPORTED_VERSION")
    expect.equal(err.version, 9)
  end)

  it("13. a header that ends mid-stream raises E_TRUNCATED", function()
    -- i16 0; version 5; vanilla 16; then the stream ends just before the
    -- v3+ song_length i16 can be read.
    local err = capture(function()
      return header.parse(reader.new(s(0, 0, 5, 16)))
    end)
    expect.equal(err.code, "E_TRUNCATED")
  end)

  it("14. v6 parses and returns its stored vanilla_instrument_count verbatim", function()
    local a = parse(new_header({ version = 6, vanilla_instrument_count = 20 }))
    expect.equal(a.version, 6)
    expect.equal(a.vanilla_instrument_count, 20)

    -- A second, different value proves the byte is read, not hardcoded.
    local b = parse(new_header({ version = 6, vanilla_instrument_count = 23 }))
    expect.equal(b.version, 6)
    expect.equal(b.vanilla_instrument_count, 23)
  end)
end)

describe("nbs.header legacy v0 end-to-end", function()
  it("15. a full well-formed v0 stream parses every field", function()
    local h = parse(legacy_header({
      song_length = 456,
      layer_count = 4,
      name = "Legacy",
      author = "Author",
      original_author = "Orig",
      description = "Desc",
      tempo_raw = 1000,
      autosave = 1,
      autosave_duration = 30,
      time_signature = 3,
      minutes_spent = 5,
      left_clicks = 186,
      right_clicks = 3,
      blocks_added = 26,
      blocks_removed = 1,
      midi_filename = "song.mid",
    }))

    expect.equal(h.version, 0)
    expect.equal(h.format, "legacy")
    expect.equal(h.vanilla_instrument_count, 10)
    expect.equal(h.song_length, 456)
    expect.equal(h.layer_count, 4)
    expect.equal(h.name, "Legacy")
    expect.equal(h.author, "Author")
    expect.equal(h.original_author, "Orig")
    expect.equal(h.description, "Desc")
    expect.equal(h.tempo_raw, 1000)
    expect.equal(h.tempo_ticks_per_second, 10)
    expect.equal(h.autosave, 1)
    expect.equal(h.autosave_duration, 30)
    expect.equal(h.time_signature, 3)
    expect.equal(h.minutes_spent, 5)
    expect.equal(h.left_clicks, 186)
    expect.equal(h.right_clicks, 3)
    expect.equal(h.blocks_added, 26)
    expect.equal(h.blocks_removed, 1)
    expect.equal(h.midi_filename, "song.mid")

    -- Legacy has no loop metadata at all.
    expect.equal(h.loop, nil)
    expect.equal(h.max_loop_count, nil)
    expect.equal(h.loop_start_tick, nil)
  end)
end)

describe("nbs.header layer_count signed-wrap guard", function()
  -- REGRESSION (silent-success defect).  layer_count is SPEC-FAITHFULLY a
  -- signed i16, so a raw count >= 32768 wraps negative.  Before the fix the
  -- negative count was accepted here and then flowed into layers.parse, whose
  -- `layer_count > remaining` guard is false for a negative number, so its loop
  -- ran ZERO times and decode() reported success on a corrupt file.  A negative
  -- count is impossible for a real file, so the header must reject it at the
  -- point of read with the SAME code layers.parse already uses.
  --
  -- Why 30000 (the existing absurd_layer_count.nbs) does NOT catch this: 30000
  -- is still positive (< 32768) and is rejected downstream by layers.parse's
  -- byte-budget guard.  The wrap only occurs at >= 32768; these cases pin the
  -- signed boundary specifically.

  it("16. a raw layer_count of 60000 (wraps to -5536) raises E_BAD_LAYER_COUNT", function()
    local err = capture(function()
      return parse(new_header({ version = 5, layer_count = 60000 }))
    end)
    expect.equal(err.code, "E_BAD_LAYER_COUNT")
    expect.equal(err.layer_count, -5536)
    expect.equal(err.version, 5)
    expect.truthy(type(err.msg) == "string" and #err.msg > 0)
  end)

  it("17. a raw layer_count of 65535 (wraps to -1) raises E_BAD_LAYER_COUNT", function()
    local err = capture(function()
      return parse(new_header({ version = 5, layer_count = 65535 }))
    end)
    expect.equal(err.code, "E_BAD_LAYER_COUNT")
    expect.equal(err.layer_count, -1)
    expect.equal(err.version, 5)
    expect.truthy(type(err.msg) == "string" and #err.msg > 0)
  end)

  it("18. POSITIVE CONTROL: a raw layer_count of 200 still parses to 200", function()
    -- The practical maximum (the format docs warn above 200).  The signed-wrap
    -- guard must never reject a legitimate count.
    local h = parse(new_header({ version = 5, layer_count = 200 }))
    expect.equal(h.layer_count, 200)
  end)

  it("19. the guard also applies on the LEGACY v0 path", function()
    local err = capture(function()
      return parse(legacy_header({ song_length = 10, layer_count = 65535 }))
    end)
    expect.equal(err.code, "E_BAD_LAYER_COUNT")
    expect.equal(err.layer_count, -1)
    expect.equal(err.version, 0)
  end)
end)

describe("nbs.header tempo guard (zero/negative tempo is corrupt)", function()
  -- B4 REGRESSION.  tempo_ticks_per_second = tempo_raw / 100 and the tempo
  -- scheduler divides by it (tick_ms = 1000 / tps).  A stored tempo of 0 makes
  -- tick_ms INFINITE, so the first event's t_ms = tick * tick_ms is NaN for
  -- tick 0; the clock is then asked for a NaN deadline, which can never be
  -- satisfied, and the session never ends.  A tempo <= 0 is impossible for a
  -- real song: it is corrupt input, not a slow song, so the parser rejects it
  -- at the point of read with a typed table error (the other header errors'
  -- convention).
  --
  -- tempo_raw is spec-faithfully a SIGNED i16, so a negative value IS
  -- representable on disk (raw 0xFF9C reads as -100).  The bound must hold on
  -- both the new-format and the legacy v0 path.

  it("20. tempo_raw 0 raises E_BAD_TEMPO with the offending value", function()
    local err = capture(function()
      return parse(new_header({ version = 5, tempo_raw = 0 }))
    end)
    expect.equal(err.code, "E_BAD_TEMPO")
    expect.equal(err.tempo_raw, 0)
    expect.equal(err.version, 5)
    expect.truthy(type(err.msg) == "string" and #err.msg > 0)
    io.write("    TEMPO-GUARD zero code=" .. err.code
      .. " tempo_raw=" .. tostring(err.tempo_raw) .. "\n")
  end)

  it("21. tempo_raw -100 (negative i16) raises E_BAD_TEMPO", function()
    local err = capture(function()
      return parse(new_header({ version = 5, tempo_raw = -100 }))
    end)
    expect.equal(err.code, "E_BAD_TEMPO")
    expect.equal(err.tempo_raw, -100)
    expect.equal(err.version, 5)
    io.write("    TEMPO-GUARD negative code=" .. err.code
      .. " tempo_raw=" .. tostring(err.tempo_raw) .. "\n")
  end)

  it("22. the guard also applies on the LEGACY v0 path", function()
    local err = capture(function()
      return parse(legacy_header({ song_length = 10, tempo_raw = 0 }))
    end)
    expect.equal(err.code, "E_BAD_TEMPO")
    expect.equal(err.tempo_raw, 0)
    expect.equal(err.version, 0)
  end)

  it("23. POSITIVE CONTROL: a normal tempo_raw still parses", function()
    -- The guard must never reject a legitimate tempo.
    local h = parse(new_header({ version = 5, tempo_raw = 1000 }))
    expect.equal(h.tempo_raw, 1000)
    expect.equal(h.tempo_ticks_per_second, 10)
  end)
end)
