-- nbs/notes.lua
--
-- Note-section parser for Note Block Studio (.nbs) files.
--
-- The note section uses a run-length "jump" encoding: instead of storing every
-- (tick, layer) pair, it stores the DELTA to the next used tick and, within a
-- tick, the DELTA to the next used layer.  A zero delta terminates the current
-- level:
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
--         velocity = u8
--         panning  = u8
--         pitch    = i16
--       else
--         velocity = 100 ; panning = 100 ; pitch = 0
--       end
--       emit { tick, layer, instrument, key, velocity, panning, pitch }
--
-- Notes are appended in encounter order (ascending tick, then ascending layer
-- within a tick); the parser NEVER sorts.
--
-- SIGNEDNESS -- the published NBS specification is internally inconsistent, so
-- this module follows the interpretation already frozen for the rest of the
-- decoder:
--   * jumps (i16) and pitch (i16) are SIGNED.
--   * instrument, key, velocity and panning are read as UNSIGNED bytes (u8).
--     Panning legitimately reaches 200, which would read as -56 if signed.
--
-- SAFETY -- a player owns the computer's only thread, so the parser must never
-- spin or walk backwards on hostile input:
--   * A negative jump is corrupt and raises E_BAD_JUMP immediately.
--   * The cursor only ever advances (every read consumes bytes).
--   * The outer loop is capped at r:remaining() iterations (each tick consumes
--     at least its 2-byte jump), and a tick above 32000 raises
--     E_TOO_MANY_TICKS -- some NBS versions crash past that point.
--   * An absolute layer index above 200 raises E_LAYER_OVERFLOW.
--   * Overruns propagate the reader's typed E_TRUNCATED error unchanged.
--
-- All typed errors are TABLES raised via error(tbl, 0) so callers branch on
-- `.code`:
--   { code = "E_BAD_JUMP" | "E_LAYER_OVERFLOW" | "E_TOO_MANY_TICKS", msg, offset }
--
-- Lua 5.2 / Cobalt constraints: no `//`, no bitwise operators, no goto.

local notes = {}

-- Documented NBS unsafe-in-practice ceilings (see module header).
local MAX_LAYER = 200
local MAX_TICK = 32000

-- Typed error helper.  `offset` is the cursor position at which the offending
-- value BEGAN (i.e. r:pos() before its read).
local function raise(code, message, offset)
  error({ code = code, msg = message, offset = offset }, 0)
end

-- notes.parse(r, version) -> { notes = { <note>, ... }, song_length_from_notes = <int> }
--
-- `r` is an nbs.reader cursor positioned at the first tick jump.  `song_length_from_notes`
-- is the highest tick that carries a note, plus one (0 when there are no notes);
-- v1/v2 songs, which store no length, recover it this way.
function notes.parse(r, version)
  if type(version) ~= "number" then
    version = 0
  end
  local has_v4_fields = version >= 4

  -- Byte-derived iteration cap: every outer iteration consumes at least the
  -- 2-byte tick jump, so more ticks than bytes remaining is impossible for
  -- honest input and implies corruption.
  local max_ticks = r:remaining()

  local parsed = {}
  local song_length = 0

  local tick = -1
  local ticks_seen = 0

  while true do
    ticks_seen = ticks_seen + 1
    if ticks_seen > max_ticks then
      raise("E_TOO_MANY_TICKS",
        string.format("tick count exceeded byte budget (%d) at offset %d",
          max_ticks, r:pos()), r:pos())
    end

    local tick_offset = r:pos()
    local jumps_to_next_tick = r:i16()
    if jumps_to_next_tick == 0 then
      break
    end
    if jumps_to_next_tick < 0 then
      raise("E_BAD_JUMP",
        string.format("negative tick jump %d at offset %d",
          jumps_to_next_tick, tick_offset), tick_offset)
    end

    tick = tick + jumps_to_next_tick
    if tick > MAX_TICK then
      raise("E_TOO_MANY_TICKS",
        string.format("tick %d exceeds safe ceiling %d at offset %d",
          tick, MAX_TICK, tick_offset), tick_offset)
    end

    local layer = -1
    while true do
      local layer_offset = r:pos()
      local jumps_to_next_layer = r:i16()
      if jumps_to_next_layer == 0 then
        break
      end
      if jumps_to_next_layer < 0 then
        raise("E_BAD_JUMP",
          string.format("negative layer jump %d at offset %d",
            jumps_to_next_layer, layer_offset), layer_offset)
      end

      layer = layer + jumps_to_next_layer
      if layer < 0 or layer > MAX_LAYER then
        raise("E_LAYER_OVERFLOW",
          string.format("layer index %d out of range 0..%d at offset %d",
            layer, MAX_LAYER, layer_offset), layer_offset)
      end

      local instrument = r:u8()
      local key = r:u8()
      local velocity, panning, pitch
      if has_v4_fields then
        velocity = r:u8()
        panning = r:u8()
        pitch = r:i16()
      else
        velocity = 100
        panning = 100
        pitch = 0
      end

      parsed[#parsed + 1] = {
        tick = tick,
        layer = layer,
        instrument = instrument,
        key = key,
        velocity = velocity,
        panning = panning,
        pitch = pitch,
      }

      if tick + 1 > song_length then
        song_length = tick + 1
      end
    end
  end

  return {
    notes = parsed,
    song_length_from_notes = song_length,
  }
end

return notes
