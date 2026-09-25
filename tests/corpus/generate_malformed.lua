-- tests/corpus/generate_malformed.lua
--
-- Reproducible generator for the MALFORMED .nbs corpus in
-- tests/corpus/malformed/.  Run once from the project root:
--
--     lua tests/corpus/generate_malformed.lua
--
-- Every produced file is a real on-disk .nbs byte stream designed to make
-- nbs.decode.decode() return ok == false (or, for cyclic_jumps.nbs, to be
-- capped by a parser iteration ceiling) WITHOUT raising or hanging.  The spec
-- tests/nbs/decode_spec.lua iterates the directory and asserts each file.
--
-- DESIGN NOTE -- the layer_count field is a SIGNED i16 (nbs/header.lua uses
-- r:i16()), so the "absurd count" family has two distinct shapes:
--   * absurd_layer_count.nbs claims 30000 -- POSITIVE and below the signed
--     ceiling 32767, so it is rejected downstream by layers.parse's byte-budget
--     guard (E_BAD_LAYER_COUNT).  The raw bytes 0x30 0x75 are 30000.
--   * negative_layer_count.nbs (raw 60000 -> -5536) and
--     max_unsigned_layer_count.nbs (raw 65535 -> -1) WRAP NEGATIVE.  A negative
--     count used to slip through layers.parse -- whose `count > remaining`
--     guard is false for a negative number -- so its loop ran ZERO times and
--     decode reported ok == true on a corrupt file (a silent success).
--     nbs/header.lua now rejects any negative layer_count at the point of read
--     with E_BAD_LAYER_COUNT, so both files are rejected there.
-- Both shapes must exist: 30000 alone can never exercise the signed wrap, which
-- only occurs at raw >= 32768.
--
-- Cobalt / Lua 5.2 constraints: no `//`, no bitwise operators, no utf8.*, no
-- os.exit / os.execute.  io.open(..., "wb") is the only writer used.

-- ---------------------------------------------------------------------------
-- Output directory: alongside this script, in malformed/.
-- ---------------------------------------------------------------------------

local script = "tests/corpus/generate_malformed.lua"
if arg and arg[0] then
  script = arg[0]
end
script = script:gsub("\\", "/")
local here = script:match("^(.*)/generate_malformed%.lua$") or "tests/corpus"
local OUT_DIR = here .. "/malformed"

-- ---------------------------------------------------------------------------
-- Byte builders (mirror the fixtures used across the spec suite)
-- ---------------------------------------------------------------------------

local function s(...)
  return string.char(...)
end

-- i16(n): two little-endian bytes for a signed/unsigned value in range.
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

