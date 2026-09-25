-- tests/nbs/notes_spec.lua
--
-- Tier-1 spec for nbs/notes.lua -- the NBS note-section parser, which decodes
-- the run-length "jump" encoding.
--
-- THE JUMP FORMAT (used by every fixture below; all integers little-endian):
--
--   tick = -1
--   loop forever:
--     jumps_to_next_tick = i16            -- 0 ends the note section
--     if jumps_to_next_tick == 0 then break
--     tick = tick + jumps_to_next_tick
--     layer = -1
--     loop forever:
--       jumps_to_next_layer = i16         -- 0 moves on to the next tick
--       if jumps_to_next_layer == 0 then break
--       layer = layer + jumps_to_next_layer
--       instrument = u8
--       key        = u8
--       if version >= 4 then
--         velocity = u8 ; panning = u8 ; pitch = i16
--       else
--         velocity = 100 ; panning = 100 ; pitch = 0
--       end
--       emit { tick, layer, instrument, key, velocity, panning, pitch }
--
-- SIGNEDNESS (frozen): jumps (i16) and pitch (i16) are SIGNED.  instrument,
-- key, velocity and panning are read as UNSIGNED bytes (u8).  Panning legally
-- reaches 200 (centre = 100); reading it signed would yield -56 -- case 3 is
-- the trap guard.
--
-- EXACT BYTE LAYOUT OF A MINIMAL v4+ ONE-NOTE SECTION (case 1):
--   le16(1)            "\1\0"      tick  -1 -> 0
--   le16(1)            "\1\0"      layer -1 -> 0
--   string.char(0)     "\0"        instrument 0
--   string.char(45)    "\45"       key 45
--   string.char(100)   "\100"      velocity 100
--   string.char(100)   "\100"      panning 100
--   le16(0)            "\0\0"      pitch 0
--   le16(0)            "\0\0"      layer 0 -> next tick
--   le16(0)            "\0\0"      tick 0 -> end of section
-- v3 and older omit the velocity/panning/pitch run entirely (case 2).
--
-- Typed errors are raised as TABLES, so we inspect them with pcall rather than
-- expect.raises (which only sees the flattened string form):
--   E_BAD_JUMP, E_LAYER_OVERFLOW, E_TOO_MANY_TICKS, E_TRUNCATED.

local reader = require("nbs.reader")
local notes = require("nbs.notes")

-- ---------------------------------------------------------------------------
-- Byte-layout fixture helpers
-- ---------------------------------------------------------------------------

-- le16(n) -> the two little-endian bytes of a signed/unsigned 16-bit n.
-- Negative n is encoded two's-complement: -1 -> FF FF, -50 -> CE FF.
local function le16(n)
  if n < 0 then
    n = n + 65536
  end
  local lo = n % 256
  local hi = math.floor(n / 256) % 256
  return string.char(lo, hi)
end

