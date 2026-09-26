-- ui/ime.lua
--
-- THE CHINESE PINYIN INPUT METHOD for the new UI's search box.
--
-- ===========================================================================
-- WHY THIS EXISTS
-- ===========================================================================
-- A stock CC:Tweaked terminal has NO input method, so a user physically cannot
-- type Chinese into a search box.  The reference project (MPlayer) solves this
-- by asking a REMOTE service: it POSTs the pinyin and receives candidate words
-- back.  This module is that lookup.  It is NOT a local dictionary -- a real
-- dictionary is megabytes and the project's audience accepts the service
-- dependency -- and it does NOT port MPlayer's request/retry plumbing, because
-- this project's own `net/http.lua` already provides retries (3 attempts with
-- linear backoff), timeouts, a bounded read, response lifecycle safety and a
-- never-raise contract.
--
-- ===========================================================================
-- THE ENDPOINT IS A DEFAULT, NOT A CONSTANT
-- ===========================================================================
-- MPlayer reads its IME URL from its settings layer and only FALLS BACK to
-- `http://rime.liulikeji.cn/query`.  Here the address is `ime.DEFAULT_URL`, and
-- `ime.configure({ url = ... })` points it somewhere else with NO edit to this
-- file; `ime.configure({ enabled = false })` turns the whole feature off.  A
-- user behind a blocked host, or when the service dies, needs both.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local ime = require("ui.ime")
--
--   ime.DEFAULT_URL           -- the reference service, as a documented default
--   ime.DEFAULT_LIMIT         -- 7 candidates asked for by default
--   ime.MAX_INPUT_BYTES       -- the input cap (64 bytes); see INPUT HYGIENE
--
--   ime.configure(opts)       -- inject/override; RETURNS a settings snapshot.
--                             --   opts.url          endpoint (nil = keep)
--                             --   opts.enabled      false turns the feature off
--                             --   opts.limit        candidates to ask for
--                             --   opts.http         the http module (net.http)
--                             --   opts.json_encode  function(value) -> string|nil, err
--                             --   opts.json_decode  function(text) -> value|nil, err
--                             --   opts.get          transport seam, passed to http
--                             --   opts.sleep        sleep seam, passed to http
--                             --   ime.configure(nil) RESETS every seam/setting.
--
--   ime.enabled()             -- boolean
--   ime.url()                 -- the endpoint currently in use
--
--   ime.query(pinyin, opts)   -> { ok = true, candidates = { "你", "泥", ... } }
--                             |  { ok = false, code = <E_...>, error = <string> }
--     `opts` (optional) may override, for THIS call only: limit, timeout,
--     max_retries, on_retry, http, json_encode, json_decode, get, sleep.
--
-- ===========================================================================
-- CANDIDATES CONTRACT
-- ===========================================================================
-- `candidates` is ALWAYS a plain array of non-empty strings -- never nil on
-- success, never a nested structure the UI has to dig through, and never with
-- garbage entries: non-string entries and blank strings are dropped.
-- AN EMPTY RESULT IS `{ ok = true, candidates = {} }`, which is DELIBERATELY
-- different from a failure -- the UI must be able to say "no matches" versus
-- "the lookup failed".  Accepted response shapes:
--   * { "candidates": [ "...", ... ] }   (the documented service shape)
--   * [ "...", ... ]                      (a bare JSON array)
-- Anything else is E_IME_SHAPE.
--
-- ===========================================================================
-- TYPED, NAMED FAILURE CODES (never raised)
-- ===========================================================================
--   E_IME_DISABLED     the input method is off (configure{enabled=false})
--   E_IME_INPUT        the pinyin is not a string (no request is made)
--   E_IME_EMPTY        the pinyin is empty/whitespace after trimming
--   E_IME_TOO_LONG     the pinyin exceeds ime.MAX_INPUT_BYTES
--   E_IME_NO_HTTP      no usable http client (no net.http, none injected)
--   E_IME_NO_ENCODER   no usable JSON encoder (e.g. desktop Lua, no textutils)
--   E_IME_REQUEST      the request itself failed; the underlying error is
--                      carried through verbatim in `error`
--   E_IME_NO_DECODER   the response arrived but no JSON decoder exists
--   E_IME_DECODE       the response could not be decoded into a table
--   E_IME_SHAPE        the decoded response had an unexpected shape
--   E_IME_INTERNAL     the last-resort guard (should be unreachable)
--
-- ===========================================================================
-- INPUT HYGIENE
-- ===========================================================================
-- The input is trimmed (leading/trailing whitespace only; internal spaces are
-- preserved, so "ni hao" survives).  A non-string never produces a body.  An
-- empty result of trimming is rejected BEFORE any request.  The input is capped
-- at ime.MAX_INPUT_BYTES = 64 BYTES: a pinyin syllable or a short phrase is far
-- shorter, and an over-long input is REJECTED (E_IME_TOO_LONG) rather than
-- truncated and sent, so the request size can never be driven by caller input.
--
-- ===========================================================================
-- THE SEAM IS THE TRANSPORT, NOT A LIVE `http` CALL
-- ===========================================================================
-- `query` never touches the real global `http` itself.  It builds a request
-- table and hands it to `opts.http` (default: `require("net.http")`), passing
-- the injected `get`/`sleep` seams straight through -- exactly as `net/nbw.lua`
-- does -- so a spec drives the whole module with no network at all.
--
-- WHY A DEFAULT `get` SEAM: net/http's own default transport is GET-only,
-- while the reference protocol is POST.  So when the caller does NOT inject a
-- `get`, this module supplies a small seam that performs the POST via the
-- global `http.post` (falling back to `http.request`) -- read LAZILY, inside
-- the closure -- and passes it to net/http, which still owns retries, backoff,
-- timeouts, the bounded read and the response lifecycle.  An injected `get`
-- always wins and is passed through untouched.
--
-- ===========================================================================
-- COMPATIBILITY
-- ===========================================================================
-- Lua 5.2 / CC:Tweaked Cobalt: no `//`, no bitwise operators, no
-- math.maxinteger, no collectgarbage, no string.dump, no os.exit and no
-- utf8.*.  `textutils`, `http` and `os` are read LAZILY inside the default
-- seams, never at module load, so `require("ui.ime")` succeeds on plain
-- desktop Lua where none of them exist.