-- new_header(opts): a complete NEW-format (v1..v6) header.
local function new_header(opts)
  opts = opts or {}
  local version = opts.version
  local parts = {
    s(0, 0),
    s(version),
    s(opts.vanilla or 16),
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
  parts[#parts + 1] = i32(0)
  parts[#parts + 1] = i32(0)
  parts[#parts + 1] = i32(0)
  parts[#parts + 1] = i32(0)
  parts[#parts + 1] = i32(0)
  parts[#parts + 1] = lstr(opts.midi or "")
  if version >= 4 then
    parts[#parts + 1] = s(opts.loop or 0)
    parts[#parts + 1] = s(opts.max_loop or 0)
    parts[#parts + 1] = i16(opts.loop_start or 0)
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

local written = 0

local function write_file(name, bytes, expected_code, note)
  local path = OUT_DIR .. "/" .. name
  local handle, open_error = io.open(path, "wb")
  if not handle then
    error("cannot open " .. path .. " for writing: " .. tostring(open_error), 0)
  end
  handle:write(bytes)
  handle:close()
  written = written + 1
  io.write(string.format("%-26s %7d bytes  -> %-24s %s\n",
    name, #bytes, expected_code, note or ""))
end

-- ---------------------------------------------------------------------------
-- 1. empty.nbs -- 0 bytes.
-- ---------------------------------------------------------------------------
write_file("empty.nbs", "", "E_TRUNCATED", "0 bytes")

-- ---------------------------------------------------------------------------
-- 2. one_byte.nbs -- shorter than any header.
-- ---------------------------------------------------------------------------
write_file("one_byte.nbs", s(0), "E_TRUNCATED", "1 byte")

-- ---------------------------------------------------------------------------
-- 3. truncated_header.nbs -- valid v5 prefix cut off mid-string.
--    name declares 200 bytes; only 45 follow.
-- ---------------------------------------------------------------------------
write_file("truncated_header.nbs",
  s(0, 0, 5, 16) .. i16(100) .. i16(1) .. i32(200) .. string.rep("A", 45),
  "E_TRUNCATED", "name length 200, 45 bytes present")

-- ---------------------------------------------------------------------------
-- 4. version_9.nbs -- first i16 0, version byte 9.  Padded past the minimum
--    header size so the parser itself (not the byte-budget pre-check) sees it.
-- ---------------------------------------------------------------------------
write_file("version_9.nbs",
  s(0, 0, 9, 16) .. string.rep(s(0), 52),
  "E_UNSUPPORTED_VERSION", "version 9")

-- ---------------------------------------------------------------------------
-- 5. negative_tick_jump.nbs -- first note jump is -1.
-- ---------------------------------------------------------------------------
write_file("negative_tick_jump.nbs",
  new_header({ version = 5, layer_count = 1, song_length = 10 })
    .. i16(-1) .. string.rep(s(0), 20),
  "E_BAD_JUMP", "first tick jump -1")

-- ---------------------------------------------------------------------------
-- 6. layer_overflow.nbs -- layer jump 202 pushes index to 201 (> 200).
-- ---------------------------------------------------------------------------
write_file("layer_overflow.nbs",
  new_header({ version = 5, layer_count = 1, song_length = 10 })
    .. i16(1) .. i16(202) .. string.rep(s(0), 20),
  "E_LAYER_OVERFLOW", "layer index 201")

-- ---------------------------------------------------------------------------
-- 7. absurd_layer_count.nbs -- 30000 layers over a 1-byte buffer.
--    (See the design note above re: 60000 vs 30000.)
-- ---------------------------------------------------------------------------
write_file("absurd_layer_count.nbs",
  new_header({ version = 5, layer_count = 30000, song_length = 10 })
    .. i16(0) .. s(0),
  "E_BAD_LAYER_COUNT", "30000 layers, 1 byte left")

-- ---------------------------------------------------------------------------
-- 7b. negative_layer_count.nbs -- raw layer_count 60000 wraps to -5536 as a
--     SIGNED i16.  Rejected at header.parse with E_BAD_LAYER_COUNT (see the
--     design note).  The raw bytes 0x60 0xEA are 60000.
-- ---------------------------------------------------------------------------
write_file("negative_layer_count.nbs",
  new_header({ version = 5, layer_count = 60000, song_length = 10 })
    .. i16(0),
  "E_BAD_LAYER_COUNT", "raw 60000 -> -5536 signed wrap")

-- ---------------------------------------------------------------------------
-- 7c. max_unsigned_layer_count.nbs -- raw layer_count 65535 wraps to -1 as a
--     SIGNED i16.  Rejected at header.parse with E_BAD_LAYER_COUNT.  The raw
--     bytes 0xFF 0xFF are 65535.
-- ---------------------------------------------------------------------------
write_file("max_unsigned_layer_count.nbs",
  new_header({ version = 5, layer_count = 65535, song_length = 10 })
    .. i16(0),
  "E_BAD_LAYER_COUNT", "raw 65535 -> -1 signed wrap")

-- ---------------------------------------------------------------------------
-- 8. absurd_instrument_count.nbs -- v5 custom-instrument count 241 (cap 240).
-- ---------------------------------------------------------------------------
write_file("absurd_instrument_count.nbs",
  new_header({ version = 5, layer_count = 0, song_length = 10 })
    .. i16(0) .. s(241),
  "E_BAD_INSTRUMENT_COUNT", "count 241 > cap 240")

-- ---------------------------------------------------------------------------
-- 9. truncated_notes.nbs -- ends after the instrument byte, mid-note.
-- ---------------------------------------------------------------------------
write_file("truncated_notes.nbs",
  new_header({ version = 5, layer_count = 1, song_length = 10 })
    .. i16(1) .. i16(1) .. s(1),
  "E_TRUNCATED", "ends before key byte")

-- ---------------------------------------------------------------------------
-- 10. cyclic_jumps.nbs -- a long run of small positive tick jumps (1) with no
--     terminating zero.  The tick climbs past the parser's MAX_TICK ceiling
--     (32000) and is rejected with E_TOO_MANY_TICKS within the time bound.
--     32010 iterations * (i16 jump + i16 layer terminator) = 128040 bytes;
--     tick reaches 32001 on iteration 32002.
-- ---------------------------------------------------------------------------
write_file("cyclic_jumps.nbs",
  new_header({ version = 5, layer_count = 0, song_length = 10 })
    .. string.rep(i16(1) .. i16(0), 32010),
  "E_TOO_MANY_TICKS", "32010 positive jumps, no zero")

-- ---------------------------------------------------------------------------
-- 11. truncated_layers.nbs -- layer name declares 50 bytes, 10 present.
-- ---------------------------------------------------------------------------
write_file("truncated_layers.nbs",
  new_header({ version = 5, layer_count = 1, song_length = 10 })
    .. i16(0) .. i32(50) .. string.rep("L", 10),
  "E_TRUNCATED", "layer name 50 claimed, 10 present")

-- ---------------------------------------------------------------------------
-- 12. huge_declared_string.nbs -- name length prefix ~2^31, tiny buffer.
-- ---------------------------------------------------------------------------
write_file("huge_declared_string.nbs",
  s(0, 0, 5, 16) .. i16(100) .. i16(1)
    .. i32(2147483647) .. string.rep("A", 40),
  "E_TRUNCATED", "name length 2^31-1, 40 present")

-- ---------------------------------------------------------------------------
-- 13. tempo_zero.nbs / tempo_negative.nbs -- STRUCTURALLY VALID v5 files whose
--     stored tempo is 0 / negative.
--
--     Everything after the header is well-formed (one note at tick 1 and one
--     layer record), so before the guard these files decoded as SUCCESS.  The
--     stored tempo is then divided downstream (tick_ms = 1000 / tps): 0 makes
--     tick_ms infinite, the first event's t_ms = tick * tick_ms is NaN for
--     tick 0, and the scheduler queues a deadline the clock can never satisfy
--     -- the session never ends.  nbs/header.lua now rejects any tempo_raw <= 0
--     with E_BAD_TEMPO at the point of read.
--
--     tempo_raw is a SIGNED i16 on disk, so a negative value IS representable
--     (0xFF9C reads as -100) and gets its own file.  The zero file is the exact
--     B4 reproduction: a structurally valid song that must be rejected as
--     malformed rather than played.
-- ---------------------------------------------------------------------------

-- A well-formed v5 note record (nbs/notes.lua field order).
local function note_v5(tick_jump, layer_jump, instrument, key)
  return i16(tick_jump) .. i16(layer_jump) .. s(instrument) .. s(key)
    .. s(100) .. s(100) .. i16(0) .. i16(0)
end

-- A well-formed v5 layer record: name, lock, volume, panning.
local function layer_v5(name, lock, volume, panning)
  return lstr(name) .. s(lock) .. s(volume) .. s(panning)
end

local function tempo_corrupt_file(tempo_raw)
  return new_header({ version = 5, layer_count = 1, song_length = 10,
                      tempo_raw = tempo_raw })
    .. note_v5(1, 1, 1, 45)
    .. i16(0) -- notes-section terminator
    .. layer_v5("L0", 0, 80, 100)
end

write_file("tempo_zero.nbs", tempo_corrupt_file(0), "E_BAD_TEMPO",
  "structurally valid v5, stored tempo 0")
write_file("tempo_negative.nbs", tempo_corrupt_file(-100), "E_BAD_TEMPO",
  "stored tempo -100 (negative i16 IS representable)")

io.write(string.format("generated %d malformed corpus file(s) in %s\n",
  written, OUT_DIR))