-- le32(n) -> the four little-endian bytes of a signed/unsigned 32-bit n.
-- Provided for completeness/composability; the note section itself has no
-- 32-bit field (read_string's i32 length belongs to other sections).
local function le32(n)
  if n < 0 then
    n = n + 4294967296
  end
  local b1 = n % 256
  local b2 = math.floor(n / 256) % 256
  local b3 = math.floor(n / 65536) % 256
  local b4 = math.floor(n / 16777216) % 256
  return string.char(b1, b2, b3, b4)
end

-- v4_note(...) -> instrument u8, key u8, velocity u8, panning u8, pitch i16.
local function v4_note(instrument, key, velocity, panning, pitch)
  return string.char(instrument, key, velocity, panning) .. le16(pitch)
end

-- v3_note(...) -> instrument u8, key u8 (velocity/panning/pitch are absent and
-- the parser must default them).
local function v3_note(instrument, key)
  return string.char(instrument, key)
end

-- parse(bytes, version) -> the frozen result table.
local function parse(bytes, version)
  return notes.parse(reader.new(bytes), version)
end

-- pcall wrapper: asserts the call raised a TABLE (the typed-error contract
-- forbids the string form) and returns it.
local function capture(fn)
  local ok, err = pcall(fn)
  expect.falsy(ok)
  expect.equal(type(err), "table")
  return err
end

-- ---------------------------------------------------------------------------
-- Cases
-- ---------------------------------------------------------------------------

describe("nbs.notes single-note decoding", function()
  it("1. a v4+ note decodes tick/layer/instrument/key/velocity/panning/pitch exactly", function()
    local bytes = le16(1) .. le16(1)
      .. v4_note(0, 45, 100, 100, 0)
      .. le16(0) .. le16(0)
    local result = parse(bytes, 5)
    expect.equal(#result.notes, 1)
    expect.deep_equal(result.notes[1], {
      tick = 0,
      layer = 0,
      instrument = 0,
      key = 45,
      velocity = 100,
      panning = 100,
      pitch = 0,
    })
    expect.equal(result.song_length_from_notes, 1)
  end)

  it("2. version 3 defaults velocity=100/panning=100/pitch=0 and consumes no extra bytes", function()
    -- The v3 stream ends immediately after the section; r:eof() proves the
    -- parser did not try to read the v4 velocity/panning/pitch run.
    local r = reader.new(le16(1) .. le16(1) .. v3_note(2, 60) .. le16(0) .. le16(0))
    local result = notes.parse(r, 3)
    expect.equal(#result.notes, 1)
    expect.deep_equal(result.notes[1], {
      tick = 0,
      layer = 0,
      instrument = 2,
      key = 60,
      velocity = 100,
      panning = 100,
      pitch = 0,
    })
    expect.truthy(r:eof())
  end)

  it("3. a raw panning byte of 200 reads back as 200, never -56 (unsigned trap)", function()
    local bytes = le16(1) .. le16(1)
      .. v4_note(0, 45, 100, 200, 0)
      .. le16(0) .. le16(0)
    local result = parse(bytes, 4)
    expect.equal(result.notes[1].panning, 200)
  end)

  it("13. pitch is signed (-50 cents) while key stays an unsigned byte in 0..87", function()
    local bytes = le16(1) .. le16(1)
      .. v4_note(3, 87, 100, 100, -50)
      .. le16(0) .. le16(0)
    local result = parse(bytes, 5)
    expect.equal(result.notes[1].pitch, -50)
    expect.equal(result.notes[1].key, 87)
    expect.truthy(result.notes[1].key >= 0 and result.notes[1].key <= 87)
  end)
end)

describe("nbs.notes run-length jumps across ticks and layers", function()
  it("4. tick jumps 1,2,1 place notes at ticks 0,2,3 and yield song length 4", function()
    local bytes = le16(1) .. le16(1) .. v4_note(0, 45, 100, 100, 0) .. le16(0)
      .. le16(2) .. le16(1) .. v4_note(0, 46, 100, 100, 0) .. le16(0)
      .. le16(1) .. le16(1) .. v4_note(0, 47, 100, 100, 0) .. le16(0)
      .. le16(0)
    local result = parse(bytes, 5)
    expect.equal(#result.notes, 3)
    expect.equal(result.notes[1].tick, 0)
    expect.equal(result.notes[2].tick, 2)
    expect.equal(result.notes[3].tick, 3)
    expect.equal(result.song_length_from_notes, 4)
  end)

  it("5. two layer jumps in one tick emit layers 0 then 1 in that order", function()
    local bytes = le16(1)
      .. le16(1) .. v4_note(0, 45, 100, 100, 0)
      .. le16(1) .. v4_note(0, 46, 100, 100, 0)
      .. le16(0) .. le16(0)
    local result = parse(bytes, 5)
    expect.equal(#result.notes, 2)
    expect.equal(result.notes[1].tick, 0)
    expect.equal(result.notes[1].layer, 0)
    expect.equal(result.notes[2].tick, 0)
    expect.equal(result.notes[2].layer, 1)
  end)

  it("6. a layer jump of 3 skips from layer 0 to layer 3", function()
    -- layer starts at -1, so the first jump of 1 lands on 0; the following
    -- jump of 3 then lands on 0 + 3 = 3 (skipping layers 1 and 2).
    local bytes = le16(1)
      .. le16(1) .. v4_note(0, 45, 100, 100, 0)
      .. le16(3) .. v4_note(0, 46, 100, 100, 0)
      .. le16(0) .. le16(0)
    local result = parse(bytes, 5)
    expect.equal(#result.notes, 2)
    expect.equal(result.notes[1].layer, 0)
    expect.equal(result.notes[2].layer, 3)
  end)

  it("7. an empty section (a single i16 0) yields no notes and length 0", function()
    local result = parse(le16(0), 5)
    expect.equal(#result.notes, 0)
    expect.equal(result.song_length_from_notes, 0)
  end)

  it("8. emission order is ascending tick then ascending layer (no reordering)", function()
    local bytes = le16(1)
      -- tick 0: layers 0 and 2
      .. le16(1) .. v4_note(1, 40, 100, 100, 0)
      .. le16(2) .. v4_note(1, 41, 100, 100, 0)
      .. le16(0)
      -- tick 3: layer 1
      .. le16(3) .. le16(2) .. v4_note(1, 42, 100, 100, 0) .. le16(0)
      -- tick 5: layers 0 and 1
      .. le16(2)
      .. le16(1) .. v4_note(1, 43, 100, 100, 0)
      .. le16(1) .. v4_note(1, 44, 100, 100, 0)
      .. le16(0)
      .. le16(0)
    local result = parse(bytes, 5)
    local order = {}
    for index = 1, #result.notes do
      order[#order + 1] = result.notes[index].tick .. ":" .. result.notes[index].layer
    end
    expect.sequence_equal(order, { "0:0", "0:2", "3:1", "5:0", "5:1" })
    expect.equal(result.song_length_from_notes, 6)
  end)
end)

describe("nbs.notes hostile-input bounds", function()
  it("9. a negative tick jump raises E_BAD_JUMP with the pre-read offset", function()
    local err = capture(function()
      return parse(le16(-1), 5)
    end)
    expect.equal(err.code, "E_BAD_JUMP")
    expect.equal(err.offset, 0)
  end)

  it("10. a stream of unit tick jumps with no terminating 0 fails fast with E_TOO_MANY_TICKS", function()
    -- 32002 empty ticks: each is a tick jump of +1 followed by a layer jump of
    -- 0 (no notes).  tick reaches 32001 > 32000, so the ceiling fires.  The
    -- byte-derived outer-loop cap is a second guard behind it; either way the
    -- parse is bounded and must finish well under one second.
    local chunk = le16(1) .. le16(0)
    local pieces = {}
    for _ = 1, 32002 do
      pieces[#pieces + 1] = chunk
    end
    local bytes = table.concat(pieces)

    local started = os.clock()
    local err = capture(function()
      return parse(bytes, 4)
    end)
    local elapsed = os.clock() - started

    expect.equal(err.code, "E_TOO_MANY_TICKS")
    expect.truthy(elapsed < 1.0)
  end)

  it("11. a stream truncated mid-layer raises E_TRUNCATED", function()
    -- tick +1, layer +1, one instrument byte written, then the buffer ends
    -- before the key byte can be read.
    local err = capture(function()
      return parse(le16(1) .. le16(1) .. string.char(5), 5)
    end)
    expect.equal(err.code, "E_TRUNCATED")
  end)

  it("12. a layer index above 200 raises E_LAYER_OVERFLOW", function()
    -- layer starts at -1; a jump of 202 lands on 201 (> 200).
    local err = capture(function()
      return parse(le16(1) .. le16(202), 5)
    end)
    expect.equal(err.code, "E_LAYER_OVERFLOW")
  end)
end)

-- The le32 helper is intentionally exercised so a future refactor cannot delete
-- it silently; the note section has no 32-bit field, so we only assert its
-- little-endian byte order directly.
describe("notes_spec fixture helpers", function()
  it("le16/le32 encode little-endian two's-complement words", function()
    expect.equal(le16(1), "\1\0")
    expect.equal(le16(300), string.char(44, 1))
    expect.equal(le16(-1), "\255\255")
    expect.equal(le16(-50), string.char(206, 255))
    expect.equal(le32(1), "\1\0\0\0")
    expect.equal(le32(-1), "\255\255\255\255")
  end)
end)
