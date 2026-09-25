-- tests/nbs/reader_spec.lua
--
-- Tier-1 spec for nbs/reader.lua -- the little-endian byte cursor that every
-- NBS section parser is built on.
--
-- Contract highlights asserted here:
--   * ALL multi-byte integers are LITTLE-ENDIAN (NBS convention).
--   * read_string() is byte-exact: the declared i32 length is followed by that
--     many RAW bytes and they are returned UNtranscoded.  Bytes in 0x80-0xFF
--     must survive unchanged (NBS v0-v5 strings are CP1252, one byte per
--     character) -- that is the anti-UTF-8 guarantee this file locks down.
--   * On overrun the reader raises a TYPED ERROR TABLE:
--       { code = "E_TRUNCATED", msg = <string>, offset = <0-based>,
--         want = <bytes requested>, have = <bytes available> }
--     so the boundary layer can branch on `.code`.  We therefore inspect the
--     raised value with pcall instead of expect.raises (which only sees the
--     flattened message).

local reader = require("nbs.reader")

-- pcall wrapper: asserts the call raised, that the raised value is a TABLE (the
-- typed-error contract explicitly forbids the string form), and returns it.
local function capture(fn)
  local ok, err = pcall(fn)
  expect.falsy(ok)
  expect.equal(type(err), "table")
  return err
end

describe("nbs.reader signed/unsigned scalars (little-endian)", function()
  it("1. u8() reads 255 from byte 0xFF", function()
    local r = reader.new("\255")
    expect.equal(r:u8(), 255)
  end)

  it("2. i8() reads -1 from byte 0xFF", function()
    local r = reader.new("\255")
    expect.equal(r:i8(), -1)
  end)

  it("3. i16() reads -32768 from 00 80 (high byte is the sign byte)", function()
    local r = reader.new("\0\128")
    expect.equal(r:i16(), -32768)
  end)

  it("4. i16() reads -1 from FF FF", function()
    local r = reader.new("\255\255")
    expect.equal(r:i16(), -1)
  end)

  it("5. u16() reads 65535 from FF FF", function()
    local r = reader.new("\255\255")
    expect.equal(r:u16(), 65535)
  end)

  it("6. i32() reads -1 from FF FF FF FF", function()
    local r = reader.new("\255\255\255\255")
    expect.equal(r:i32(), -1)
  end)

  it("7. u32() reads 1 from 01 00 00 00", function()
    local r = reader.new("\1\0\0\0")
    expect.equal(r:u32(), 1)
  end)

  it("8. i64() reads -1 from eight 0xFF bytes", function()
    local r = reader.new("\255\255\255\255\255\255\255\255")
    expect.equal(r:i64(), -1)
  end)
end)

describe("nbs.reader read_string is byte-exact (no transcoding)", function()
  it("9. reads an i32 length then exactly that many bytes, then reports eof", function()
    local r = reader.new("\3\0\0\0abc")
    expect.equal(r:read_string(), "abc")
    expect.truthy(r:eof())
  end)

  it("10. preserves bytes 0x80/0x93/0xFF unchanged", function()
    local payload = "\128\147\255"
    local r = reader.new("\3\0\0\0" .. payload)
    local result = r:read_string()

    expect.equal(#result, 3)
    expect.equal(string.byte(result, 1), 128)
    expect.equal(string.byte(result, 2), 147)
    expect.equal(string.byte(result, 3), 255)

    -- The returned string must equal the original bytes exactly.  This is the
    -- anti-transcoding guarantee: no UTF-8 decoding may ever happen here.
    expect.equal(result, payload)
  end)

  it("11. reads an empty payload as the empty string, then eof", function()
    local r = reader.new("\0\0\0\0")
    expect.equal(r:read_string(), "")
    expect.truthy(r:eof())
  end)
end)

describe("nbs.reader read(0) and cursor bookkeeping", function()
  it("12. read(0) returns the empty string and does not advance", function()
    local r = reader.new("abc")
    expect.equal(r:read(0), "")
    expect.equal(r:pos(), 0)
    expect.equal(r:remaining(), 3)
  end)

  it("13. pos()/remaining()/eof() track a mixed read sequence", function()
    --             u8    u16=0x0302  u32=0x07060504   read(2)
    local r = reader.new("\1" .. "\2\3" .. "\4\5\6\7" .. "XY")

    expect.equal(r:pos(), 0)
    expect.equal(r:remaining(), 9)
    expect.falsy(r:eof())

    expect.equal(r:u8(), 1)
    expect.equal(r:pos(), 1)
    expect.equal(r:remaining(), 8)

    expect.equal(r:u16(), 770)
    expect.equal(r:pos(), 3)
    expect.equal(r:remaining(), 6)

    expect.equal(r:u32(), 117835012)
    expect.equal(r:pos(), 7)
    expect.equal(r:remaining(), 2)

    expect.equal(r:read(2), "XY")
    expect.equal(r:pos(), 9)
    expect.equal(r:remaining(), 0)
    expect.truthy(r:eof())
  end)
end)

describe("nbs.reader overrun raises E_TRUNCATED", function()
  it("14. read_string with only 2 of the promised 5 payload bytes", function()
    local r = reader.new("\5\0\0\0ab")
    local err = capture(function()
      r:read_string()
    end)
    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 4)
    expect.equal(err.want, 5)
    expect.equal(err.have, 2)
  end)

  it("15. i16() on an empty cursor", function()
    local r = reader.new("")
    local err = capture(function()
      r:i16()
    end)
    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 0)
    expect.equal(err.want, 2)
    expect.equal(err.have, 0)
  end)

  it("16. read(n) requesting more bytes than remain", function()
    local r = reader.new("abc")
    r:skip(1)
    local err = capture(function()
      r:read(5)
    end)
    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 1)
    expect.equal(err.want, 5)
    expect.equal(err.have, 2)
  end)

  it("17. skip(n) past the end", function()
    local r = reader.new("abc")
    local err = capture(function()
      r:skip(4)
    end)
    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 0)
    expect.equal(err.want, 4)
    expect.equal(err.have, 3)
  end)

  it("18. hostile i32 string length (0x7FFFFFFF) fails fast, no huge allocation", function()
    local r = reader.new("\255\255\255\127")
    local started = os.clock()
    local err = capture(function()
      r:read_string()
    end)
    local elapsed = os.clock() - started

    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 4)
    expect.equal(err.want, 2147483647)
    expect.equal(err.have, 0)
    -- The guard must reject the length BEFORE any allocation; a hostile length
    -- can therefore never cost more than a successful short read.
    expect.truthy(elapsed < 1.0)
  end)
end)

describe("nbs.reader error offsets mark where the failing read began", function()
  it("19a. a successful read advances the offset used by the next failure", function()
    -- 3-byte buffer: consume one byte, then a 4-byte scalar cannot fit in the
    -- two bytes that remain.
    local r = reader.new("abc")
    r:u8()
    local err = capture(function()
      r:u32()
    end)
    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 1)
    expect.equal(err.want, 4)
    expect.equal(err.have, 2)
  end)

  it("19b. read_string failure offset points at the payload, not the length", function()
    -- 4 length bytes read cleanly; the payload read begins at offset 4.
    local r = reader.new("\9\0\0\0z")
    local err = capture(function()
      r:read_string()
    end)
    expect.equal(err.code, "E_TRUNCATED")
    expect.equal(err.offset, 4)
    expect.equal(err.want, 9)
    expect.equal(err.have, 1)
  end)
end)
