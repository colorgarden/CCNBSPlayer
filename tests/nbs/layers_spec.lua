-- tests/nbs/layers_spec.lua
--
-- Tier-1 spec for nbs/layers.lua -- the NBS layers-section parser.
--
-- FROZEN PUBLIC INTERFACE
--   local layers = require("nbs.layers")
--   layers.parse(r, version, layer_count) -> <array of layer records>
--
-- Each record has EXACTLY these keys:
--   name     string, BYTE-EXACT
--   lock     0 = unlocked, 1 = locked, 2 = solo ; nil when version < 4
--   volume   integer 0..100
--   panning  integer 0..200 (100 = centre) ; nil when version < 2
--
-- RECORD LAYOUT read layer_count times, in order:
--   str name
--   u8  lock     -- ONLY when version >= 4
--   u8  volume   -- 0..100
--   u8  panning  -- ONLY when version >= 2
--
-- So v0/v1 = name + volume; v2/v3 = name + volume + panning; v4+ adds lock
-- between the name and the volume.  Reading the wrong number of bytes for a
-- given version silently desynchronises every SUBSEQUENT record, so the
-- version-gated cases below assert both the field values AND that the cursor
-- stops exactly at end-of-buffer.
--
-- FIXTURE LAYOUT (built in code; no .nbs files are downloaded or read):
--   lstr(text) = i32 little-endian byte length, then the raw bytes of `text`.
--   A layer record is the concatenation of those fields, e.g. for v5
--     lstr(name) .. string.char(lock, volume, panning)
--   and for v1
--     lstr(name) .. string.char(volume)
--   All scalar bytes are produced with string.char; multi-byte lengths with a
--   manual little-endian encoder (no bitwise ops, no `//`, Cobalt-safe).

local reader = require("nbs.reader")
local layers = require("nbs.layers")

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

-- le32(n): the four little-endian bytes of a non-negative integer < 2^32.
local function le32(n)
  local b0 = n % 256
  local b1 = math.floor(n / 256) % 256
  local b2 = math.floor(n / 65536) % 256
  local b3 = math.floor(n / 16777216) % 256
  return string.char(b0, b1, b2, b3)
end

