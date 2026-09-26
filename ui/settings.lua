-- ui/settings.lua
--
-- THE SETTINGS STORE -- persistence for everything the user can change.
--
-- Modelled on the reference implementation's `src/Settings.lua`: a small JSON
-- store under a directory, one file per concern, loaded once at startup and
-- saved on demand.  The SHAPE differs because our content differs -- there is no
-- NetEase, no login, no lyrics -- but the mechanism is the same.
--
-- ===========================================================================
-- WHY ONE DIRECTORY OF SMALL FILES INSTEAD OF ONE BIG FILE
-- ===========================================================================
-- A single file would have to be rewritten in full on every change, so a crash
-- mid-write could lose EVERY setting.  One file per concern means a corrupt
-- appearance file cannot cost the user their network configuration, and each
-- file is small enough to rewrite atomically.
--
-- ===========================================================================
-- NOTHING HERE EVER RAISES, AND A MISSING FILE IS NOT AN ERROR
-- ===========================================================================
-- A first run has no settings at all, which is the normal case, not a failure.
-- So every loader returns DEFAULTS when the file is absent, and
-- `{ value, error }` when the file exists but cannot be used.  A corrupt file
-- degrades to defaults for that file alone; the caller decides whether to warn.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no math.maxinteger, no collectgarbage, no string.dump, no os.exit, no utf8.*.
-- All globals are read lazily inside seams, so this module is require-able in
-- plain desktop Lua where `fs` and `textutils` do not exist.

local settings = {}

-- Where the files live, relative to the program's directory.
settings.DIRECTORY = "Settings"

-- ---------------------------------------------------------------------------
-- Defaults -- the SINGLE source of truth for every default value
-- ---------------------------------------------------------------------------
-- Every default lives here, so a reader can see the whole configuration in one
-- place, and so a test can assert against the same table the code uses rather
-- than a copy of it.

