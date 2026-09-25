-- tests/nbs/instruments_custom_spec.lua
--
-- Tier-1 spec for nbs/instruments_custom.lua -- the parser for the OPTIONAL
-- custom-instruments section that NBS appends after the layers section.
--
-- FROZEN INTERFACE UNDER TEST
--   local instruments_custom = require("nbs.instruments_custom")
--   instruments_custom.parse(r, version) -> array of records, each with
--   EXACTLY the keys:
--     name        string, BYTE-EXACT
--     sound_file  string, BYTE-EXACT (a path relative to the NBS /Sounds dir)
--     key         integer 0..87, verbatim (default 45 is a format convention,
--                 NOT something this parser substitutes)
--     press_key   integer 0 or 1, verbatim
--
-- WIRE LAYOUT (documented once, used by every fixture below)
--   u8 count
--   then `count` times:
--     str name        (i32 little-endian length, then that many RAW bytes)
--     str sound_file  (i32 little-endian length, then that many RAW bytes)
--     u8  key
--     u8  press_key
--   Every record therefore costs at least 4 + 4 + 1 + 1 = 10 bytes.
--
-- VERSION-DEPENDENT COUNT CAP (the real maximum is 240, never 255, because 16
-- vanilla instruments plus the custom ids must still fit in a byte):
--   version 0      -> 9
--   versions 1..4  -> 18
--   versions 5..6  -> 240
-- A count above the cap raises the typed table
--   { code = "E_BAD_INSTRUMENT_COUNT", msg, count, cap, version }
-- BEFORE any array is allocated.  A count the remaining buffer cannot satisfy
-- (count * 10 > remaining) raises the same typed table immediately, instead of
-- looping into a less useful E_TRUNCATED.
--
-- BYTE-EXACTNESS IS THE POINT of this module: sound_file is an opaque path and
-- must survive byte-for-byte (no UTF-8 decoding, no CP1252 -> UTF-8 display
-- mapping, no slash normalisation, no extension stripping).  Tests 4 and 5 lock
-- this down.  The consumer refuses custom instruments at playback time, but the
-- stored path must still print faithfully in diagnostics.

local reader = require("nbs.reader")
local instruments_custom = require("nbs.instruments_custom")

-- lstr(text) -> the i32 little-endian length prefix followed by the raw bytes.
-- Built by hand (no string.pack) so this stays Lua 5.2 / Cobalt compatible.
local function lstr(text)
  local n = #text
  local b1 = n % 256
  local b2 = math.floor(n / 256) % 256
  local b3 = math.floor(n / 65536) % 256
  local b4 = math.floor(n / 16777216) % 256
  return string.char(b1, b2, b3, b4) .. text
end

-- pcall wrapper: assert the call raised a TABLE (the typed-error contract) and
-- return it, so tests can branch on `.code` / `.cap` / `.count` / `.version`.
local function capture(fn)
  local ok, err = pcall(fn)
  expect.falsy(ok)
  expect.equal(type(err), "table")
  return err
end

