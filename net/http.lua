-- net/http.lua
--
-- Shared HTTP download helper for CCNBSPlayer.
--
-- This module is intentionally licence-clean: it is written from scratch for
-- this project (GPL-2.0, no third-party code) and adds no dependency.
--
-- WHY THIS EXISTS
-- ---------------
-- The song installer has to fetch files from a remote host.  A download can
-- fail (transient network error), be hostile (an unexpectedly huge or endless
-- response) or be truncated (fewer bytes than promised).  Faults must never
-- crash the calling computer: a CC:Tweaked computer is memory-constrained and
-- has a limited number of concurrent requests, so both leaked responses and
-- unbounded buffers are real hazards.  What follows is the module that turns
-- those hazards into ordinary `{ ok = false, ... }` tables.
--
-- INJECTABLE-SEAM DESIGN
-- ----------------------
-- `http.request(opts)` never calls the real global `http` itself.  The actual
-- transport is the injected seam `opts.get(url, headers, binary) -> response,
-- err`, and the wait between retries is the injected seam
-- `opts.sleep(seconds)`.  Both default to thin wrappers around the live
-- CC:Tweaked facilities, and the default `get` reads the global `http` table
-- LAZILY inside the closure -- never at module load -- so this file is
-- `require`-able in plain desktop Lua (where no `http` global exists) and is
-- driven in tests with fakes, with no real network and no real sleeping.
--
-- BOUNDED-READ RATIONALE
-- ----------------------
-- `opts.max_bytes` is the key safety property.  It is checked BEFORE a byte is
-- accumulated:
--   * If the response advertises a `Content-Length` above the limit we fail
--     immediately and never read the body at all.
--   * Otherwise the body is pulled in fixed-size chunks (CHUNK_SIZE) and the
--     read is aborted the moment the accumulated size would exceed the limit.
-- A lying or absent `Content-Length` therefore cannot make us buffer a huge
-- response: memory grows only up to roughly the limit plus one chunk.
--
-- NEVER-RAISE CONTRACT
-- --------------------
-- `http.request` ALWAYS returns a table, for every input, including malformed
-- `opts`.  Every fallible operation (the seam call, each `read`, `close`,
-- `getResponseCode`, `getResponseHeaders`, the user callbacks) is guarded, and
-- the whole body is wrapped in `pcall`.  A caller can rely on
-- `local result = http.request(opts)` without its own error handling.
--
-- RESPONSE LIFECYCLE
-- ------------------
-- Every response that is obtained is `close()`d on EVERY path -- success,
-- status failure, oversize rejection, read error and short body alike -- using
-- a once-only guard, because a leaked response consumes one of the computer's
-- scarce concurrent-request slots.
--
-- Compatible with Lua 5.2 / CC:Tweaked Cobalt: no floor division, no bitwise
-- operators, no goto, no math.maxinteger, no collectgarbage, no string.dump
-- and no os.exit.

local http = {}

-- Bytes pulled per `read(n)` call.  Small enough that a single chunk is cheap,
-- large enough that normal downloads are not dominated by call overhead.
http.CHUNK_SIZE = 8192

-- Base delay (seconds) between retries; grows linearly with the attempt index.
http.BACKOFF_BASE = 0.25

local DEFAULT_MAX_RETRIES = 3
local DEFAULT_TIMEOUT = 15

-- ---------------------------------------------------------------------------
-- Small guarded helpers
-- ---------------------------------------------------------------------------

