-- nbs/decode.lua
--
-- WHOLE-FILE decode boundary for Note Block Studio (.nbs) songs.
--
-- This is the single place that composes the four section parsers in file
-- order, catches every error they can raise, and guarantees that the player
-- can never crash or hang on a hostile or corrupt file.
--
-- FROZEN PUBLIC INTERFACE
--   local decode = require("nbs.decode")
--
--   decode.decode(bytes) -> { ok = true,  song = <song> }
--                        | { ok = false, error = { code, msg, ... } }
--
--   decode.decode NEVER raises and NEVER hangs.  A non-table error (e.g. a
--   plain string raised by a bug in this file) is normalised to
--   { code = "E_INTERNAL", msg = tostring(err) }.  A typed TABLE error raised by
--   a section parser via error(tbl, 0) is passed through unchanged, so its
--   `.code`, `.msg` and any extra fields (such as `.offset`) are preserved --
--   the error is never swallowed into a fixed generic message.
--
--   song = {
--     header             = <nbs.header.parse result>
--     layers             = <nbs.layers.parse result>
--     notes              = <bare array of note records>
--     custom_instruments = <nbs.instruments_custom.parse result>
--     song_length        = <effective length, integer>
--     song_length_source = "header" | "notes" | "empty"
--   }
--
-- COMPOSITION ORDER (the on-disk layout)
--   header.parse(r)                              -- leaves cursor at notes
--   notes.parse(r, header.version)               -- leaves cursor at layers
--   layers.parse(r, header.version, layer_count)
--   instruments_custom.parse(r, header.version)  -- tolerates absent/EOF
--
--   The SAME cursor is threaded through all four calls so it advances
--   monotonically over one buffer.  instrument_custom's section is optional:
--   an exhausted cursor yields an empty array.
--
-- EFFECTIVE SONG LENGTH
--   * header.song_length is non-nil for v0 (legacy) and v3..v6; v1/v2 store no
--     length and leave it nil.
--   * When it is nil, fall back to the notes-derived length
--     (highest note tick + 1), or 0 with source "empty" when there are no
--     notes either.
--   * RECONSTRUCT-IF-SHORTER: the stored header field is documented as
--     advisory and can be stale.  A wrapped signed i16 also reads back small
--     (see nbs/header.lua).  When the notes on disk prove the song is longer
--     than the header claims, the bytes win: use the notes-derived value and
--     report source "notes".  Otherwise the stored value is authoritative.
--
-- BOUNDED RUNTIME (anti-hang guarantee)
--   * A byte-budget pre-check rejects any input shorter than MIN_HEADER_BYTES
--     before a cursor is built.
--   * Every section parser only advances the cursor (every read consumes
--     bytes), a negative jump is rejected immediately, the note loop is capped
--     by the remaining byte count and by a tick ceiling, and the layers /
--     custom-instrument counts are rejected before any allocation.  Parse time
--     is therefore linear in the input size and every malformed file is
--     rejected well under one second.
--   * After composition the consumed cursor position is sanity-checked.
--
-- ERROR CODES surfaced (all defined inside the sections; no parallel set here):
--   E_TRUNCATED, E_UNSUPPORTED_VERSION, E_BAD_JUMP, E_LAYER_OVERFLOW,
--   E_TOO_MANY_TICKS, E_BAD_LAYER_COUNT, E_BAD_INSTRUMENT_COUNT, E_BAD_TEMPO,
--   E_INTERNAL.
--   E_BAD_TEMPO is raised by header.parse when the stored tempo is <= 0 (a
--   corrupt header); it reaches callers through the pass-through pcall below
--   unchanged, exactly like the other section-parser table errors.
--
-- Lua 5.2 / Cobalt constraints honoured: no `//`, no bitwise operators, no
-- utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.

local reader = require("nbs.reader")
local header = require("nbs.header")
local notes = require("nbs.notes")
local layers = require("nbs.layers")
local instruments_custom = require("nbs.instruments_custom")

