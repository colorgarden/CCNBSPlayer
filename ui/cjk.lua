-- ui/cjk.lua
--
-- THE CJK PIXEL-FONT ADAPTER -- the SINGLE place that knows how to OBTAIN,
-- CACHE and USE a community CJK pixel-font renderer, and the SINGLE place
-- that decides when to fall back to English/ASCII.
--
-- ===========================================================================
-- WHY THIS EXISTS
-- ===========================================================================
-- A stock CC:Tweaked terminal ships NO CJK font, so Chinese glyphs render as
-- garbage.  The community solution is a pixel-font library that draws each
-- glyph as a bitmap through `term.blit`.  This project fetches that library
-- AT RUNTIME rather than vendoring it (see LICENSING), because the repo is
-- GPL-2.0 and the library declares no licence.  This adapter is the only
-- module that talks to it.  `ui/i18n.lua` owns the prose; this module only
-- makes the prose RENDERABLE.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local cjk = require("ui.cjk")
--
--   cjk.RENDERER_URL            -- the renderer source URL
--   cjk.FONT_URLS               -- { ["8px"] = <url>, ["12px"] = <url> }
--   cjk.DEFAULT_SIZE            -- "8px"
--
--   cjk.setup(opts) -> { ok = true,  cached = <boolean>, size = <string>,
--                        ms = <number>, font_bytes = <number> }
--                   |  { ok = false, error = <string>, code = <string> }
--     opts.size       -- "8px" | "12px", default DEFAULT_SIZE
--     opts.cache_dir  -- where to look for / write a cached font
--     opts.use_cache  -- default true
--     opts.fetch      -- INJECTED: function(url, binary)
--     opts.renderer   -- INJECTED: an already-loaded renderer table
--     opts.font_data  -- INJECTED: an already-loaded font table
--     opts.fs         -- INJECTED: {exists, read, write, make_dir, free_space}
--     opts.term       -- INJECTED: terminal seam used by the ASCII fallback
--
--   cjk.available()             -- true only after a successful setup
--   cjk.teardown()              -- forget loaded fonts so memory can be freed
--   cjk.print(str, opts)        -- CJK-aware render; false when it fell back
--   cjk.write(str, opts)        -- same, without a trailing newline
--   cjk.width(str)              -- display columns
--   cjk.info()                  -- { available, size, cached, font_bytes,
--                                    memory_estimate }
--   cjk.to_bimg(str, fg, bg, opts) -> bimg | nil   (PURE: no terminal output)
--
-- Error codes returned from `setup` (never raised):
--   E_BAD_SIZE        an unsupported opts.size
--   E_NO_RENDERER     the renderer could not be fetched or did not load
--   E_NO_FONT         the font could not be fetched
--   E_FONT_LOAD       the font data / injected font_data was not a table
--   E_INTERNAL        the last-resort guard (should be unreachable)
-- A CACHE-WRITE FAILURE IS *NOT* AN ERROR: it is reported as cached = false in
-- a SUCCESSFUL result (see the 1,000,000-byte disk limit below).
--
-- ===========================================================================
-- LICENSING -- NON-NEGOTIABLE
-- ===========================================================================
-- This project is GPL-2.0 and contains ZERO third-party source code.  The
-- renderer and the fonts are fetched onto the USER's machine AT RUNTIME; they
-- are NEVER committed, vendored, embedded or copied into this repository, and
-- none of their source appears in this file.  This module is an ADAPTER that
-- calls their documented public API -- it does not contain or derive their
-- implementation.  No audio code (playAudio / DFPWM / PCM) is involved.
--
-- ===========================================================================
-- SECURITY CONSIDERATION -- READ BEFORE CHANGING ANYTHING
-- ===========================================================================
-- The renderer is fetched as SOURCE TEXT and executed with `load`.  Executing
-- remote code is a real risk, and the renderer library itself then executes
-- the fetched FONT source the same way via `load(content, "=remoteFont", "t",
-- sandbox)`.  That is the documented behaviour of the upstream library and is
-- deliberately NOT changed here: the adapter pins the exact URLs, so the only
-- code executed is the code at those pinned URLs.  No user input is ever fed
-- to `load`.
--
-- ===========================================================================
-- THE HARD CONSTRAINTS THIS MODULE IS BUILT AROUND
-- ===========================================================================
-- 1. DISK.  A CC:Tweaked computer's default disk limit is 1,000,000 bytes and
--    the 8px font SOURCE is 1,681,325 bytes, so caching the font to disk WILL
--    FAIL on a default server.  This module therefore TRIES to cache, TOLERATES
--    the failure, and still works -- a cache-write failure is NEVER a rendering
--    failure; it surfaces as `cached = false` so the caller can warn.
-- 2. DOWNLOAD COST.  With no usable cache the font is fetched every launch.
--    `setup` returns `font_bytes` so the caller can tell the user how big the
--    download about to happen is.
-- 3. LOAD COST.  `load()` on ~1.68 MB of Lua table constructor is slow and the
--    8px table has 22,062 entries (~6 MB in memory once loaded).  The font is
--    therefore loaded AT MOST ONCE per size per session and kept in this
--    module; `teardown()` is the single way to release it.
--
-- ===========================================================================
-- ADOPTED DESIGN DECISIONS (intentional, not oversights)
-- ===========================================================================
-- * DEFAULT TO 8px.  Less than half the download and memory of 12px, and
--   legible for UI text.
-- * TRY TO CACHE, TOLERATE FAILURE, SURFACE IT.  The default disk limit is
--   smaller than the font, so requiring a cache would break every default
--   server.
-- * NEVER RAISE; ALWAYS FALL BACK TO ASCII.  An unusable Chinese font must
--   cost the user Chinese, never the program.  After a failed setup,
--   `cjk.print` still writes plain text via `term.write` and returns false.
-- * THE FONT DOWNLOAD HAPPENS EVERY LAUNCH BY DEFAULT.  The owner explicitly
--   chose this, and the README documents raising `computer_space_limit` as the
--   way to enable caching.  The try-cache-then-fetch order below produces
--   exactly that, so there is deliberately NO branching on a config flag --
--   this is intentional.
--
-- ===========================================================================
-- COMPATIBILITY
-- ===========================================================================
-- Lua 5.2 / CC:Tweaked Cobalt: no `//`, no bitwise operators, no
-- math.maxinteger, no collectgarbage, no string.dump, no os.exit and no
-- utf8.* (UTF-8 is decoded here with plain byte arithmetic).  `term`, `fs`
-- and `http` are read LAZILY inside the default seams, never at module load,
-- so `require("ui.cjk")` succeeds on plain desktop Lua where none exist.

