-- net/zip.lua
--
-- Minimal, from-scratch ZIP reader for CCNBSPlayer -- just enough to pull a
-- single `song.nbs` entry out of the archive Note Block World serves on its
-- anonymous download route.
--
-- WHY THIS EXISTS
-- ---------------
-- The anonymous route returns a ZIP, but this project only ever wants the
-- `song.nbs` inside it.  CC:Tweaked has no ZIP library and this project is
-- relicensed to GPL-2.0 with ZERO third-party source, so the reader is written
-- here from the frozen local-file-header layout rather than copied from
-- anywhere.  Note Block World's own code is AGPL-3.0 and is INCOMPATIBLE with
-- GPL-2.0: it may be CALLED over HTTP, never copied.
--
-- DESIGN
-- ------
-- Entries are discovered by walking LOCAL FILE HEADERS, not the central
-- directory, because a single-pass streaming walk needs no end-of-archive
-- bookkeeping.  Each header is 30 bytes; the walk advances past each entry's
-- data.  All multi-byte fields are little-endian (see u16/u32).
--
-- STORED ONLY
-- -----------
-- Real archives were measured: a song with no custom instruments stores
-- `song.nbs` uncompressed (method 0), and three of four sampled archives with
-- custom instruments also stored it, but ONE used DEFLATE.  This reader
-- supports STORED (a plain byte slice) and REFUSES DEFLATE with the typed code
-- `E_ZIP_COMPRESSED` rather than pretending.  Rationale: pure-Lua inflate is
-- several hundred lines and would be slow on a CC computer for a multi-megabyte
-- entry, while the failure is honest and actionable -- the caller can point the
-- user at the song page.  This is reversible: inflate can be added behind the
-- same interface later.
--
-- DATA DESCRIPTORS
-- ----------------
-- When flag bit 3 is set the local header's compressed/uncompressed sizes are
-- zero and the real values trail the data, so the walker cannot know where the
-- entry ends.  Such an entry is refused with `E_ZIP_DATA_DESCRIPTOR` instead of
-- slicing on a bogus size.  (Bit 3 was not set in any sampled real file, but a
-- robust reader must refuse rather than corrupt.)
--
-- NEVER-RAISE CONTRACT
-- --------------------
-- Both public functions ALWAYS return a table, for every input including nil
-- and malformed buffers.  Every path bounds-checks before it slices, the walk
-- is capped at MAX_ENTRIES so a hostile buffer cannot spin, and each entry
-- point is additionally wrapped in pcall as a belt-and-braces guard.
--
-- Compatible with Lua 5.2 / CC:Tweaked Cobalt: no floor division, no bitwise
-- operators, no goto, no math.maxinteger, no collectgarbage, no string.dump and
-- no os.exit.

local zip = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SIG = "PK\x03\x04"        -- local file header signature
local HEADER_SIZE = 30          -- bytes of a local file header before name
local MAX_ENTRIES = 4096        -- walk guard: refuse absurd entry counts

local E_BAD_ARGS = "E_ZIP_BAD_ARGS"
local E_BAD_SIGNATURE = "E_ZIP_BAD_SIGNATURE"
local E_TRUNCATED = "E_ZIP_TRUNCATED"
local E_COMPRESSED = "E_ZIP_COMPRESSED"
local E_DATA_DESCRIPTOR = "E_ZIP_DATA_DESCRIPTOR"
local E_NOT_FOUND = "E_ZIP_NOT_FOUND"
local E_UNSUPPORTED = "E_ZIP_UNSUPPORTED"
local E_TOO_MANY = "E_ZIP_TOO_MANY"

-- ---------------------------------------------------------------------------
-- Little-endian field readers (nil when the bytes are not present)
-- ---------------------------------------------------------------------------

local function read_u16(data, offset)
  local a, b = data:byte(offset, offset + 1)
  if a == nil or b == nil then
    return nil
  end
  return a + b * 256
end