local decode = {}

-- Minimum on-disk size of any complete NBS header.  The legacy v0 layout is the
-- smallest: i16 song_length + i16 layer_count + four empty strings (4*4) +
-- i16 tempo + three u8 + five i32 + one empty string = 49 bytes.  Anything
-- shorter cannot hold a header, so it fails fast as E_TRUNCATED.
local MIN_HEADER_BYTES = 49

-- Build a normalised internal error.
local function internal_error(message)
  return { ok = false, error = { code = "E_INTERNAL", msg = message } }
end

-- Normalise a pcall() failure value.  Typed error tables pass through
-- untouched; anything else (including a table that lacks a usable `.code`) is
-- wrapped as E_INTERNAL so the caller always sees a string `.code`.
local function normalize_error(err)
  if type(err) == "table" then
    if type(err.code) == "string" and err.code ~= "" then
      return err
    end
    local message = type(err.msg) == "string" and err.msg
      or "internal error table without a code"
    return { code = "E_INTERNAL", msg = message }
  end
  return { code = "E_INTERNAL", msg = tostring(err) }
end

-- decode(bytes) -> { ok = true, song = ... } | { ok = false, error = ... }
function decode.decode(bytes)
  if type(bytes) ~= "string" then
    return internal_error("decode expects a byte string, got " .. type(bytes))
  end

  local length = #bytes

  -- Byte-budget sanity check: a header cannot exist in fewer than
  -- MIN_HEADER_BYTES bytes, so reject before building a cursor.
  if length < MIN_HEADER_BYTES then
    return {
      ok = false,
      error = {
        code = "E_TRUNCATED",
        msg = string.format(
          "input is too short to contain an NBS header: %d byte(s), minimum %d",
          length, MIN_HEADER_BYTES),
        offset = 0,
        want = MIN_HEADER_BYTES,
        have = length,
      },
    }
  end

  local r = reader.new(bytes)

  -- Compose the whole file.  Every section parser raises typed tables via
  -- error(tbl, 0); the single pcall below catches them and passes them through.
  local ok, composed = pcall(function()
    local parsed_header = header.parse(r)
    local parsed_notes = notes.parse(r, parsed_header.version)
    local parsed_layers = layers.parse(r, parsed_header.version,
      parsed_header.layer_count)
    local parsed_custom =
      instruments_custom.parse(r, parsed_header.version)

    return {
      header = parsed_header,
      notes = parsed_notes,
      layers = parsed_layers,
      custom_instruments = parsed_custom,
      consumed = r:pos(),
    }
  end)

  if not ok then
    return { ok = false, error = normalize_error(composed) }
  end

  -- Post-composition sanity check: a valid header must have been consumed and
  -- the cursor can never pass the end of the buffer.
  if composed.consumed < MIN_HEADER_BYTES or composed.consumed > length then
    return internal_error(string.format(
      "cursor consumed an implausible %d byte(s) of %d", composed.consumed,
      length))
  end

  -- Effective song length (see the module header for the rationale).
  local header_length = composed.header.song_length
  local notes_length = composed.notes.song_length_from_notes

  local song_length
  local song_length_source

  if header_length == nil then
    if notes_length > 0 then
      song_length = notes_length
      song_length_source = "notes"
    else
      song_length = 0
      song_length_source = "empty"
    end
  elseif notes_length > header_length then
    -- reconstruct-if-shorter: the notes prove the song is longer than the
    -- advisory stored field, so trust the bytes on disk.
    song_length = notes_length
    song_length_source = "notes"
  else
    song_length = header_length
    song_length_source = "header"
  end

  return {
    ok = true,
    song = {
      header = composed.header,
      layers = composed.layers,
      notes = composed.notes.notes,
      custom_instruments = composed.custom_instruments,
      song_length = song_length,
      song_length_source = song_length_source,
    },
  }
end

return decode