local cjk = {}

-- ---------------------------------------------------------------------------
-- Pinned remote endpoints (source text fetched at runtime; never vendored)
-- ---------------------------------------------------------------------------

cjk.RENDERER_URL = "https://git.liulikeji.cn/xingluo/ComputerCraft-Utf8/"
  .. "raw/branch/main/utf8display/utf8display.lua"

local FONT_BASE = "https://git.liulikeji.cn/xingluo/ComputerCraft-Utf8/"
  .. "raw/branch/main/fonts/"

cjk.FONT_URLS = {
  ["8px"] = FONT_BASE .. "fusion-pixel-8px-proportional-zh_hans.lua",
  ["12px"] = FONT_BASE .. "fusion-pixel-12px-proportional-zh_hans.lua",
}

cjk.DEFAULT_SIZE = "8px"

-- Where a cache lives when the caller passes no `cache_dir`.  Under /lib so it
-- travels with the rest of the runtime.
local DEFAULT_CACHE_DIR = "/lib/ccnbs-font-cache"

-- Documented in-memory sizes once loaded as Lua tables: ~6 MB for 8px and
-- ~10.5 MB for 12px.  These are ESTIMATES exposed for the caller's warnings.
local MEMORY_ESTIMATE = {
  ["8px"] = 6 * 1024 * 1024,
  ["12px"] = 11010048,
}