local function read_u32(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  if a == nil or b == nil or c == nil or d == nil then
    return nil
  end
  return a + b * 256 + c * 65536 + d * 16777216
end

-- ---------------------------------------------------------------------------
-- Result helpers
-- ---------------------------------------------------------------------------

local function failure(message, code)
  return { ok = false, error = message, code = code }
end

-- ---------------------------------------------------------------------------
-- The walker
-- ---------------------------------------------------------------------------
--
-- scan(data) -> { ok = true, entries = { {name, method, compressed, size,
--                                          data_at}, ... } }
--             | { ok = false, error, code }
--
-- `data_at` is the 1-based index of the entry's first data byte; the caller
-- slices `data:sub(data_at, data_at + compressed - 1)`.
--
-- Every offset is checked against #data BEFORE the corresponding bytes are
-- read, so a truncated or hostile buffer can only ever yield a typed error.

local function scan(data)
  if type(data) ~= "string" then
    return failure("zip: data must be a string", E_BAD_ARGS)
  end

  local total = #data
  local entries = {}
  local pos = 1

  while pos + 3 <= total do
    -- A non-signature byte after at least one entry means we reached whatever
    -- follows the last local file (e.g. a central directory); stop cleanly.
    if data:sub(pos, pos + 3) ~= SIG then
      break
    end

    if pos + HEADER_SIZE - 1 > total then
      return failure("zip: local file header at byte " .. tostring(pos)
        .. " is truncated", E_TRUNCATED)
    end

    local flags = read_u16(data, pos + 6)
    local method = read_u16(data, pos + 8)
    local compressed = read_u32(data, pos + 18)
    local size = read_u32(data, pos + 22)
    local name_length = read_u16(data, pos + 26)
    local extra_length = read_u16(data, pos + 28)
    -- All six reads are non-nil: the header fits entirely in the buffer.

    local name_start = pos + HEADER_SIZE
    local name_end = name_start + name_length - 1
    if name_end > total then
      return failure("zip: entry name runs past the end of the buffer",
        E_TRUNCATED)
    end
    local name = data:sub(name_start, name_end)

    -- Bit 3 of the flags (8) marks a data descriptor: the local header sizes
    -- are zero and the real values follow the data.  Arithmetic, not bitwise:
    -- Cobalt has no bit operators.
    if math.floor(flags / 8) % 2 == 1 then
      return failure("zip: entry '" .. name .. "' sets the data-descriptor flag "
        .. "(bit 3); its sizes are not in the local header and the walker cannot "
        .. "know where the data ends", E_DATA_DESCRIPTOR)
    end

    local data_at = name_end + 1 + extra_length
    if data_at - 1 > total then
      return failure("zip: entry '" .. name .. "' extra field runs past the end "
        .. "of the buffer", E_TRUNCATED)
    end

    if compressed > 0 and data_at + compressed - 1 > total then
      local remain = total - data_at + 1
      if remain < 0 then
        remain = 0
      end
      return failure("zip: entry '" .. name .. "' data is truncated (needs "
        .. tostring(compressed) .. " bytes, only " .. tostring(remain)
        .. " remain)", E_TRUNCATED)
    end

    entries[#entries + 1] = {
      name = name,
      method = method,
      compressed = compressed,
      size = size,
      data_at = data_at,
    }

    if #entries > MAX_ENTRIES then
      return failure("zip: more than " .. tostring(MAX_ENTRIES)
        .. " entries; refusing to walk further", E_TOO_MANY)
    end

    pos = data_at + compressed
  end

  if #entries == 0 then
    return failure("zip: no local file header signature found", E_BAD_SIGNATURE)
  end

  return { ok = true, entries = entries }
end

-- ---------------------------------------------------------------------------
-- Public interface
-- ---------------------------------------------------------------------------

local function extract_impl(data, wanted_name)
  if type(wanted_name) ~= "string" or wanted_name == "" then
    return failure("zip: wanted_name must be a non-empty string", E_BAD_ARGS)
  end

  local scanned = scan(data)
  if not scanned.ok then
    return scanned
  end

  local found = nil
  for index = 1, #scanned.entries do
    if scanned.entries[index].name == wanted_name then
      found = scanned.entries[index]
      break
    end
  end

  if found == nil then
    return failure("zip: entry '" .. wanted_name .. "' was not found in the archive",
      E_NOT_FOUND)
  end

  if found.method == 8 then
    return failure("zip: entry '" .. found.name .. "' is DEFLATE-compressed "
      .. "(method 8); only stored (method 0) entries are supported", E_COMPRESSED)
  end

  if found.method ~= 0 then
    return failure("zip: entry '" .. found.name .. "' uses unsupported "
      .. "compression method " .. tostring(found.method), E_UNSUPPORTED)
  end

  -- STORED: the data is a plain slice.  A zero-length entry yields "" (never
  -- nil) because string.sub with i > j returns the empty string.
  return { ok = true, data = data:sub(found.data_at, found.data_at + found.compressed - 1) }
end

local function list_impl(data)
  local scanned = scan(data)
  if not scanned.ok then
    return scanned
  end

  local entries = {}
  for index = 1, #scanned.entries do
    local entry = scanned.entries[index]
    entries[index] = {
      name = entry.name,
      method = entry.method,
      compressed = entry.compressed,
      size = entry.size,
    }
  end
  return { ok = true, entries = entries }
end

-- The public contract: always a table, never an error.
function zip.extract(data, wanted_name)
  local ok, result = pcall(extract_impl, data, wanted_name)
  if ok and type(result) == "table" then
    return result
  end
  return failure("zip: internal error: " .. tostring(result), "E_ZIP_INTERNAL")
end

function zip.list(data)
  local ok, result = pcall(list_impl, data)
  if ok and type(result) == "table" then
    return result
  end
  return failure("zip: internal error: " .. tostring(result), "E_ZIP_INTERNAL")
end

return zip
