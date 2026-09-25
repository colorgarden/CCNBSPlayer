-- nbs/header.lua
--
-- Parser for the Note Block Studio (.nbs) HEADER section, covering the legacy
-- v0 layout and the Open Note Block Studio layouts v1..v6.
--
-- FROZEN PUBLIC INTERFACE (other modules depend on this exact shape):
--
--   local reader = require("nbs.reader")
--   local header = require("nbs.header")
--   local h = header.parse(reader.new(bytes))
--
--   header.parse(reader) -> header_table with these EXACT field names:
--     version                  integer 0..6 ; 0 means the legacy format
--     vanilla_instrument_count integer ; index at which custom instruments start
--     song_length              integer, or nil for v1/v2
--     layer_count              integer
--     name, author, original_author, description   strings, BYTE-EXACT
--     midi_filename            string (may be "")
--     tempo_raw                integer ; the raw signed i16 (hundredths of a
--                              tick per second)
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
-- FORMAT DETECTION -----------------------------------------------------------
-- The very first field is an i16.  Two cases:
--   * 0        -> NEW format.  The next byte is the u8 version, then a u8
--                vanilla_instrument_count.
--   * NON-ZERO -> LEGACY v0.  That i16 IS the song length; there is NO version
--                byte and NO vanilla-instrument byte.  version = 0,
--                format = "legacy", vanilla_instrument_count = 10.
--
-- FIELD ORDER ----------------------------------------------------------------
-- NEW format (v1..v6), immediately after the version byte:
--   u8  vanilla_instrument_count
--   i16 song_length        -- ONLY when version >= 3
--   i16 layer_count
--   str name
--   str author
--   str original_author
--   str description
--   i16 tempo_raw
--   u8  autosave
--   u8  autosave_duration
--   u8  time_signature
--   i32 minutes_spent
--   i32 left_clicks
--   i32 right_clicks
--   i32 blocks_added
--   i32 blocks_removed
--   str midi_filename
--   u8  loop               -- ONLY when version >= 4
--   u8  max_loop_count     -- ONLY when version >= 4
--   i16 loop_start_tick    -- ONLY when version >= 4
-- (No song_length for v1/v2 -> that field is nil.  The real length is derived
-- later from the notes section by a different module; this parser never does.)
--
-- LEGACY v0, immediately after the first i16 (which was the song length):
--   i16 layer_count
--   str name / author / original_author / description
--   i16 tempo_raw
--   u8  autosave / autosave_duration / time_signature
--   i32 minutes_spent / left_clicks / right_clicks / blocks_added / blocks_removed
--   str midi_filename
-- (Legacy has no loop fields.)
--
-- SIGNED-INT16 WRAPAROUND -----------------------------------------------------
-- song_length is stored as a signed i16 but a long song can exceed 32767 ticks,
-- so the value is stored wrapped into the negative range and must be
-- reconstructed.  This mirrors the reference parser OpenNBS/nbs.js
-- (src/formats/binary/BinaryReader.ts, processHeader):
--
--     const difference = -1 * (BufferReader.MIN_SHORT - size) + 2;
--     size = BufferReader.MAX_SHORT + difference;
--
-- where nbs.js defines MIN_SHORT = -32767 and MAX_SHORT = 32767
-- (src/buffer/wrapper.ts).  Algebraically that is exactly the UNSIGNED
-- reinterpretation, size + 65536, i.e. the "intended unsigned value":
--   raw 0x8000 (-32768) -> 32768
--   raw 0xFFFF (-1)     -> 65535
-- The reconstruction is applied on BOTH the legacy path and the new-format
-- v3+ path, and is NOT applied to loop_start_tick.
--
-- ERRORS ----------------------------------------------------------------------
--   * Overruns are NOT caught here: they propagate from nbs.reader unchanged as
--     a table { code = "E_TRUNCATED", ... }.
--   * A version byte greater than 6 raises a TYPED ERROR TABLE
--     { code = "E_UNSUPPORTED_VERSION", msg = <string>, version = <n> } via
--     error(tbl, 0), and parsing stops immediately.
--   * A NEGATIVE layer_count raises a TYPED ERROR TABLE
--     { code = "E_BAD_LAYER_COUNT", msg = <string>, layer_count = <n>,
--       version = <n> } via error(tbl, 0), and parsing stops immediately.
--     layer_count is spec-faithfully a signed i16, so a raw count >= 32768
--     wraps negative; such a count is impossible for a real file and is
--     rejected here rather than accepted (a negative count would make
--     layers.parse's `layer_count > remaining` guard false, run zero
--     iterations, and let the corrupt file decode as a success).  The code is
--     the SAME one layers.parse already raises for an unsustainable count, so
--     callers branch on a single consistent `.code`.
--
-- Lua 5.2 / Cobalt constraints honoured here: no `//`, no bitwise operators, no
-- math.maxinteger, no collectgarbage, no string.dump, no os.exit, no utf8.*.
-- Only plain arithmetic, string.char and the reader are used.