-- ---------------------------------------------------------------------------
-- Session state -- one font per size, loaded at most once, released by teardown
-- ---------------------------------------------------------------------------

local state = {
  available = false,
  size = cjk.DEFAULT_SIZE,
  cached = false,
  font_bytes = 0,
  renderer = nil,
  font = nil,
  font_name = nil,
  term = nil,
}

-- loaded_fonts[size] = { font = <table>, bytes = <n>, cached = <bool> }
-- Kept so a second setup() with the SAME size reuses the expensive table.
local loaded_fonts = {}

-- ---------------------------------------------------------------------------
-- Lazy global access.  Reading a global that a hostile environment traps must
-- be caught here, not at require time.
-- ---------------------------------------------------------------------------

local function read_global(name)
  local ok, value = pcall(function()
    return _G[name]
  end)
  if ok then
    return value
  end
  return nil
end

local function now_seconds()
  local oslib = read_global("os")
  if type(oslib) == "table" and type(oslib.clock) == "function" then
    local ok, value = pcall(oslib.clock)
    if ok and type(value) == "number" then
      return value
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Default seams (used only when the caller injects nothing)
-- ---------------------------------------------------------------------------

-- function(url, binary) -> { ok = true, data = <string> }
--                        | { ok = false, error = <string> }
local function default_fetch(url, binary)
  local http = read_global("http")
  if type(http) ~= "table" or type(http.get) ~= "function" then
    return { ok = false, error = "HTTP API is unavailable" }
  end

  local called, response, err = pcall(http.get, url, binary)
  if not called or type(response) ~= "table" then
    return { ok = false, error = tostring(err or "http.get failed") }
  end

  local read_ok, data = pcall(response.readAll, response)
  pcall(response.close, response)
  if not read_ok or type(data) ~= "string" or #data == 0 then
    return { ok = false, error = "empty HTTP response" }
  end
  return { ok = true, data = data }
end

-- Normalise whatever the fetch seam returns; a raising seam becomes a result.
local function safe_fetch(fetch, url, binary)
  local called, result = pcall(fetch, url, binary)
  if not called then
    return { ok = false, error = tostring(result) }
  end
  if type(result) ~= "table" then
    return { ok = false, error = "fetch returned no result" }
  end
  if result.ok ~= true then
    return { ok = false, error = result.error or "fetch failed" }
  end
  return { ok = true, data = result.data }
end

local function resolve_fs(opts)
  if type(opts) == "table" and type(opts.fs) == "table" then
    return opts.fs
  end
  local value = read_global("fs")
  if type(value) == "table" then
    return value
  end
  return nil
end

local function resolve_term(opts)
  if type(opts) == "table" and type(opts.term) == "table" then
    return opts.term
  end
  if type(state.term) == "table" then
    return state.term
  end
  local value = read_global("term")
  if type(value) == "table" and type(value.write) == "function" then
    return value
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Remote source loading
-- ---------------------------------------------------------------------------

local function compile_source(source, name)
  if type(source) ~= "string" then
    return nil, "source is not a string"
  end
  local chunk, err = load(source, name, "t")
  if chunk == nil then
    return nil, tostring(err)
  end
  local called, result = pcall(chunk)
  if not called then
    return nil, tostring(result)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- UTF-8 decoding and glyph metrics (no utf8.* library available)
-- ---------------------------------------------------------------------------