settings.DEFAULTS = {
  -- Network clients.  Each mirrors the reference project's `{url, timeout,
  -- maxRetries}` shape, because that is what its client library expects.
  api = {
    -- The Note Block World API.  `nbw.API_BASE` is the real owner of this
    -- value; it is repeated here only as the default for the settings file.
    url = "https://api.noteblock.world/v1",
    timeout = 15,
    maxRetries = 3,
  },

  -- The pinyin input method.
  --
  -- A DEFAULT, NOT A CONSTANT: the reference implementation reads this from its
  -- settings layer and only falls back to this address, and the user explicitly
  -- asked for the same ("并非硬编码，在MPlayer设置里可以更改").  So it is editable
  -- in the settings UI and never hard-coded at a call site.
  ime = {
    url = "http://rime.liulikeji.cn/query",
    timeout = 15,
    maxRetries = 3,
    -- Turning this off makes the search box ASCII-only.  It is a real option
    -- because the service is a third party's host and may be unreachable.
    enabled = true,
  },

  -- The updater, which reuses the installer's mirror chain.
  updater = {
    url = "https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main",
    timeout = 30,
    maxRetries = 3,
  },

  -- Which monitor to render on, remembered by peripheral NAME so a monitor can
  -- be moved to another side without losing the setting.
  display = {
    name = nil,
  },

  -- The CJK font.  Not vendored (1.68 MB against a default 1 MB disk limit), so
  -- the URL is configuration: a user with a mirror, or with a raised disk limit,
  -- can point this at a cached copy.
  font = {
    url = "https://git.liulikeji.cn/xingluo/ComputerCraft-Utf8/raw/branch/main"
      .. "/fonts/fusion-pixel-8px-proportional-zh_hans.lua",
    size = "8px",
  },

  -- The 16-colour palette is redefinable, and the reference project ships a dark
  -- theme as seven overrides.  Values are 0xRRGGBB.  `nil` means "leave the
  -- terminal's own colour alone".
  appearance = {
    black = 0x101014,
    gray = 0x18181C,
    lightGray = 0x222226,
    orange = 0x2C2C32,
    magenta = 0x695E61,
    pink = 0x3A3438,
    purple = 0xFFDAD6,
  },

  -- Interface language.  "en" or "zh"; see ui/i18n.lua.
  language = "en",
}

-- The palette keys that carry a colour override, in a fixed order so the
-- settings UI can render them predictably and a test can iterate them.
settings.PALETTE_KEYS = {
  "black", "gray", "lightGray", "orange", "magenta", "pink", "purple",
}

-- ---------------------------------------------------------------------------
-- Seams -- injected for tests, lazy globals for the real thing
-- ---------------------------------------------------------------------------

local seams = {
  fs = nil,        -- { exists, isDir, makeDir, open, list, read, write, delete }
  json = nil,      -- { encode, decode }
  dir = nil,       -- override for the settings directory
}

-- raw_global(name): read a CC global without tripping a load-time dependency.
local function raw_global(name)
  local ok, value = pcall(rawget, _G, name)
  if ok then
    return value
  end
  return nil
end

-- default_fs() -> an adapter over the live `fs`, read LAZILY.
local function default_fs()
  local real = raw_global("fs")
  if type(real) ~= "table" then
    return nil
  end
  local adapter = {}
  -- Every call is guarded: a host quirk must not become an exception here.
  function adapter.exists(path)
    local ok, value = pcall(real.exists, path)
    return ok and value == true
  end
  function adapter.is_dir(path)
    local ok, value = pcall(real.isDir, path)
    return ok and value == true
  end
  function adapter.make_dir(path)
    if adapter.exists(path) and adapter.is_dir(path) then
      return true
    end
    local ok = pcall(real.makeDir, path)
    return ok and adapter.exists(path) and adapter.is_dir(path)
  end
  function adapter.read(path)
    if not adapter.exists(path) then
      return nil
    end
    local ok, handle = pcall(real.open, path, "r")
    if not ok or handle == nil then
      return nil
    end
    local read_ok, body = pcall(function()
      return handle.readAll()
    end)
    pcall(function()
      handle.close()
    end)
    if read_ok and type(body) == "string" then
      return body
    end
    return nil
  end
  function adapter.write(path, body)
    local ok, handle = pcall(real.open, path, "w")
    if not ok or handle == nil then
      return false
    end
    local wrote_ok, wrote = pcall(function()
      handle.write(body)
      return true
    end)
    pcall(function()
      handle.close()
    end)
    return wrote_ok and wrote == true
  end
  function adapter.delete(path)
    local ok = pcall(real.delete, path)
    return ok
  end
  return adapter
end

-- default_json() -> { encode, decode } over CC's textutils, read LAZILY.
local function default_json()
  local textutils = raw_global("textutils")
  if type(textutils) ~= "table" then
    return nil
  end
  local encoder = textutils.serializeJSON
  local decoder = textutils.unserializeJSON
  if type(encoder) ~= "function" or type(decoder) ~= "function" then
    return nil
  end
  return {
    encode = function(value)
      local ok, text = pcall(encoder, value)
      if ok and type(text) == "string" then
        return text
      end
      return nil
    end,
    decode = function(text)
      local ok, value = pcall(decoder, text)
      if ok and type(value) == "table" then
        return value
      end
      return nil
    end,
  }
end

local function fs_seam()
  return seams.fs or default_fs()
end

local function json_seam()
  return seams.json or default_json()
end

local function settings_dir()
  return seams.dir or settings.DIRECTORY
end

-- settings.configure(opts) -> inject seams.
--   opts.fs, opts.json, opts.dir
-- `configure(nil)` restores every default, so a test can start clean.
function settings.configure(opts)
  if type(opts) ~= "table" then
    seams.fs = nil
    seams.json = nil
    seams.dir = nil
    return settings
  end
  seams.fs = type(opts.fs) == "table" and opts.fs or nil
  seams.json = type(opts.json) == "table" and opts.json or nil
  seams.dir = type(opts.dir) == "string" and opts.dir or nil
  return settings
end

-- ---------------------------------------------------------------------------
-- Value normalisation -- PURE, and the only place a value is trusted
-- ---------------------------------------------------------------------------
-- Every value that comes out of a settings file is UNTRUSTED: a user can edit
-- it by hand, and a corrupted write can leave anything behind.  So each field
-- is coerced through a named validator here rather than being used directly.
-- That is why a hand-broken settings file degrades instead of crashing.

-- settings.valid_url(text) -> string | nil.
-- Accepts only an absolute http/https URL; anything else is rejected so a typo
-- cannot turn into "the app silently talks to nothing".
function settings.valid_url(text)
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return nil
  end
  if trimmed:match("^https?://[%w%.%-%_%~%:%?#%[%]%@%!%$&%'%(%)%*%+%,%;%=/]+$")
    == nil then
    return nil
  end
  return trimmed
end

-- settings.valid_number(value, min, max) -> number | nil.
function settings.valid_number(value, minimum, maximum)
  local number = tonumber(value)
  if number == nil then
    return nil
  end
  if minimum ~= nil and number < minimum then
    return nil
  end
  if maximum ~= nil and number > maximum then
    return nil
  end
  return number
end

-- settings.valid_colour(value) -> integer 0..0xFFFFFF | nil.
-- Accepts a number or a "#RRGGBB" / "RRGGBB" string, and NORMALISES the string
-- form to a number so the rest of the code has one representation.
function settings.valid_colour(value)
  if type(value) == "string" then
    local hex = value:match("^#?(%x%x%x%x%x%x)$")
    if hex == nil then
      return nil
    end
    return tonumber(hex, 16)
  end
  local number = tonumber(value)
  if number == nil or number < 0 or number > 0xFFFFFF then
    return nil
  end
  -- A fractional value is meaningless as a colour.
  if number ~= math.floor(number) then
    return nil
  end
  return number
end

-- settings.valid_language(value) -> "en" | "zh" | nil.
function settings.valid_language(value)
  if value == "en" or value == "zh" then
    return value
  end
  return nil
end

-- settings.normalise_client(raw, fallback) -> a validated {url,timeout,maxRetries}.
-- A field that fails validation falls back to the DEFAULT for that field, not to
-- the whole block: one bad value must not discard a user's other settings.
function settings.normalise_client(raw, fallback)
  local out = {}
  local source = type(raw) == "table" and raw or {}
  local base = type(fallback) == "table" and fallback or {}

  out.url = settings.valid_url(source.url) or base.url
  out.timeout = settings.valid_number(source.timeout, 1, 300) or base.timeout
  out.maxRetries = settings.valid_number(source.maxRetries, 0, 10)
    or base.maxRetries
  return out
end

-- ---------------------------------------------------------------------------
-- Merge -- PURE.  Defaults, then a stored table, field by field
-- ---------------------------------------------------------------------------
-- settings.merge(kind, stored) -> a complete, validated settings block.
-- `kind` names which block ("api", "ime", "updater", "display", "font",
-- "appearance") so this one function serves them all.
function settings.merge(kind, stored)
  local defaults = settings.DEFAULTS[kind]
  local raw = type(stored) == "table" and stored or {}

  if kind == "api" or kind == "ime" or kind == "updater" then
    local out = settings.normalise_client(raw, defaults)
    if kind == "ime" then
      -- `enabled` is a real switch, so only an explicit false turns it off;
      -- anything else keeps the default (which is on).
      if raw.enabled == false then
        out.enabled = false
      else
        out.enabled = defaults.enabled ~= false
      end
    end
    return out
  end

  if kind == "display" then
    local name = raw.name
    if type(name) ~= "string" or name == "" then
      name = defaults.name
    end
    return { name = name }
  end

  if kind == "font" then
    return {
      url = settings.valid_url(raw.url) or defaults.url,
      size = (raw.size == "8px" or raw.size == "12px") and raw.size
        or defaults.size,
    }
  end

  if kind == "appearance" then
    local out = {}
    for _, key in ipairs(settings.PALETTE_KEYS) do
      local colour = settings.valid_colour(raw[key])
      if colour == nil then
        colour = defaults[key]
      end
      out[key] = colour
    end
    return out
  end

  return {}
end

-- ---------------------------------------------------------------------------
-- File paths
-- ---------------------------------------------------------------------------

-- settings.file_for(kind) -> the repo-relative path, e.g. "Settings/Api.json".
-- The name is capitalised to match the reference project's layout, so anyone who
-- has seen its data directory recognises this one.
local FILE_NAMES = {
  api = "Api.json",
  ime = "Ime.json",
  updater = "Updater.json",
  display = "Display.json",
  font = "Font.json",
  appearance = "Appearance.json",
  language = "Language.json",
}

function settings.file_for(kind)
  local name = FILE_NAMES[kind]
  if name == nil then
    return nil
  end
  return settings_dir() .. "/" .. name
end

-- ---------------------------------------------------------------------------
-- Loading and saving
-- ---------------------------------------------------------------------------

-- settings.load(kind) -> value, error.
--   * the file is absent          -> the DEFAULTS, no error (a first run)
--   * the file is unreadable      -> the DEFAULTS, plus an error
--   * the file is not valid JSON  -> the DEFAULTS, plus an error
-- The returned value is ALWAYS a complete, validated block.
function settings.load(kind)
  if settings.DEFAULTS[kind] == nil and FILE_NAMES[kind] == nil then
    return nil, "unknown settings kind: " .. tostring(kind)
  end

  local fallback = settings.merge(kind, nil)

  local fs = fs_seam()
  local json = json_seam()
  if fs == nil then
    return fallback, "no filesystem available"
  end
  if json == nil then
    return fallback, "no JSON codec available"
  end

  local path = settings.file_for(kind)
  if path == nil then
    return fallback, "unknown settings kind: " .. tostring(kind)
  end
  if not fs.exists(path) then
    return fallback, nil
  end

  local body = fs.read(path)
  if type(body) ~= "string" then
    return fallback, "could not read " .. path
  end

  local decoded = json.decode(body)
  if type(decoded) ~= "table" then
    return fallback, "could not decode " .. path
  end

  if kind == "language" then
    return { code = settings.valid_language(decoded.code) or fallback.code },
      nil
  end
  return settings.merge(kind, decoded), nil
end

-- settings.save(kind, value) -> true | false, error.
-- Writes the validated block.  The directory is created on demand, so a first
-- run needs no setup step.
function settings.save(kind, value)
  if settings.DEFAULTS[kind] == nil and FILE_NAMES[kind] == nil then
    return false, "unknown settings kind: " .. tostring(kind)
  end

  local fs = fs_seam()
  local json = json_seam()
  if fs == nil then
    return false, "no filesystem available"
  end
  if json == nil then
    return false, "no JSON codec available"
  end

  if not fs.exists(settings_dir()) then
    if not fs.make_dir(settings_dir()) then
      return false, "could not create " .. settings_dir()
    end
  end

  local normalised
  if kind == "language" then
    normalised = { code = settings.valid_language(
      type(value) == "table" and value.code or value) or settings.DEFAULTS.language }
  else
    normalised = settings.merge(kind, value)
  end

  local text = json.encode(normalised)
  if type(text) ~= "string" then
    return false, "could not encode settings"
  end

  local path = settings.file_for(kind)
  if not fs.write(path, text) then
    return false, "could not write " .. tostring(path)
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Convenience wrappers -- one per concern, so no call site spells a kind wrong
-- ---------------------------------------------------------------------------

function settings.load_api() return settings.load("api") end
function settings.save_api(value) return settings.save("api", value) end

function settings.load_ime() return settings.load("ime") end
function settings.save_ime(value) return settings.save("ime", value) end

function settings.load_updater() return settings.load("updater") end
function settings.save_updater(value) return settings.save("updater", value) end

function settings.load_display() return settings.load("display") end
function settings.save_display(value) return settings.save("display", value) end

function settings.load_font() return settings.load("font") end
function settings.save_font(value) return settings.save("font", value) end

function settings.load_appearance() return settings.load("appearance") end
function settings.save_appearance(value)
  return settings.save("appearance", value)
end

function settings.load_language() return settings.load("language") end
function settings.save_language(value)
  return settings.save("language", value)
end

-- settings.load_all() -> a table of every block, keyed by kind.
-- Each entry ALSO carries its error, so a caller can warn about one broken file
-- without losing the other six.
function settings.load_all()
  local kinds = { "api", "ime", "updater", "display", "font", "appearance",
                  "language" }
  local out = {}
  for _, kind in ipairs(kinds) do
    local value, err = settings.load(kind)
    out[kind] = value
    if err ~= nil then
      out[kind .. "Error"] = err
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Applying the appearance -- the one place a colour reaches the terminal
-- ---------------------------------------------------------------------------
-- settings.apply_palette(appearance, term) -> count of colours applied.
-- `term` defaults to the live `term` global, read lazily.  Best effort: a host
-- with no palette support simply keeps its defaults, which is why this returns a
-- count rather than raising.
function settings.apply_palette(appearance, term)
  local terminal = term or raw_global("term")
  if type(terminal) ~= "table"
    or type(terminal.setPaletteColor) ~= "function" then
    return 0
  end
  local colours = raw_global("colors")
  if type(colours) ~= "table" then
    return 0
  end

  local block = settings.merge("appearance", appearance)
  local applied = 0
  for _, key in ipairs(settings.PALETTE_KEYS) do
    local slot = colours[key]
    local colour = block[key]
    if slot ~= nil and colour ~= nil then
      local ok = pcall(terminal.setPaletteColor, slot, colour)
      if ok then
        applied = applied + 1
      end
    end
  end
  return applied
end

return settings