-- lstr(text): i32 length prefix (little-endian) followed by the raw bytes.
local function lstr(text)
  return le32(#text) .. text
end

-- Record builders, one per version-gated layout (see the header comment).
local function rec_v5(name, lock, volume, panning)
  return lstr(name) .. string.char(lock, volume, panning)
end

local function rec_v2(name, volume, panning)
  return lstr(name) .. string.char(volume, panning)
end

local function rec_v1(name, volume)
  return lstr(name) .. string.char(volume)
end

-- pcall wrapper for typed error tables: asserts the call raised, that the
-- raised value is a table, and returns it so `.code` can be inspected.
local function capture(fn)
  local ok, err = pcall(fn)
  expect.falsy(ok)
  expect.equal(type(err), "table")
  return err
end

-- ---------------------------------------------------------------------------
-- 1. v5 single layer -- all four fields
-- ---------------------------------------------------------------------------

describe("nbs.layers v5 full record", function()
  it("1. reads name/lock/volume/panning byte-exact and yields one layer", function()
    local r = reader.new(rec_v5("Lead", 1, 80, 150))
    local result = layers.parse(r, 5, 1)

    expect.equal(#result, 1)
    expect.equal(result[1].name, "Lead")
    expect.equal(result[1].lock, 1)
    expect.equal(result[1].volume, 80)
    expect.equal(result[1].panning, 150)
    expect.truthy(r:eof())
  end)
end)

-- ---------------------------------------------------------------------------
-- 2. Multiple layers preserve order
-- ---------------------------------------------------------------------------

describe("nbs.layers ordering", function()
  it("2. keeps three layers in stream order (a, b, c)", function()
    local r = reader.new(
      rec_v5("a", 0, 10, 100) ..
      rec_v5("b", 0, 20, 100) ..
      rec_v5("c", 0, 30, 100))
    local result = layers.parse(r, 5, 3)

    expect.equal(#result, 3)
    expect.equal(result[1].name, "a")
    expect.equal(result[2].name, "b")
    expect.equal(result[3].name, "c")
    expect.equal(result[1].volume, 10)
    expect.equal(result[2].volume, 20)
    expect.equal(result[3].volume, 30)
    expect.truthy(r:eof())
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. v3 has NO lock byte
-- ---------------------------------------------------------------------------

describe("nbs.layers version gating", function()
  it("3. v3 record is name+volume+panning: lock is nil and the cursor stops exactly at eof", function()
    local r = reader.new(rec_v2("Pad", 90, 25))
    local result = layers.parse(r, 3, 1)

    expect.equal(#result, 1)
    expect.equal(result[1].name, "Pad")
    expect.equal(result[1].lock, nil)
    expect.equal(result[1].volume, 90)
    expect.equal(result[1].panning, 25)
    expect.truthy(r:eof())
  end)

  it("4. v1 record is name+volume: panning and lock are nil, cursor stops exactly at eof", function()
    local r = reader.new(rec_v1("Bass", 77))
    local result = layers.parse(r, 1, 1)

    expect.equal(#result, 1)
    expect.equal(result[1].name, "Bass")
    expect.equal(result[1].lock, nil)
    expect.equal(result[1].panning, nil)
    expect.equal(result[1].volume, 77)
    expect.truthy(r:eof())
  end)

  it("5. v0 record is name+volume: both lock and panning are nil, cursor stops exactly at eof", function()
    local r = reader.new(rec_v1("Organ", 42))
    local result = layers.parse(r, 0, 1)

    expect.equal(#result, 1)
    expect.equal(result[1].name, "Organ")
    expect.equal(result[1].lock, nil)
    expect.equal(result[1].panning, nil)
    expect.equal(result[1].volume, 42)
    expect.truthy(r:eof())
  end)
end)

-- ---------------------------------------------------------------------------
-- 6-7. Lock semantics: 0, 1 and the undocumented SOLO value 2
-- ---------------------------------------------------------------------------

describe("nbs.layers lock semantics", function()
  it("6. exposes SOLO (raw byte 2) verbatim without collapsing or raising", function()
    local r = reader.new(rec_v5("Solo", 2, 65, 100))
    local result = layers.parse(r, 5, 1)

    expect.equal(result[1].lock, 2)
    expect.truthy(result[1].lock ~= nil)
    expect.truthy(result[1].lock ~= 1)
    expect.equal(result[1].volume, 65)
  end)

  it("7. passes lock values 0 and 1 through verbatim", function()
    local r = reader.new(
      rec_v5("off", 0, 50, 100) ..
      rec_v5("on", 1, 60, 100))
    local result = layers.parse(r, 5, 2)

    expect.equal(result[1].lock, 0)
    expect.equal(result[2].lock, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. Panning extremes must be UNSIGNED
-- ---------------------------------------------------------------------------

describe("nbs.layers scalar ranges", function()
  it("8. panning bytes 0 and 200 read as 0 and 200 (200 is not -56)", function()
    local r = reader.new(
      rec_v5("L", 0, 100, 0) ..
      rec_v5("R", 0, 100, 200))
    local result = layers.parse(r, 5, 2)

    expect.equal(result[1].panning, 0)
    expect.equal(result[2].panning, 200)
  end)

  it("11. volume bytes 0 and 100 are preserved verbatim", function()
    local r = reader.new(
      rec_v5("mute", 0, 0, 100) ..
      rec_v5("max", 0, 100, 100))
    local result = layers.parse(r, 5, 2)

    expect.equal(result[1].volume, 0)
    expect.equal(result[2].volume, 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- 9-10. Names: empty and byte-exact
-- ---------------------------------------------------------------------------

describe("nbs.layers names", function()
  it("9. accepts an empty name and still parses the record", function()
    local r = reader.new(rec_v5("", 0, 55, 100))
    local result = layers.parse(r, 5, 1)

    expect.equal(#result, 1)
    expect.equal(result[1].name, "")
    expect.equal(result[1].volume, 55)
    expect.truthy(r:eof())
  end)

  it("10. preserves high bytes 128/147/255 unchanged", function()
    local raw = string.char(128, 147, 255)
    local r = reader.new(rec_v5(raw, 0, 55, 100))
    local result = layers.parse(r, 5, 1)

    expect.equal(result[1].name, raw)
    expect.equal(string.byte(result[1].name, 1), 128)
    expect.equal(string.byte(result[1].name, 2), 147)
    expect.equal(string.byte(result[1].name, 3), 255)
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. layer_count 0
-- ---------------------------------------------------------------------------

describe("nbs.layers empty section", function()
  it("12. layer_count 0 returns an empty array and leaves an empty stream at eof", function()
    local r = reader.new("")
    local result = layers.parse(r, 5, 0)

    expect.equal(type(result), "table")
    expect.equal(#result, 0)
    expect.truthy(r:eof())
  end)
end)

-- ---------------------------------------------------------------------------
-- 13-15. Safety and exact consumption
-- ---------------------------------------------------------------------------

describe("nbs.layers untrusted count and truncation", function()
  it("13. rejects an absurd layer_count fast, without allocating, as E_BAD_LAYER_COUNT", function()
    -- Eight bytes of real data (4 length + 1 name + lock + volume + panning).
    -- The guard must fire before any loop.
    local r = reader.new(rec_v5("x", 1, 50, 100))

    local started = os.clock()
    local err = capture(function()
      return layers.parse(r, 5, 100000)
    end)
    local elapsed = os.clock() - started

    expect.equal(err.code, "E_BAD_LAYER_COUNT")
    expect.equal(err.layer_count, 100000)
    expect.equal(err.remaining, 8)
    expect.truthy(elapsed < 1)
  end)

  it("14. a stream truncated mid-name raises E_TRUNCATED", function()
    -- Declare a 3-byte name but supply only 2 bytes.
    local r = reader.new(le32(3) .. "ab")
    local err = capture(function()
      return layers.parse(r, 5, 1)
    end)

    expect.equal(err.code, "E_TRUNCATED")
  end)

  it("15. reads exactly layer_count records and leaves the rest unread", function()
    local third = rec_v5("c", 0, 30, 100)
    local r = reader.new(
      rec_v5("a", 0, 10, 100) ..
      rec_v5("b", 0, 20, 100) ..
      third)

    local result = layers.parse(r, 5, 2)

    expect.equal(#result, 2)
    expect.equal(result[1].name, "a")
    expect.equal(result[2].name, "b")
    expect.equal(r:remaining(), #third)
    expect.falsy(r:eof())
  end)
end)
