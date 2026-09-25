-- net/nbw.lua
--
-- Note Block World API client for CCNBSPlayer -- search songs, fetch song
-- details, and fetch the raw `.nbs` from the site's anonymous download route.
--
-- LICENCE OBLIGATION (READ THIS)
-- ------------------------------
-- This project is relicensed to GPL-2.0 and contains ZERO third-party source.
-- Note Block World's own source is AGPL-3.0, which is INCOMPATIBLE with
-- GPL-2.0: this module only ever CALLS its public HTTP API; it never copies its
-- code.  The SONGS carry their own licence, independently:
--   * "standard"  -- personal listening only; redistribution and use in
--                    published works are forbidden.
--   * "cc_by_sa"  -- reuse permitted with attribution and share-alike.
-- Half the sampled songs were "standard".  Therefore this module MUST NEVER
-- bundle a song, and `attribution(song)` produces displayable credit text
-- (uploader + song-page link) so the interface can satisfy the attribution
-- obligation.  Callers that persist or redistribute a fetched `.nbs` are
-- responsible for checking `license_label(song.license)` first.
--
-- PURITY / INJECTED SEAMS
-- -----------------------
-- Nothing here touches the network or a JSON library at load time.  Every
-- request goes through `opts.http` (defaulting, lazily, to `net.http`) and every
-- response body is decoded through `opts.json_decode` (defaulting to a thin
-- lazy wrapper over CC:Tweaked's `textutils.unserializeJSON`).  Tests inject
-- fakes and never hit the network.
--
-- TARGET CONSTRAINTS
-- ------------------
-- Cobalt (Lua 5.2 base): no floor division, no bitwise operators, no goto, no
-- math.maxinteger, no collectgarbage, no string.dump, no os.exit, no utf8.*.
-- Arithmetic only.  The shipped `net/zip.lua` uses arithmetic for the ZIP flags
-- bit-3 test for the same reason.
--
-- FUNCTIONS
-- ---------
--   nbw.API_BASE, nbw.SITE_BASE
--   nbw.song_page_url(public_id)  -> string
--   nbw.search(opts)              -> { ok=true, songs=, page=, limit=, total= }
--                                 | { ok=false, error=, code= }
--   nbw.detail(public_id, opts)   -> { ok=true, song= } | { ok=false, error=, code= }
--   nbw.download(public_id, opts) -> { ok=true, data=, via="zip"|"raw" }
--                                 | { ok=false, error=, code= }
--   nbw.license_label(code)       -> string
--   nbw.attribution(song)         -> string
--
-- `download` returns raw bytes and does NOT decode them (the caller owns the
-- decoder) and does NOT write files (the caller owns the filesystem).

local zip = require("net.zip")

local nbw = {}

nbw.API_BASE = "https://api.noteblock.world/v1"
nbw.SITE_BASE = "https://noteblock.world"

-- ---------------------------------------------------------------------------
-- Bounds and allow-lists
-- ---------------------------------------------------------------------------

-- A limit=100 search response is about 67 KB; 256 KiB leaves generous headroom
-- while still bounding memory on a CC computer.
local SEARCH_MAX_BYTES = 262144
local DETAIL_MAX_BYTES = 262144
-- The presigned URL is plain text, a few hundred bytes at most.
local URL_MAX_BYTES = 8192
-- Generous cap for a `.nbs` (largest observed entries are a few MiB).
local SONG_MAX_BYTES = 33554432 -- 32 MiB

local ALLOWED_SORTS = {
  recent = true,
  random = true,
  playCount = true,
  title = true,
  duration = true,
  noteCount = true,
}

local ALLOWED_ORDERS = { asc = true, desc = true }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function failure(message, code)
  return { ok = false, error = tostring(message), code = code or "E_NBW" }
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Percent-encode a query value.  Lua 5.2 patterns are byte-oriented, so each
-- non-unreserved byte is encoded independently (correct for UTF-8 too).
local function url_encode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

local function to_int(value)
  local number = tonumber(value)
  if number == nil then
    return nil
  end
  return math.floor(number)
end

local function clamp(number, low, high)
  if number < low then
    return low
  end
  if number > high then
    return high
  end
  return number
end

-- A publicId is a short alphanumeric key (~10 chars).  Reject anything else so
-- a hostile id cannot rewrite the request path.
local function valid_id(public_id)
  if type(public_id) ~= "string" or public_id == "" then
    return false
  end
  return public_id:match("^[%w_%-]+$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Seam resolution (lazy, never touches the real transport at load)
-- ---------------------------------------------------------------------------

local function resolve_http(opts)
  if type(opts.http) == "table" then
    return opts.http
  end
  local ok, module = pcall(require, "net.http")
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

local function default_json_decode(text)
  if type(text) ~= "string" then
    return nil, "response body is not a string"
  end
  local textutils = rawget(_G, "textutils")
  if type(textutils) ~= "table" then
    return nil, "no JSON decoder is available; inject opts.json_decode"
  end
  local decode = textutils.unserializeJSON
  if type(decode) ~= "function" then
    return nil, "textutils.unserializeJSON is unavailable; inject opts.json_decode"
  end
  local ok, value = pcall(decode, text)
  if not ok then
    return nil, "JSON decode failed: " .. tostring(value)
  end
  return value
end

local function decode_body(opts, body)
  local decode = opts.json_decode
  if type(decode) ~= "function" then
    decode = default_json_decode
  end
  local ok, value, err = pcall(decode, body)
  if not ok then
    return nil, tostring(value)
  end
  if type(value) ~= "table" then
    return nil, err or "decoded JSON is not a table"
  end
  return value
end

-- Call the injected net.http seam exactly once, absorbing any error it throws so
-- the caller always sees a table.
local function call_http(http, request)
  if type(http) ~= "table" then
    return failure("no http client available; inject opts.http", "E_NBW_NO_HTTP")
  end
  local request_fn = http.request
  if type(request_fn) ~= "function" then
    return failure("http client has no request function", "E_NBW_NO_HTTP")
  end
  local ok, result = pcall(request_fn, request)
  if not ok then
    return failure("http request raised: " .. tostring(result), "E_NBW_HTTP")
  end
  if type(result) ~= "table" then
    return failure("http request returned no result table", "E_NBW_HTTP")
  end
  return result
end

-- Public entry points are wrapped in this so they always return a table.
local function guard(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok and type(result) == "table" then
    return result
  end
  return failure("internal error: " .. tostring(result), "E_NBW_INTERNAL")
end

-- ---------------------------------------------------------------------------
-- URL building
-- ---------------------------------------------------------------------------

local function build_search_url(opts, page, limit)
  local parts = {}

  local q = opts.q
  if type(q) == "string" and q ~= "" then
    parts[#parts + 1] = "q=" .. url_encode(q)
  end

  parts[#parts + 1] = "page=" .. tostring(page)
  parts[#parts + 1] = "limit=" .. tostring(limit)

  if type(opts.sort) == "string" and ALLOWED_SORTS[opts.sort] then
    parts[#parts + 1] = "sort=" .. url_encode(opts.sort)
  end
  if type(opts.order) == "string" and ALLOWED_ORDERS[opts.order] then
    parts[#parts + 1] = "order=" .. url_encode(opts.order)
  end
  if type(opts.category) == "string" and opts.category ~= "" then
    parts[#parts + 1] = "category=" .. url_encode(opts.category)
  end
  if type(opts.uploader) == "string" and opts.uploader ~= "" then
    parts[#parts + 1] = "uploader=" .. url_encode(opts.uploader)
  end

  return nbw.API_BASE .. "/song?" .. table.concat(parts, "&")
end

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------

local function search_impl(opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return failure("search opts must be a table", "E_NBW_ARGS")
  end

  local page = to_int(opts.page) or 1
  if page < 1 then
    page = 1
  end
  local limit = clamp(to_int(opts.limit) or 10, 1, 100)

  local http = resolve_http(opts)
  if http == nil then
    return failure("no http client available; inject opts.http", "E_NBW_NO_HTTP")
  end

  local request = {
    url = build_search_url(opts, page, limit),
    headers = { ["Accept"] = "application/json" },
    binary = false,
    max_bytes = SEARCH_MAX_BYTES,
  }
  if opts.timeout ~= nil then
    request.timeout = opts.timeout
  end
  if type(opts.on_retry) == "function" then
    request.on_retry = opts.on_retry
  end

  local response = call_http(http, request)
  if not response.ok then
    return failure(response.error or "search request failed", "E_NBW_HTTP")
  end

  local parsed, decode_error = decode_body(opts, response.body)
  if parsed == nil then
    return failure("could not parse the search response: " .. tostring(decode_error),
      "E_NBW_JSON")
  end

  local songs = parsed.content
  if type(songs) ~= "table" then
    songs = {}
  end

  return {
    ok = true,
    songs = songs,
    page = to_int(parsed.page) or page,
    limit = to_int(parsed.limit) or limit,
    total = to_int(parsed.total) or 0,
  }
end

-- ---------------------------------------------------------------------------
-- detail
-- ---------------------------------------------------------------------------

local function detail_impl(public_id, opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return failure("detail opts must be a table", "E_NBW_ARGS")
  end
  if not valid_id(public_id) then
    return failure("detail requires a non-empty alphanumeric publicId",
      "E_NBW_ARGS")
  end

  local http = resolve_http(opts)
  if http == nil then
    return failure("no http client available; inject opts.http", "E_NBW_NO_HTTP")
  end

  local request = {
    url = nbw.API_BASE .. "/song/" .. public_id,
    headers = { ["Accept"] = "application/json" },
    binary = false,
    max_bytes = DETAIL_MAX_BYTES,
  }
  if opts.timeout ~= nil then
    request.timeout = opts.timeout
  end

  local response = call_http(http, request)
  if not response.ok then
    return failure(response.error or "song detail request failed", "E_NBW_HTTP")
  end

  local parsed, decode_error = decode_body(opts, response.body)
  if parsed == nil then
    return failure("could not parse the song detail: " .. tostring(decode_error),
      "E_NBW_JSON")
  end

  return { ok = true, song = parsed }
end

-- ---------------------------------------------------------------------------
-- download
-- ---------------------------------------------------------------------------
--
-- Two routes:
--   * authenticated raw route (opts.token): GET /song/{id}/download?src=...
--     with `Authorization: Bearer <token>`; CC:Tweaked follows the 302 to the
--     raw `.nbs`, so the body IS the file.  via = "raw".
--   * anonymous route: GET /song/{id}/open with the MANDATORY header
--     `src: downloadButton`; the body is a presigned Backblaze B2 URL (valid
--     ~120 s).  Fetch that URL with binary=true through the SAME seam, then
--     extract `song.nbs`.  via = "zip".

local function download_via_raw(public_id, opts, http)
  local request = {
    url = nbw.API_BASE .. "/song/" .. public_id .. "/download?src=downloadButton",
    headers = { ["Authorization"] = "Bearer " .. opts.token },
    binary = true,
    max_bytes = SONG_MAX_BYTES,
  }
  if opts.timeout ~= nil then
    request.timeout = opts.timeout
  end

  local response = call_http(http, request)
  if not response.ok then
    return failure(response.error or "authenticated download failed", "E_NBW_HTTP")
  end
  if type(response.body) ~= "string" or response.body == "" then
    return failure("authenticated download returned an empty body", "E_NBW_EMPTY")
  end

  return { ok = true, data = response.body, via = "raw" }
end

local function download_via_zip(public_id, opts, http)
  local open_url = nbw.API_BASE .. "/song/" .. public_id .. "/open"
  local open_request = {
    url = open_url,
    headers = { ["src"] = "downloadButton" },
    binary = false,
    max_bytes = URL_MAX_BYTES,
  }
  if opts.timeout ~= nil then
    open_request.timeout = opts.timeout
  end

  local open_response = call_http(http, open_request)
  if not open_response.ok then
    return failure("anonymous download route failed ("
      .. tostring(open_response.error or "unknown error")
      .. "); the mandatory 'src: downloadButton' header was rejected or the "
      .. "/open route is unavailable", "E_NBW_OPEN")
  end

  local presigned = trim(open_response.body)
  if presigned == "" then
    return failure("anonymous download route returned an empty presigned URL",
      "E_NBW_OPEN")
  end

  -- The presigned URL lives on a DIFFERENT host (*.backblazeb2.com); it is
  -- fetched through the same injected seam.
  local zip_response = call_http(http, {
    url = presigned,
    headers = {},
    binary = true,
    max_bytes = SONG_MAX_BYTES,
  })
  if not zip_response.ok then
    return failure(zip_response.error or "presigned ZIP download failed",
      "E_NBW_HTTP")
  end

  local extracted = zip.extract(zip_response.body, "song.nbs")
  if not extracted.ok then
    if extracted.code == "E_ZIP_COMPRESSED" then
      -- ADOPTED DECISION: rather than implement pure-Lua inflate (hundreds of
      -- lines, slow on a CC computer for a multi-megabyte entry), fail clearly
      -- and point at the song page so the user can download another way.
      return failure("this song is stored compressed (DEFLATE) and cannot be "
        .. "fetched without an account; download it another way from "
        .. nbw.song_page_url(public_id), "E_SONG_COMPRESSED")
    end
    return failure("could not extract song.nbs from the downloaded ZIP: "
      .. tostring(extracted.error), "E_NBW_ZIP")
  end

  return { ok = true, data = extracted.data, via = "zip" }
end

local function download_impl(public_id, opts)
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return failure("download opts must be a table", "E_NBW_ARGS")
  end
  if not valid_id(public_id) then
    return failure("download requires a non-empty alphanumeric publicId",
      "E_NBW_ARGS")
  end

  local http = resolve_http(opts)
  if http == nil then
    return failure("no http client available; inject opts.http", "E_NBW_NO_HTTP")
  end

  if type(opts.token) == "string" and opts.token ~= "" then
    return download_via_raw(public_id, opts, http)
  end
  return download_via_zip(public_id, opts, http)
end

-- ---------------------------------------------------------------------------
-- Public interface
-- ---------------------------------------------------------------------------

function nbw.search(opts)
  return guard(search_impl, opts)
end

function nbw.detail(public_id, opts)
  return guard(detail_impl, public_id, opts)
end

function nbw.download(public_id, opts)
  return guard(download_impl, public_id, opts)
end

function nbw.song_page_url(public_id)
  if type(public_id) ~= "string" or public_id == "" then
    return nbw.SITE_BASE
  end
  return nbw.SITE_BASE .. "/song/" .. public_id
end

local LICENSE_LABELS = {
  standard = "Standard - personal listening only; redistribution or use in "
    .. "published works is not permitted.",
  cc_by_sa = "CC BY-SA - reuse is permitted with attribution and share-alike.",
}

function nbw.license_label(code)
  if type(code) == "string" then
    local known = LICENSE_LABELS[code]
    if known ~= nil then
      return known
    end
  end
  return "Unknown license (" .. tostring(code)
    .. ") - treat as all rights reserved."
end

function nbw.attribution(song)
  if type(song) ~= "table" then
    return "Unknown song (no metadata available) - " .. nbw.SITE_BASE
  end

  local title = song.title
  if type(title) ~= "string" or title == "" then
    title = "Untitled"
  end

  local username = "Unknown uploader"
  if type(song.uploader) == "table"
    and type(song.uploader.username) == "string"
    and song.uploader.username ~= "" then
    username = song.uploader.username
  end

  local credit = title .. " by " .. username
  if type(song.originalAuthor) == "string"
    and song.originalAuthor ~= ""
    and song.originalAuthor ~= username then
    credit = credit .. " (original by " .. song.originalAuthor .. ")"
  end

  if type(song.publicId) == "string" and song.publicId ~= "" then
    credit = credit .. " - " .. nbw.song_page_url(song.publicId)
  else
    credit = credit .. " - " .. nbw.SITE_BASE
  end

  return credit
end

return nbw