-- Decode a byte string into an array of Unicode code points.
local function decode_codepoints(str)
  local codepoints = {}
  local index = 1
  local length = #str
  while index <= length do
    local b1 = string.byte(str, index) or 0
    local codepoint
    if b1 < 0xC0 then
      -- ASCII, or a stray continuation byte: count it as one code point.
      codepoint = b1
      index = index + 1
    elseif b1 < 0xE0 then
      local b2 = string.byte(str, index + 1) or 0
      codepoint = (b1 - 0xC0) * 64 + (b2 - 0x80)
      index = index + 2
    elseif b1 < 0xF0 then
      local b2 = string.byte(str, index + 1) or 0
      local b3 = string.byte(str, index + 2) or 0
      codepoint = ((b1 - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)
      index = index + 3
    else
      local b2 = string.byte(str, index + 1) or 0
      local b3 = string.byte(str, index + 2) or 0
      local b4 = string.byte(str, index + 3) or 0
      codepoint = (((b1 - 0xF0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80)) * 64
        + (b4 - 0x80)
      index = index + 4
    end
    codepoints[#codepoints + 1] = codepoint
  end
  return codepoints
end

-- The number of terminal columns a glyph occupies.  Each character of a glyph
-- row is one blit-encoded pixel / one cell, so the row length IS the width.
-- The space glyph (code point 32) is the documented fallback glyph.
local function glyph_columns(font, codepoint)
  if type(font) ~= "table" then
    return 1
  end
  local glyph = font[codepoint]
  if type(glyph) ~= "table" then
    glyph = font[32]
  end
  if type(glyph) ~= "table" then
    return 1
  end
  local row = glyph[1]
  if type(row) ~= "string" or #row < 1 then
    return 1
  end
  return #row
end

-- ---------------------------------------------------------------------------
-- setup()
-- ---------------------------------------------------------------------------

local function do_setup(raw_opts)
  local opts
  if type(raw_opts) == "table" then
    opts = raw_opts
  else
    opts = {}
  end

  local started = now_seconds()

  -- Remember the terminal seam first, so even a FAILED setup can still fall
  -- back to plain text.
  if type(opts.term) == "table" then
    state.term = opts.term
  end

  local size = opts.size
  if size == nil then
    size = cjk.DEFAULT_SIZE
  end
  if type(size) ~= "string" or cjk.FONT_URLS[size] == nil then
    return {
      ok = false,
      error = "unsupported font size: " .. tostring(size),
      code = "E_BAD_SIZE",
    }
  end

  local fetch = opts.fetch
  if type(fetch) ~= "function" then
    fetch = default_fetch
  end

  -- 1. Renderer: injected, else already loaded this session, else fetched.
  local renderer = nil
  if opts.renderer ~= nil then
    if type(opts.renderer) ~= "table" then
      return {
        ok = false,
        error = "opts.renderer is not a table",
        code = "E_NO_RENDERER",
      }
    end
    renderer = opts.renderer
  elseif type(state.renderer) == "table" then
    renderer = state.renderer
  else
    local fetched = safe_fetch(fetch, cjk.RENDERER_URL, false)
    if not fetched.ok then
      return {
        ok = false,
        error = fetched.error or "renderer fetch failed",
        code = "E_NO_RENDERER",
      }
    end
    local loaded, err = compile_source(fetched.data, "=remoteRenderer")
    if type(loaded) ~= "table" then
      return {
        ok = false,
        error = err or "renderer did not return a table",
        code = "E_NO_RENDERER",
      }
    end
    renderer = loaded
  end

  -- 2. Font: injected, else already loaded for this size, else cache, else
  --    fetched.  Anything loaded from cache or the network is compiled with
  --    `load()` exactly once.
  local cache_dir = opts.cache_dir
  if type(cache_dir) ~= "string" or cache_dir == "" then
    cache_dir = DEFAULT_CACHE_DIR
  end
  local cache_path = cache_dir .. "/font-" .. size .. ".lua"

  local use_cache = opts.use_cache
  if use_cache == nil then
    use_cache = true
  end

  local filesystem = resolve_fs(opts)
  local font = nil
  local font_bytes = 0
  local cached = false

  if opts.font_data ~= nil then
    if type(opts.font_data) ~= "table" then
      return {
        ok = false,
        error = "opts.font_data is not a table",
        code = "E_FONT_LOAD",
      }
    end
    font = opts.font_data
  elseif loaded_fonts[size] ~= nil then
    local record = loaded_fonts[size]
    font = record.font
    font_bytes = record.bytes
    cached = record.cached
  else
    -- 2a. Try the disk cache first (a corrupt entry is just a cache miss).
    if use_cache and type(filesystem) == "table"
      and type(filesystem.exists) == "function" then
      local exists_ok, exists = pcall(filesystem.exists, cache_path)
      if exists_ok and exists then
        local read_ok, data = pcall(filesystem.read, cache_path)
        if read_ok and type(data) == "string" and #data > 0 then
          local loaded = compile_source(data, "=cachedFont")
          if type(loaded) == "table" then
            font = loaded
            font_bytes = #data
            cached = true
          end
        end
      end
    end

    -- 2b. Cache miss: fetch the font source and compile it in memory.
    if font == nil then
      local fetched = safe_fetch(fetch, cjk.FONT_URLS[size], true)
      if not fetched.ok then
        return {
          ok = false,
          error = fetched.error or "font fetch failed",
          code = "E_NO_FONT",
        }
      end
      local loaded, err = compile_source(fetched.data, "=remoteFont")
      if type(loaded) ~= "table" then
        return {
          ok = false,
          error = err or "font did not return a table",
          code = "E_FONT_LOAD",
        }
      end
      font = loaded
      font_bytes = #fetched.data

      -- 2c. Best-effort cache write.  A failure here -- most likely the
      --      default 1,000,000-byte disk limit being smaller than the font --
      --      leaves `cached = false` but MUST NOT fail the setup.
      if use_cache and type(filesystem) == "table" then
        if type(filesystem.make_dir) == "function" then
          pcall(filesystem.make_dir, cache_dir)
        end
        local wrote = false
        if type(filesystem.write) == "function" then
          local write_ok, write_result = pcall(filesystem.write, cache_path,
            fetched.data)
          wrote = write_ok and write_result == true
        end
        cached = wrote
      end
    end
  end

  -- 3. Register the font with the renderer and VERIFY it before any render.
  --    The upstream library auto-loads its font on first use and can RAISE if
  --    that fails, so we always call loadFont ourselves and turn a failure
  --    into a RETURNED error, never an exception.
  local font_name = "ccnbs-" .. size
  if type(renderer.addfonts) == "function" then
    pcall(renderer.addfonts, font_name, "fontData", font)
  end
  if type(renderer.loadFont) == "function" then
    local loaded_ok, loaded_result, loaded_err =
      pcall(renderer.loadFont, font_name)
    if not loaded_ok or loaded_result ~= true then
      return {
        ok = false,
        error = tostring(loaded_err or loaded_result or "loadFont failed"),
        code = "E_FONT_LOAD",
      }
    end
  end

  -- Commit the session state only now that everything succeeded.
  state.renderer = renderer
  state.font = font
  state.font_name = font_name
  state.font_bytes = font_bytes
  state.cached = cached
  state.size = size
  state.available = true

  if loaded_fonts[size] == nil then
    loaded_fonts[size] = { font = font, bytes = font_bytes, cached = cached }
  end

  local ms = 0
  local finished = now_seconds()
  if started ~= nil and finished ~= nil then
    ms = math.floor((finished - started) * 1000)
  end

  return {
    ok = true,
    cached = cached,
    size = size,
    ms = ms,
    font_bytes = font_bytes,
  }
end

-- setup() NEVER raises: the last-resort guard converts even an internal fault
-- into a typed result.
function cjk.setup(opts)
  local called, result = pcall(do_setup, opts)
  if called and type(result) == "table" then
    return result
  end
  return { ok = false, error = tostring(result), code = "E_INTERNAL" }
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function cjk.available()
  return state.available == true
end

-- Forget every loaded font (and the renderer) so their memory can be released.
-- This is also how a session invalidates the "loaded once" cache.
function cjk.teardown()
  state.available = false
  state.renderer = nil
  state.font = nil
  state.font_name = nil
  state.font_bytes = 0
  state.cached = false
  state.term = nil
  state.size = cjk.DEFAULT_SIZE
  loaded_fonts = {}
  return true
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function default_color(getter, fallback)
  local terminal = resolve_term(nil)
  if terminal ~= nil and type(terminal[getter]) == "function" then
    local called, value = pcall(terminal[getter])
    if called and type(value) == "number" then
      return value
    end
  end
  return fallback
end

-- Shared body of print/write.  Returns TRUE when the CJK renderer drew the
-- text, FALSE when it fell back to plain ASCII.
local function render_text(str, opts, method)
  local text = tostring(str)
  local options
  if type(opts) == "table" then
    options = opts
  else
    options = {}
  end

  if state.available and type(state.renderer) == "table" then
    local fg = options.fg
    local bg = options.bg
    if fg == nil then
      fg = default_color("getTextColor", 1)
    end
    if bg == nil then
      bg = default_color("getBackgroundColor", 0)
    end

    local drew = false
    if method == "print" and type(state.renderer.print) == "function" then
      drew = pcall(state.renderer.print, text, fg, bg, state.font_name)
    elseif method == "write" and type(state.renderer.write) == "function" then
      drew = pcall(state.renderer.write, text, fg, bg)
    end
    if drew then
      return true
    end
    -- A raising/failed renderer falls through to the ASCII fallback below.
  end

  local terminal = resolve_term(options)
  if terminal ~= nil and type(terminal.write) == "function" then
    pcall(terminal.write, text)
  end
  return false
end

function cjk.print(str, opts)
  local called, drew = pcall(render_text, str, opts, "print")
  if called and drew == true then
    return true
  end
  return false
end

function cjk.write(str, opts)
  local called, drew = pcall(render_text, str, opts, "write")
  if called and drew == true then
    return true
  end
  return false
end

-- Display width in columns: ASCII counts 1, a CJK glyph counts its cell width
-- from the font.  When the font is unavailable EVERY character counts 1, so
-- layout still works.
function cjk.width(str)
  if type(str) ~= "string" then
    return 0
  end
  local called, value = pcall(function()
    local font = state.font
    local total = 0
    local codepoints = decode_codepoints(str)
    for index = 1, #codepoints do
      local codepoint = codepoints[index]
      if codepoint < 128 or type(font) ~= "table" then
        total = total + 1
      else
        total = total + glyph_columns(font, codepoint)
      end
    end
    return total
  end)
  if called and type(value) == "number" then
    return value
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

function cjk.info()
  local estimate = MEMORY_ESTIMATE[state.size]
  if estimate == nil then
    estimate = MEMORY_ESTIMATE[cjk.DEFAULT_SIZE] or 0
  end
  return {
    available = state.available == true,
    size = state.size,
    cached = state.cached == true,
    font_bytes = state.font_bytes or 0,
    memory_estimate = estimate,
  }
end

-- ---------------------------------------------------------------------------
-- to_bimg() -- the PURE Basalt2 seam
-- ---------------------------------------------------------------------------

-- Convert a string to the `bimg` structure ({ {text, fg, bg}, ... }) that
-- Basalt2's Image:setBimg consumes, by delegating to the renderer's strToBimg.
-- Performs NO terminal output whatsoever.  Returns nil -- never raises -- when
-- no renderer/font is available, so the caller can fall back to an ASCII label.
function cjk.to_bimg(str, fg, bg, opts)
  local called, result = pcall(function()
    if not state.available or type(state.renderer) ~= "table" then
      return nil
    end
    if type(state.renderer.strToBimg) ~= "function" then
      return nil
    end
    local options
    if type(opts) == "table" then
      options = opts
    else
      options = {}
    end
    local width = options.width
    if type(width) ~= "number" then
      width = cjk.width(str)
    end
    return state.renderer.strToBimg(str, fg, bg, width, state.font_name)
  end)
  if called and type(result) == "table" then
    return result
  end
  return nil
end

return cjk