local ime = {}

-- ---------------------------------------------------------------------------
-- Documented defaults and bounds
-- ---------------------------------------------------------------------------

-- The reference service MPlayer falls back to.  A DEFAULT, not a constant:
-- override it with ime.configure({ url = ... }).
ime.DEFAULT_URL = "http://rime.liulikeji.cn/query"

ime.DEFAULT_LIMIT = 7

-- A candidate response is a short JSON array; 64 KiB is generous headroom and
-- still bounds memory on a CC computer.
local MAX_RESPONSE_BYTES = 65536

-- 64 bytes: a pinyin syllable or short phrase is far shorter.
ime.MAX_INPUT_BYTES = 64

-- The service is not asked for an unbounded number of candidates.
local MAX_LIMIT = 100

local DEFAULT_TIMEOUT = 10

-- ---------------------------------------------------------------------------
-- Session state (reset in full by ime.configure(nil))
-- ---------------------------------------------------------------------------

local state = {
  url = ime.DEFAULT_URL,
  enabled = true,
  limit = ime.DEFAULT_LIMIT,
  http = nil,          -- nil = lazy require("net.http")
  json_encode = nil,   -- nil = lazy textutils.serializeJSON
  json_decode = nil,   -- nil = lazy textutils.unserializeJSON
  get = nil,           -- nil = the built-in POST transport seam
  sleep = nil,         -- nil = let net.http use its own default (os.sleep)
}

-- ---------------------------------------------------------------------------
-- Small helpers (none of which read a global at load time)
-- ---------------------------------------------------------------------------

local function failure(message, code)
  return {
    ok = false,
    error = tostring(message),
    code = code or "E_IME_INTERNAL",
  }
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- An array is either empty, or has a nonzero length under `#`.  A table with
-- only string keys is NOT an array, so `{ candidates = { a = 1 } }` is caught
-- as an unexpected shape rather than silently reported as "no matches".
local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  if next(value) == nil then
    return true
  end
  return #value > 0
end

local function normalize_limit(value)
  local number = tonumber(value)
  if number == nil then
    return ime.DEFAULT_LIMIT
  end
  number = math.floor(number)
  if number < 1 then
    return 1
  end
  if number > MAX_LIMIT then
    return MAX_LIMIT
  end
  return number
end

-- Read an override from the per-call opts, else from the configured state.
local function option(opts, name)
  if type(opts) == "table" and opts[name] ~= nil then
    return opts[name]
  end
  return state[name]
end

-- ---------------------------------------------------------------------------
-- Default JSON seams (lazy: no global is touched until first use)
-- ---------------------------------------------------------------------------

local function default_encode_fn()
  local textutils = rawget(_G, "textutils")
  if type(textutils) ~= "table" then
    return nil
  end
  local encode = textutils.serializeJSON
  if type(encode) ~= "function" then
    return nil
  end
  return encode
end

local function default_decode_fn()
  local textutils = rawget(_G, "textutils")
  if type(textutils) ~= "table" then
    return nil
  end
  local decode = textutils.unserializeJSON
  if type(decode) ~= "function" then
    return nil
  end
  return decode