local header = {}

-- nbs.js BufferWrapper constants (see the wraparound note above).  Note that
-- MIN_SHORT is deliberately -32767, not -32768: together with the "+ 2" term in
-- the formula it makes the reconstruction the exact unsigned reinterpretation.
local MIN_SHORT = -32767
local MAX_SHORT = 32767

-- Raise the frozen unsupported-version error.  Raised as a TABLE so the decoded
-- `.code` survives pcall; level 0 keeps the error position at the caller.
local function unsupported_version(version)
  error({
    code = "E_UNSUPPORTED_VERSION",
    msg = string.format(
      "unsupported NBS version %d (supported range: 0..6, where 0 is the legacy format)",
      version),
    version = version,
  }, 0)
end

-- Reconstruct a wrapped signed i16 song length into its intended unsigned tick
-- count.  Identical shape to nbs.js, so the intent is auditable side by side.
local function reconstruct_song_length(value)
  if value < 0 then
    local difference = -1 * (MIN_SHORT - value) + 2
    return MAX_SHORT + difference
  end
  return value
end

-- header.parse(reader) -> header_table
--
-- Consumes exactly the header fields from `reader`; the cursor is left at the
-- first byte of the notes section.  See the module header for the frozen shape.
function header.parse(r)
  -- Format detection --------------------------------------------------------
  local first = r:i16()

  local version
  local vanilla_instrument_count
  local format
  local song_length

  if first == 0 then
    -- NEW format (v1..v6): the next byte is the version.
    version = r:u8()
    if version > 6 then
      unsupported_version(version)
    end
    format = "new"
    vanilla_instrument_count = r:u8()
    if version >= 3 then
      song_length = reconstruct_song_length(r:i16())
    else
      -- v1 and v2 do not store a length; it is derived later from the notes.
      song_length = nil
    end
  else
    -- LEGACY v0: the first i16 already was the (possibly wrapped) song length.
    version = 0
    format = "legacy"
    vanilla_instrument_count = 10
    song_length = reconstruct_song_length(first)
  end

  -- Fields shared by both layouts, in identical order ------------------------
  local layer_count = r:i16()

  -- A negative layer_count is corrupt.  The field is spec-faithfully a SIGNED
  -- i16, so a raw count >= 32768 wraps negative (e.g. 60000 -> -5536,
  -- 65535 -> -1).  Reject it HERE at the point of read: layers.parse's
  -- byte-budget guard is `layer_count > remaining`, which is FALSE for any
  -- negative number, so a negative count would run ZERO iterations and the
  -- whole corrupt file would decode as a success.  Reuse layers.parse's own
  -- typed code so callers see one consistent `.code`.
  if layer_count < 0 then
    error({
      code = "E_BAD_LAYER_COUNT",
      msg = string.format(
        "negative layer_count %d (raw signed i16; corrupt header)",
        layer_count),
      layer_count = layer_count,
      version = version,
    }, 0)
  end

  local name = r:read_string()
  local author = r:read_string()
  local original_author = r:read_string()
  local description = r:read_string()
  local tempo_raw = r:i16()
  local autosave = r:u8()
  local autosave_duration = r:u8()
  local time_signature = r:u8()
  local minutes_spent = r:i32()
  local left_clicks = r:i32()
  local right_clicks = r:i32()
  local blocks_added = r:i32()
  local blocks_removed = r:i32()
  local midi_filename = r:read_string()

  -- Loop metadata exists only from v4; legacy v0 never has it.  When absent
  -- the three fields are nil (not 0) so callers can distinguish "not stored".
  local loop = nil
  local max_loop_count = nil
  local loop_start_tick = nil
  if version >= 4 then
    loop = r:u8()
    max_loop_count = r:u8()
    loop_start_tick = r:i16() -- deliberately NOT reconstructed
  end

  return {
    version = version,
    vanilla_instrument_count = vanilla_instrument_count,
    song_length = song_length,
    layer_count = layer_count,
    name = name,
    author = author,
    original_author = original_author,
    description = description,
    midi_filename = midi_filename,
    tempo_raw = tempo_raw,
    tempo_ticks_per_second = tempo_raw / 100,
    autosave = autosave,
    autosave_duration = autosave_duration,
    time_signature = time_signature,
    minutes_spent = minutes_spent,
    left_clicks = left_clicks,
    right_clicks = right_clicks,
    blocks_added = blocks_added,
    blocks_removed = blocks_removed,
    loop = loop,
    max_loop_count = max_loop_count,
    loop_start_tick = loop_start_tick,
    format = format,
  }
end

return header