describe("nbs.instruments_custom.parse -- happy paths", function()
  it("1. reads two v5 instruments with all four fields exact", function()
    -- count 2, then Piano2/dbass/key 45/press 1, then Sax/sax/key 60/press 0.
    local bytes = string.char(2)
      .. lstr("Piano2") .. lstr("dbass") .. string.char(45) .. string.char(1)
      .. lstr("Sax") .. lstr("sax") .. string.char(60) .. string.char(0)

    local result = instruments_custom.parse(reader.new(bytes), 5)

    expect.equal(#result, 2)
    expect.sequence_equal(result, {
      { name = "Piano2", sound_file = "dbass", key = 45, press_key = 1 },
      { name = "Sax", sound_file = "sax", key = 60, press_key = 0 },
    })
  end)

  it("2. reads a count of zero as an empty list", function()
    local result = instruments_custom.parse(reader.new(string.char(0)), 5)
    expect.equal(#result, 0)
    expect.equal(result[1], nil)
  end)

  it("3. an ABSENT section (already-exhausted reader) yields an empty list, no error", function()
    -- The section is optional.  An exhausted cursor must NOT raise, and must
    -- not attempt to read a count byte.
    local r = reader.new("X")
    r:u8() -- consume the only byte so r:eof() is true
    expect.truthy(r:eof())

    local result = instruments_custom.parse(r, 5)
    expect.equal(#result, 0)
    expect.truthy(r:eof())
  end)

  it("6. produces a record even when name and sound_file are both empty", function()
    local bytes = string.char(1)
      .. lstr("") .. lstr("") .. string.char(45) .. string.char(0)

    local result = instruments_custom.parse(reader.new(bytes), 5)
    expect.equal(#result, 1)
    expect.equal(result[1].name, "")
    expect.equal(result[1].sound_file, "")
    expect.equal(result[1].key, 45)
    expect.equal(result[1].press_key, 0)
  end)

  it("13. key is stored VERBATIM (byte 45 stays 45; default is a format convention)", function()
    -- NBS documents 45 as the "not set" default, but this parser must not
    -- invent it: whatever byte is on the wire is what the model keeps.
    local bytes = string.char(1)
      .. lstr("K") .. lstr("kick") .. string.char(45) .. string.char(0)

    local result = instruments_custom.parse(reader.new(bytes), 5)
    expect.equal(result[1].key, 45)
  end)

  it("14. press_key 0 and 1 are both returned verbatim", function()
    local bytes = string.char(2)
      .. lstr("A") .. lstr("a") .. string.char(45) .. string.char(0)
      .. lstr("B") .. lstr("b") .. string.char(46) .. string.char(1)

    local result = instruments_custom.parse(reader.new(bytes), 5)
    expect.equal(result[1].press_key, 0)
    expect.equal(result[2].press_key, 1)
  end)
end)

describe("nbs.instruments_custom.parse -- byte-exact paths (no transcoding)", function()
  it("4. preserves sound_file bytes 0x80/0x93/0xFF unchanged (length 3)", function()
    local payload = "\128\147\255"
    local bytes = string.char(1)
      .. lstr("accented") .. lstr(payload) .. string.char(45) .. string.char(0)

    local result = instruments_custom.parse(reader.new(bytes), 5)
    local sound_file = result[1].sound_file

    expect.equal(#sound_file, 3)
    expect.equal(string.byte(sound_file, 1), 128)
    expect.equal(string.byte(sound_file, 2), 147)
    expect.equal(string.byte(sound_file, 3), 255)
    -- Exact round-trip: no UTF-8 decode, no CP1252 remap ever touched it.
    expect.equal(sound_file, payload)
  end)

  it("5. keeps a slash-containing sound_file verbatim, including both slashes", function()
    local path = "sub/dir/sax"
    local bytes = string.char(1)
      .. lstr("n") .. lstr(path) .. string.char(45) .. string.char(0)

    local result = instruments_custom.parse(reader.new(bytes), 5)
    local sound_file = result[1].sound_file

    expect.equal(sound_file, path)
    -- Both separators survive: the parser is not a path normaliser.
    expect.equal(string.byte(sound_file, 4), 47) -- '/'
    expect.equal(string.byte(sound_file, 8), 47) -- '/'
  end)
end)

describe("nbs.instruments_custom.parse -- count cap is version-dependent and enforced first", function()
  it("7. count 241 at v5 raises E_BAD_INSTRUMENT_COUNT with cap 240", function()
    local err = capture(function()
      instruments_custom.parse(reader.new(string.char(241)), 5)
    end)
    expect.equal(err.code, "E_BAD_INSTRUMENT_COUNT")
    expect.equal(err.cap, 240)
    expect.equal(err.count, 241)
    expect.equal(err.version, 5)
  end)

  it("8. count 10 at v0 raises E_BAD_INSTRUMENT_COUNT with cap 9", function()
    local err = capture(function()
      instruments_custom.parse(reader.new(string.char(10)), 0)
    end)
    expect.equal(err.code, "E_BAD_INSTRUMENT_COUNT")
    expect.equal(err.cap, 9)
    expect.equal(err.count, 10)
    expect.equal(err.version, 0)
  end)

  it("9. count 19 at v4 raises E_BAD_INSTRUMENT_COUNT with cap 18", function()
    local err = capture(function()
      instruments_custom.parse(reader.new(string.char(19)), 4)
    end)
    expect.equal(err.code, "E_BAD_INSTRUMENT_COUNT")
    expect.equal(err.cap, 18)
    expect.equal(err.count, 19)
    expect.equal(err.version, 4)
  end)

  it("10. count exactly 240 at v5 is ACCEPTED (cap is inclusive)", function()
    -- 240 minimal records: each is lstr("")+lstr("")+key+press = 10 bytes.
    local record = lstr("") .. lstr("") .. string.char(45) .. string.char(0)
    local bytes = string.char(240) .. string.rep(record, 240)
    expect.equal(#bytes, 1 + 240 * 10)

    local r = reader.new(bytes)
    local result = instruments_custom.parse(r, 5)

    expect.equal(#result, 240)
    expect.equal(result[240].name, "")
    expect.equal(result[240].sound_file, "")
    expect.equal(result[240].key, 45)
    expect.truthy(r:eof())
  end)

  it("11. count 240 with too few bytes raises E_BAD_INSTRUMENT_COUNT fast", function()
    -- 50 bytes can never satisfy 240 records (needs >= 2400).  This must be
    -- rejected up front, NOT by looping into a truncated read.
    local bytes = string.char(240) .. string.rep("A", 50)
    local r = reader.new(bytes)

    local started = os.clock()
    local err = capture(function()
      instruments_custom.parse(r, 5)
    end)
    local elapsed = os.clock() - started

    expect.equal(err.code, "E_BAD_INSTRUMENT_COUNT")
    expect.equal(err.count, 240)
    -- Fast: no per-record allocation happened before the guard fired.
    expect.truthy(elapsed < 1.0)
    -- The count byte was consumed, but none of the payload was.
    expect.equal(r:remaining(), 50)
  end)
end)

describe("nbs.instruments_custom.parse -- truncation and consumption", function()
  it("12. a stream truncated mid-record raises E_TRUNCATED", function()
    -- count 2; record 1 is complete (16 bytes, so the buffer clears the
    -- count*10 = 20-byte minimum); record 2's name declares 100 bytes but only
    -- 5 are present, so read_string overruns mid-record.  This is genuinely a
    -- truncated variable-length read, distinct from the buffer-too-small guard
    -- of case 11.
    local record1 = lstr("AAAAAA") .. lstr("") .. string.char(45) .. string.char(0)
    local partial = string.char(100, 0, 0, 0) .. "abcde"
    local bytes = string.char(2) .. record1 .. partial
    expect.truthy(#record1 + #partial >= 2 * 10)

    local err = capture(function()
      instruments_custom.parse(reader.new(bytes), 5)
    end)
    expect.equal(err.code, "E_TRUNCATED")
  end)

  it("15. consumes exactly `count` records and leaves the remainder unread", function()
    -- Three full records on the wire but a count of 2: the third must be left
    -- untouched for whatever section follows.
    local record1 = lstr("A") .. lstr("a") .. string.char(45) .. string.char(0)
    local record2 = lstr("B") .. lstr("b") .. string.char(46) .. string.char(1)
    local record3 = lstr("C") .. lstr("c") .. string.char(47) .. string.char(0)
    local bytes = string.char(2) .. record1 .. record2 .. record3

    local r = reader.new(bytes)
    local result = instruments_custom.parse(r, 5)

    expect.equal(#result, 2)
    expect.equal(result[1].name, "A")
    expect.equal(result[2].name, "B")
    expect.equal(r:remaining(), #record3)
    expect.falsy(r:eof())
  end)
end)