end

local function resolve_encoder(opts)
  if type(opts) == "table" and type(opts.json_encode) == "function" then
    return opts.json_encode
  end
  if type(state.json_encode) == "function" then
    return state.json_encode
  end
  return default_encode_fn()
end

local function resolve_decoder(opts)
  if type(opts) == "table" and type(opts.json_decode) == "function" then
    return opts.json_decode
  end
  if type(state.json_decode) == "function" then
    return state.json_decode
  end
  return default_decode_fn()
end

-- Call a user-supplied encoder, absorbing any error it throws.
local function call_encoder(encode, value)
  local ok, result, err = pcall(encode, value)
  if not ok then
    return nil, tostring(result)
  end
  if type(result) ~= "string" then
    return nil, err or ("encoder returned " .. type(result))
  end
  return result
end

-- Call a user-supplied decoder, absorbing any error it throws.  A value that is
-- not a table is "could not be decoded" (E_IME_DECODE), not a shape failure.
local function call_decoder(decode, text)
  local ok, value, err = pcall(decode, text)
  if not ok then
    return false, tostring(value)
  end
  if value == nil then
    return false, err or "decoder returned nil"
  end
  if type(value) ~= "table" then
    return false, "decoded value is not a table"
  end
  return true, value
end

-- ---------------------------------------------------------------------------
-- HTTP seam resolution
-- ---------------------------------------------------------------------------

local function resolve_http(opts)
  if type(opts) == "table" and type(opts.http) == "table" then
    return opts.http
  end
  if type(state.http) == "table" then
    return state.http
  end
  local ok, module = pcall(require, "net.http")
  if ok and type(module) == "table" then
    return module
  end
  return nil
end

-- The built-in POST transport seam.  `net/http.lua` calls `get(url, headers,
-- binary)`; the JSON body is captured in this closure.  The global `http` table
-- is read LAZILY here, never at module load, and every step is guarded so a
-- hostile/absent global degrades to a returned error rather than a raise.
local function make_post_get(body)
  return function(url, headers)
    local ok, response, err = pcall(function()
      local api = rawget(_G, "http")
      if type(api) ~= "table" then
        return nil, "http is unavailable on this computer"
      end
      local post = api.post
      if type(post) ~= "function" then
        post = api.request
      end
      if type(post) ~= "function" then
        return nil, "http.post is unavailable on this computer"
      end
      return post(url, body, headers)
    end)
    if not ok then
      return nil, "http.post failed: " .. tostring(response)
    end
    return response, err
  end
end

-- An injected `get`/`get` from configure always wins; otherwise the built-in
-- POST seam carries the body.
local function resolve_get(opts, body)
  if type(opts) == "table" and type(opts.get) == "function" then
    return opts.get
  end
  if type(state.get) == "function" then
    return state.get
  end
  return make_post_get(body)
end

-- Call the injected http client's `request` exactly once, absorbing any error
-- it throws so the caller always sees a table.
local function call_http(http_module, request)
  local ok, result = pcall(http_module.request, request)
  if not ok then
    return { ok = false, error = "http request raised: " .. tostring(result) }
  end
  if type(result) ~= "table" then
    return { ok = false, error = "http request returned no result table" }
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Response shape
-- ---------------------------------------------------------------------------

-- Find the candidate list in a decoded response.  Returns the list, or
-- nil, <reason> when the shape is unexpected.
local function extract_candidates(value)
  local list
  if value.candidates ~= nil then
    list = value.candidates
  else
    -- A bare JSON array decodes to a table with only integer keys.
    list = value
  end
  if not is_array(list) then
    return nil, "the response does not contain a candidate list"
  end
  return list
end

-- ---------------------------------------------------------------------------
-- query
-- ---------------------------------------------------------------------------

