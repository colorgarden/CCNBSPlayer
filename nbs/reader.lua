-- nbs/reader.lua
--
-- Little-endian byte cursor for Note Block Studio (.nbs) files.
--
-- Every section parser in the decoder (header, notes, layers, custom
-- instruments, ...) reads its fields through this module, so the semantics here
-- are a frozen contract:
--
--   * ALL multi-byte integers are LITTLE-ENDIAN.  This is the NBS format
--     convention, verified against pynbs (file.py), nbs.js
--     (BinaryReader.ts) and NBS4j (NBSReader.java).
--   * read_string() reads an i32 byte count followed by exactly that many RAW
--     bytes and returns them untouched.  NBS v0-v5 strings are CP1252, i.e. one
--     byte per character; bytes in the 0x80-0xFF range must survive unchanged
--     so that custom-instrument sound paths stay valid.  This module NEVER
--     performs UTF-8 decoding -- display conversion is a separate concern
--     (nbs/cp1252.lua).
--   * On any overrun every read raises a TYPED ERROR TABLE
--     { code = "E_TRUNCATED", msg = <string>, offset = <0-based>,
--       want = <bytes requested>, have = <bytes available> }
--     via error(table).  The string form of error() is deliberately NOT used:
--     the boundary layer branches on the structured `.code`.  A short string is
--     never returned and the cursor never advances past the end.
--
-- i64 PRECISION NOTE
-- ------------------
-- Cobalt tracks Lua 5.2, whose numbers are IEEE-754 doubles with a 53-bit
-- significand.  A full 64-bit signed value therefore cannot round-trip exactly
-- for magnitudes above 2^53.  i64() is implemented best-effort: it reads the 8
-- little-endian bytes and reconstructs the value as a double, which is EXACT
-- for the small values and for -1 that the spec asserts, but loses precision
-- for exotic magnitudes.  This is acceptable because the only i64 field in NBS
-- is a statistics counter (minutes spent / click counts) that the player never
-- uses arithmetically.  Do NOT rely on i64() for exact large-magnitude values.
--
-- Lua 5.2 / Cobalt constraints honoured here: no `//`, no bitwise operators,
-- no math.maxinteger, no collectgarbage, no string.dump, no os.exit.  Only
-- string.byte / string.sub / arithmetic are used.

local reader = {}

-- Cursor object -----------------------------------------------------------------

local Cursor = {}
Cursor.__index = Cursor

-- reader.new(bytes) -> cursor
-- `bytes` is a Lua string (a raw byte buffer); the cursor starts at offset 0.
function reader.new(bytes)
  if type(bytes) ~= "string" then
    error("nbs.reader.new: expected a string, got " .. type(bytes), 2)
  end
  return setmetatable({ bytes = bytes, len = #bytes, _pos = 0 }, Cursor)
end

-- Typed overrun error -----------------------------------------------------------
--
-- Raised as a TABLE so the decoded `.code` survives pcall.  `offset` is the
-- 0-based position at which the failing read was attempted.
local function truncated(offset, want, have)
  error({
    code = "E_TRUNCATED",
    msg = string.format(
      "truncated read at offset %d: wanted %d byte(s), %d available",
      offset, want, have),
    offset = offset,
    want = want,
    have = have,
  }, 0)
end

-- Generic fixed-width little-endian decoder.
--
-- Reads `n` bytes starting at the current position and interprets them as an
-- unsigned integer, or as a two's-complement signed integer when `signed` is
-- true (the most significant byte, i.e. the LAST byte in little-endian order,
-- carries the sign).  Bounds are checked before touching any byte and the
-- cursor only advances on success.
function Cursor:_read_int(n, signed)
  local p = self._pos
  local available = self.len - p
  if n > available then
    truncated(p, n, available)
  end

  -- Start from the most significant byte so that sign extension works by plain
  -- arithmetic (no bitwise operators on doubles).
  local top = string.byte(self.bytes, p + n)
  local value
  if signed and top >= 128 then
    value = top - 256
  else
    value = top
  end

  local i = n - 1
  while i >= 1 do
    value = value * 256 + string.byte(self.bytes, p + i)
    i = i - 1
  end

  self._pos = p + n
  return value
end

-- Unsigned scalars --------------------------------------------------------------

function Cursor:u8()
  return self:_read_int(1, false)
end

function Cursor:u16()
  return self:_read_int(2, false)
end

function Cursor:u32()
  return self:_read_int(4, false)
end

-- Signed scalars ----------------------------------------------------------------

function Cursor:i8()
  return self:_read_int(1, true)
end

function Cursor:i16()
  return self:_read_int(2, true)
end

function Cursor:i32()
  return self:_read_int(4, true)
end

-- See the i64 PRECISION NOTE at the top of this file.
function Cursor:i64()
  return self:_read_int(8, true)
end

-- Raw byte reads ----------------------------------------------------------------

-- read(n) -> string: exactly n RAW bytes, byte-exact, or raise E_TRUNCATED.
-- read(0) returns "" and does not advance.
function Cursor:read(n)
  if type(n) ~= "number" then
    error("nbs.reader:read: expected a number, got " .. type(n), 2)
  end
  if n < 0 then
    truncated(self._pos, n, self.len - self._pos)
  end
  if n == 0 then
    return ""
  end

  local p = self._pos
  local available = self.len - p
  if n > available then
    truncated(p, n, available)
  end

  local out = string.sub(self.bytes, p + 1, p + n)
  self._pos = p + n
  return out
end

-- read_string() -> string: i32 little-endian byte count, then that many RAW
-- bytes, byte-exact and untranscoded (see the module header).  The declared
-- length is validated against the bytes actually available BEFORE any
-- allocation or slicing, so a hostile length such as 0x7FFFFFFF fails fast.
function Cursor:read_string()
  -- Read the signed i32 length first; this advances past the 4 length bytes.
  local n = self:_read_int(4, true)

  if n < 0 then
    truncated(self._pos, n, self.len - self._pos)
  end

  local available = self.len - self._pos
  if n > available then
    truncated(self._pos, n, available)
  end

  if n == 0 then
    return ""
  end

  local out = string.sub(self.bytes, self._pos + 1, self._pos + n)
  self._pos = self._pos + n
  return out
end

-- Cursor bookkeeping ------------------------------------------------------------

-- skip(n): advance n bytes, bounds-checked; raises E_TRUNCATED on overrun.
function Cursor:skip(n)
  if type(n) ~= "number" then
    error("nbs.reader:skip: expected a number, got " .. type(n), 2)
  end
  if n < 0 then
    truncated(self._pos, n, self.len - self._pos)
  end

  local available = self.len - self._pos
  if n > available then
    truncated(self._pos, n, available)
  end
  self._pos = self._pos + n
end

function Cursor:pos()
  return self._pos
end

function Cursor:remaining()
  return self.len - self._pos
end

function Cursor:eof()
  return self._pos >= self.len
end

return reader
