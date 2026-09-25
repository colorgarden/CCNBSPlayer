-- nbs/instruments_custom.lua
--
-- Parser for the OPTIONAL custom-instruments section of a Note Block Studio
-- (.nbs) file.  This section sits after the layers section; the caller is
-- responsible for positioning the cursor (nbs/reader.lua) at its first byte.
--
-- WIRE LAYOUT
--   u8 count
--   then `count` times:
--     str name        (i32 little-endian length, then that many RAW bytes)
--     str sound_file  (i32 little-endian length, then that many RAW bytes)
--     u8  key
--     u8  press_key
--   Every record therefore costs at least 4 + 4 + 1 + 1 = 10 bytes.
--
-- RETURN SHAPE
--   An ARRAY of records, each with EXACTLY these keys:
--     name        string, byte-exact
--     sound_file  string, byte-exact (path relative to the NBS /Sounds folder)
--     key         integer, verbatim (0..87 expected; 45 is the format's
--                 documented "unset" default and is NOT substituted here)
--     press_key   integer, verbatim (0 or 1)
--
-- OPTIONAL SECTION
--   If the cursor is already exhausted (r:eof()), the section is absent and
--   parse() returns an empty array WITHOUT raising.
--
-- COUNT CAP (version-dependent)
--   `count` is read as an UNSIGNED byte, but the true maximum is 240, never
--   255, because 16 vanilla instruments plus the custom ids must still fit in
--   a byte.  The documented per-version caps are:
--     version 0      -> 9
--     versions 1..4  -> 18
--     versions 5..6  -> 240
--   A count above the cap raises the typed table
--     { code = "E_BAD_INSTRUMENT_COUNT", msg, count, cap, version }
--   via error(table, 0), BEFORE any array is allocated.  Unknown/higher
--   versions reuse the 240 cap.
--
-- BUFFER PRE-FLIGHT
--   Even a legal count can be impossible for the remaining buffer.  Since each
--   record needs at least 10 bytes, a count with count * 10 > r:remaining() is
--   rejected immediately with the same E_BAD_INSTRUMENT_COUNT table -- this is
--   a strictly better diagnostic than looping into a truncated read, which
--   would surface as a generic E_TRUNCATED.
--
-- BYTE-EXACTNESS
--   sound_file is an OPAQUE PATH.  It is read with reader's byte-exact
--   read_string() and stored untouched: no UTF-8 decoding, no CP1252 -> UTF-8
--   display mapping (nbs/cp1252.lua is display-only and MUST NOT be applied
--   here), no slash splitting/normalising, no extension stripping, and no
--   validation against any Minecraft sound registry.  The consumer refuses
--   custom instruments at playback time, but the stored path must still be
--   printable faithfully in diagnostics.
--
-- TARGET INTERPRETER
--   Stock Lua 5.2 / CC:Tweaked Cobalt: no utf8.*, no bitwise operators, no
--   integer division, no os.exit.

local instruments_custom = {}

-- Minimum wire size of one record: two i32 length prefixes + two bytes.
local MIN_RECORD_BYTES = 10

-- Version-dependent count cap (see the module header).
local function cap_for(version)
  if version <= 0 then
    return 9
  elseif version <= 4 then
    return 18
  end
  return 240
end

-- Raise the typed count error.  `context` distinguishes the two guarded cases
-- (above-cap vs. buffer-too-small) in the human-readable `msg` only; `.code`,
-- `.count`, `.cap` and `.version` are identical so callers branch on one code.
local function raise_bad_count(count, cap, version, context)
  error({
    code = "E_BAD_INSTRUMENT_COUNT",
    msg = string.format(
      "bad custom-instrument count: count=%d cap=%d version=%d (%s)",
      count, cap, version, context),
    count = count,
    cap = cap,
    version = version,
  }, 0)
end

-- parse(r, version) -> array of custom instrument records.
--
-- `r` is a nbs.reader cursor positioned at the section's first byte, `version`
-- is the song format version (0..6).  Returns an empty array when the section
-- is absent.  Raises a typed table on an impossible count and propagates the
-- reader's typed E_TRUNCATED on a genuinely truncated stream.
function instruments_custom.parse(r, version)
  -- Optional section: an exhausted cursor means "no custom instruments".
  if r:eof() then
    return {}
  end

  version = version or 0
  local cap = cap_for(version)

  -- `count` is an UNSIGNED byte; validate against the version cap BEFORE
  -- allocating anything.
  local count = r:u8()
  if count > cap then
    raise_bad_count(count, cap, version, "exceeds version cap")
  end

  -- Pre-flight the remaining buffer so a legal-but-unsatisfiable count fails
  -- fast instead of looping into a truncated read.
  if count * MIN_RECORD_BYTES > r:remaining() then
    raise_bad_count(count, cap, version, "buffer cannot satisfy count")
  end

  local records = {}
  for index = 1, count do
    -- Read order matches the wire layout exactly.
    records[index] = {
      name = r:read_string(),
      sound_file = r:read_string(),
      key = r:u8(),
      press_key = r:u8(),
    }
  end
  return records
end

return instruments_custom