local function query_impl(pinyin, opts)
  local call = (type(opts) == "table") and opts or nil

  -- 1. Disabled?  Short-circuit before anything else.
  if state.enabled ~= true then
    return failure("the input method is disabled", "E_IME_DISABLED")
  end

  -- 2. Input hygiene, all of it BEFORE any transport call.
  if type(pinyin) ~= "string" then
    return failure("pinyin must be a string, got " .. type(pinyin), "E_IME_INPUT")
  end
  local input = trim(pinyin)
  if input == "" then
    return failure("pinyin is empty after trimming", "E_IME_EMPTY")
  end
  if #input > ime.MAX_INPUT_BYTES then
    return failure("pinyin is too long: " .. tostring(#input) .. " bytes, max "
      .. tostring(ime.MAX_INPUT_BYTES), "E_IME_TOO_LONG")
  end

  -- 3. The http client.
  local http_module = resolve_http(call)
  if type(http_module) ~= "table"
    or type(http_module.request) ~= "function" then
    return failure("no usable http client; inject opts.http", "E_IME_NO_HTTP")
  end

  -- 4. Encode the body.
  local encode = resolve_encoder(call)
  if type(encode) ~= "function" then
    return failure("no usable JSON encoder; inject opts.json_encode",
      "E_IME_NO_ENCODER")
  end
  local limit = normalize_limit(option(call, "limit"))
  local body, encode_error = call_encoder(encode, { input = input, limit = limit })
  if type(body) ~= "string" then
    return failure("could not encode the request body: " .. tostring(encode_error),
      "E_IME_NO_ENCODER")
  end

  -- 5. Build the request.  `method` and `body` are what a POST-capable
  --    transport consumes; the injected seams are passed straight through.
  local request = {
    url = state.url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Accept"] = "application/json",
    },
    body = body,
    binary = false,
    max_bytes = MAX_RESPONSE_BYTES,
    get = resolve_get(call, body),
  }
  local sleep_fn = option(call, "sleep")
  if type(sleep_fn) == "function" then
    request.sleep = sleep_fn
  end
  if type(call) == "table" then
    if type(call.timeout) == "number" and call.timeout > 0 then
      request.timeout = call.timeout
    end
    if type(call.max_retries) == "number" and call.max_retries >= 0 then
      request.max_retries = math.floor(call.max_retries)
    end
    if type(call.on_retry) == "function" then
      request.on_retry = call.on_retry
    end
  end

  local response = call_http(http_module, request)
  if response.ok ~= true then
    -- Carry the transport's own error through verbatim.
    return failure(response.error or "the input method request failed",
      "E_IME_REQUEST")
  end

  -- 6. Decode.
  local decode = resolve_decoder(call)
  if type(decode) ~= "function" then
    return failure("no usable JSON decoder; inject opts.json_decode",
      "E_IME_NO_DECODER")
  end
  local decoded, values = call_decoder(decode, response.body)
  if not decoded then
    return failure("could not decode the response: " .. tostring(values),
      "E_IME_DECODE")
  end

  -- 7. Shape.
  local list, shape_error = extract_candidates(values)
  if list == nil then
    return failure(shape_error, "E_IME_SHAPE")
  end

  -- 8. Map to a flat array of non-empty strings (drop garbage).
  local candidates = {}
  for index = 1, #list do
    local item = list[index]
    if type(item) == "string" then
      local text = trim(item)
      if text ~= "" then
        candidates[#candidates + 1] = text
      end
    end
  end

  return { ok = true, candidates = candidates }
end

-- query NEVER raises: the last-resort guard converts even an internal fault
-- into a typed result.
function ime.query(pinyin, opts)
  local ok, result = pcall(query_impl, pinyin, opts)
  if ok and type(result) == "table" then
    return result
  end
  return failure("internal error: " .. tostring(result), "E_IME_INTERNAL")
end

-- ---------------------------------------------------------------------------
-- configure / accessors
-- ---------------------------------------------------------------------------

local function snapshot()
  return {
    url = state.url,
    enabled = state.enabled,
    limit = state.limit,
  }
end

-- ime.configure(nil) resets EVERY seam and setting to its default, so a test
-- (or the UI) can restore clean state symmetrically.  Values of the wrong type
-- are ignored rather than raising, keeping the never-raise contract.
function ime.configure(opts)
  if opts == nil then
    state.url = ime.DEFAULT_URL
    state.enabled = true
    state.limit = ime.DEFAULT_LIMIT
    state.http = nil
    state.json_encode = nil
    state.json_decode = nil
    state.get = nil
    state.sleep = nil
    return snapshot()
  end
  if type(opts) ~= "table" then
    return snapshot()
  end

  if type(opts.url) == "string" and opts.url ~= "" then
    state.url = opts.url
  end
  if type(opts.enabled) == "boolean" then
    state.enabled = opts.enabled
  end
  if type(opts.limit) == "number" and opts.limit >= 1 then
    state.limit = normalize_limit(opts.limit)
  end
  if type(opts.http) == "table" then
    state.http = opts.http
  end
  if type(opts.json_encode) == "function" then
    state.json_encode = opts.json_encode
  end
  if type(opts.json_decode) == "function" then
    state.json_decode = opts.json_decode
  end
  if type(opts.get) == "function" then
    state.get = opts.get
  end
  if type(opts.sleep) == "function" then
    state.sleep = opts.sleep
  end

  return snapshot()
end

function ime.enabled()
  return state.enabled == true
end

function ime.url()
  return state.url
end

return ime