local function to_number(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

-- Case-insensitive header lookup, because builds differ on capitalisation.
local function header_lookup(headers, name)
  if type(headers) ~= "table" then
    return nil
  end
  local target = string.lower(name)
  for key, value in pairs(headers) do
    if type(key) == "string" and string.lower(key) == target then
      return value
    end
  end
  return nil
end

-- Read `Content-Length` if the response advertises one.  Returns a number or
-- nil; a non-numeric or negative value is treated as "not advertised".
local function content_length(headers)
  local raw = header_lookup(headers, "content-length")
  local value = to_number(raw)
  if value == nil or value < 0 then
    return nil
  end
  return value
end

-- A response's own method may be missing (older builds) or may raise; both
-- cases must degrade to "unknown" rather than crash.
local function guarded_method(response, name)
  local method
  local ok = pcall(function()
    method = response[name]
  end)
  if not ok or type(method) ~= "function" then
    return nil
  end
  return method
end

local function safe_close(response)
  if response == nil then
    return
  end
  local close = guarded_method(response, "close")
  if close == nil then
    return
  end
  pcall(close, response)
end

local function safe_code(response)
  local method = guarded_method(response, "getResponseCode")
  if method == nil then
    return nil
  end
  local ok, value = pcall(method, response)
  if not ok or type(value) ~= "number" then
    return nil
  end
  return value
end

local function safe_headers(response)
  local method = guarded_method(response, "getResponseHeaders")
  if method == nil then
    return nil
  end
  local ok, value = pcall(method, response)
  if not ok or type(value) ~= "table" then
    return nil
  end
  return value
end

-- Call the injected (or default) transport seam, absorbing any error it throws
-- so the never-raise contract holds even for a misbehaving seam.
local function call_get(get, url, headers, binary)
  local ok, response, err = pcall(get, url, headers, binary)
  if not ok then
    return nil, "http.get failed: " .. tostring(response)
  end
  if response == nil then
    if err == nil then
      return nil, "http.get returned no response"
    end
    return nil, tostring(err)
  end
  return response, err
end

-- ---------------------------------------------------------------------------
-- Default seams
-- ---------------------------------------------------------------------------

-- Lazy default transport.  The global `http` table is read HERE, inside the
-- closure, so module load never depends on it.  `rawget` avoids triggering a
-- hostile metatable, and the indexing itself is guarded.
local function default_get(url, headers, binary)
  local ok, response, err = pcall(function()
    local api = rawget(_G, "http")
    if type(api) ~= "table" then
      return nil, "http is unavailable on this computer"
    end
    local get = api.get
    if type(get) ~= "function" then
      return nil, "http.get is unavailable on this computer"
    end
    return get(url, headers, binary)
  end)
  if not ok then
    return nil, "http.get failed: " .. tostring(response)
  end
  return response, err
end

-- `os.sleep` is not part of stock Lua 5.2, so it must be probed lazily and
-- tolerated when absent (the helper simply does not wait).
local function default_sleep(seconds)
  local sleep = os and os.sleep
  if type(sleep) == "function" then
    sleep(seconds)
  end
end

-- ---------------------------------------------------------------------------
-- Option normalisation (never raises: malformed values fall back to defaults)
-- ---------------------------------------------------------------------------

local function failure(message, code, retries, bytes)
  return {
    ok = false,
    error = tostring(message),
    code = code,
    retries = retries or 0,
    bytes = bytes or 0,
  }
end

local function normalize(opts)
  local binary = opts.binary
  if type(binary) ~= "boolean" then
    binary = true
  end

  local max_retries = to_number(opts.max_retries)
  if max_retries == nil or max_retries < 0 then
    max_retries = DEFAULT_MAX_RETRIES
  else
    max_retries = math.floor(max_retries)
  end

  local timeout = to_number(opts.timeout)
  if timeout == nil or timeout <= 0 then
    timeout = DEFAULT_TIMEOUT
  end

  local min_bytes = to_number(opts.min_bytes)
  if min_bytes == nil or min_bytes < 0 then
    min_bytes = 0
  end

  local max_bytes = to_number(opts.max_bytes)
  if max_bytes == nil or max_bytes <= 0 then
    max_bytes = nil
  end

  local sleep = opts.sleep
  if type(sleep) ~= "function" then
    sleep = default_sleep
  end

  local get = opts.get
  if type(get) ~= "function" then
    get = default_get
  end

  local on_retry = opts.on_retry
  if type(on_retry) ~= "function" then
    on_retry = nil
  end

  local on_progress = opts.on_progress
  if type(on_progress) ~= "function" then
    on_progress = nil
  end

  return {
    url = opts.url,
    headers = (type(opts.headers) == "table") and opts.headers or nil,
    binary = binary,
    max_retries = max_retries,
    timeout = timeout,
    min_bytes = min_bytes,
    max_bytes = max_bytes,
    sleep = sleep,
    get = get,
    on_retry = on_retry,
    on_progress = on_progress,
  }
end

-- ---------------------------------------------------------------------------
-- A single attempt
-- ---------------------------------------------------------------------------
--
-- Returns a success table, or an internal outcome table:
--   { ok = false, error, code, retryable, bytes }
-- `retryable = false` marks failures for which another identical attempt is
-- pointless (an oversize response will not shrink, so we stop immediately).

local function attempt(cfg)
  local response, err = call_get(cfg.get, cfg.url, cfg.headers, cfg.binary)
  if response == nil then
    return { ok = false, error = err, code = nil, retryable = true, bytes = 0 }
  end

  if type(response) ~= "table" then
    safe_close(response)
    return {
      ok = false,
      error = "invalid http response object",
      code = nil,
      retryable = true,
      bytes = 0,
    }
  end

  -- Once-only close guard: EVERY exit below goes through it.
  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    safe_close(response)
  end

  local code = safe_code(response)
  local headers = safe_headers(response)

  -- A non-2xx status is a failure.  With no getResponseCode we cannot tell, so
  -- the response is treated as OK (guard for older builds).
  if code ~= nil and (code < 200 or code >= 300) then
    close()
    return {
      ok = false,
      error = "HTTP " .. tostring(code) .. " for " .. tostring(cfg.url),
      code = code,
      retryable = true,
      bytes = 0,
    }
  end

  local declared = content_length(headers)

  -- Oversize is decided BEFORE reading a single byte when the length is known.
  if cfg.max_bytes ~= nil and declared ~= nil and declared > cfg.max_bytes then
    close()
    return {
      ok = false,
      error = "response Content-Length " .. tostring(declared)
        .. " exceeds max_bytes " .. tostring(cfg.max_bytes),
      code = code,
      retryable = false,
      bytes = 0,
    }
  end

  local read = guarded_method(response, "read")
  local read_all = guarded_method(response, "readAll")
  if read == nil and read_all == nil then
    close()
    return {
      ok = false,
      error = "http response is not readable",
      code = code,
      retryable = true,
      bytes = 0,
    }
  end

  local parts = {}
  local total = 0

  if read ~= nil then
    -- Bounded chunked read: this is what makes max_bytes meaningful.
    while true do
      local ok, chunk = pcall(read, response, http.CHUNK_SIZE)
      if not ok then
        close()
        return {
          ok = false,
          error = "http read failed: " .. tostring(chunk),
          code = code,
          retryable = true,
          bytes = total,
        }
      end
      if chunk == nil or chunk == "" then
        break
      end
      if type(chunk) ~= "string" then
        close()
        return {
          ok = false,
          error = "http read returned a non-string chunk",
          code = code,
          retryable = true,
          bytes = total,
        }
      end
      if cfg.max_bytes ~= nil and (total + #chunk) > cfg.max_bytes then
        -- Refuse the offending chunk: the full body is never accumulated.
        close()
        return {
          ok = false,
          error = "response exceeds max_bytes " .. tostring(cfg.max_bytes),
          code = code,
          retryable = false,
          bytes = total,
        }
      end
      total = total + #chunk
      parts[#parts + 1] = chunk
      if cfg.on_progress ~= nil then
        pcall(cfg.on_progress, total, declared)
      end
    end
  else
    -- Fallback for exotic responses with only readAll: still honour max_bytes
    -- on the returned buffer (the read itself is inherently unbounded).
    local ok, chunk = pcall(read_all, response)
    if not ok then
      close()
      return {
        ok = false,
        error = "http readAll failed: " .. tostring(chunk),
        code = code,
        retryable = true,
        bytes = 0,
      }
    end
    if type(chunk) == "string" and chunk ~= "" then
      if cfg.max_bytes ~= nil and #chunk > cfg.max_bytes then
        close()
        return {
          ok = false,
          error = "response exceeds max_bytes " .. tostring(cfg.max_bytes),
          code = code,
          retryable = false,
          bytes = 0,
        }
      end
      total = #chunk
      parts[1] = chunk
      if cfg.on_progress ~= nil then
        pcall(cfg.on_progress, total, declared)
      end
    end
  end

  local body = table.concat(parts)
  close()

  if total < cfg.min_bytes then
    return {
      ok = false,
      error = "body too short: got " .. tostring(total)
        .. " bytes, need at least " .. tostring(cfg.min_bytes)
        .. " (min_bytes)",
      code = code,
      retryable = true,
      bytes = total,
    }
  end

  return {
    ok = true,
    body = body,
    code = code,
    headers = headers,
    bytes = #body,
  }
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

local function run(opts)
  if type(opts) ~= "table" then
    return failure("opts must be a table", nil, 0, 0)
  end
  if type(opts.url) ~= "string" or opts.url == "" then
    return failure("opts.url must be a non-empty string", nil, 0, 0)
  end

  local cfg = normalize(opts)
  local max_attempts = 1 + cfg.max_retries
  local retries_done = 0
  local last = failure("request never ran", nil, 0, 0)

  for attempt_index = 1, max_attempts do
    local outcome = attempt(cfg)
    if outcome.ok then
      return outcome
    end
    last = outcome

    if outcome.retryable and attempt_index < max_attempts then
      retries_done = retries_done + 1
      if cfg.on_retry ~= nil then
        pcall(cfg.on_retry, attempt_index, max_attempts, outcome.error)
      end
      pcall(cfg.sleep, http.BACKOFF_BASE * attempt_index)
    else
      break
    end
  end

  return failure(last.error, last.code, retries_done, last.bytes)
end

-- The public contract: always a table, never an error.
function http.request(opts)
  local ok, result = pcall(run, opts)
  if ok and type(result) == "table" then
    return result
  end
  return failure("internal error: " .. tostring(result), nil, 0, 0)
end

return http
