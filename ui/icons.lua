-- ui/icons.lua
--
-- THE MPLAYER ICON-SET LOADER -- the SINGLE place that knows how to obtain,
-- compile and CACHE the 35 bitmap icons the new user interface draws with.
--
-- ===========================================================================
-- WHY THIS EXISTS
-- ===========================================================================
-- The interface is modelled on MPlayer, which labels and draws buttons with
-- small BITMAP icons rather than text.  MPlayer's 35 icons are vendored,
-- VERBATIM and unmodified, under vendor/mplayer-icons/ (see NOTICE and
-- vendor/README.md for their provenance and licence).  Each file is pure data:
-- a Lua chunk that returns a `bimg` -- the pixel-bitmap structure the fork of
-- Basalt accepts through `element:setImage(bimg)`:
--
--     return {
--       {"\135\143\143\139","BQQB","QBBQ"},   -- one row: {text, fg, bg}
--       ...
--     }
--
-- `Loading-circle` is the one ANIMATED icon: its chunk returns
-- `{ animation = true, <frame>, <frame>, ... }` where each frame is itself a
-- bimg.  This loader returns whatever the file returns, unchanged, so both
-- shapes reach Basalt exactly as upstream wrote them.
--
-- ===========================================================================
-- WHY A LOADER AT ALL -- the two constraints that force it
-- ===========================================================================
-- 1. THE NAMES ARE NOT REQUIREABLE.  Some names contain a HYPHEN
--    (`Loading-circle`, `chevron-left`), so `require("...Loading-circle")` is
--    not a legal module name.  A path-based loader sidesteps `require`
--    entirely, which matters even more because the vendored Basalt bundle
--    REPLACES the global `require` with its own in-memory shim.
-- 2. BOOT MUST NOT PAY FOR ICONS.  Loading 35 files eagerly at startup is
--    wasted work: a launch may use none of them.  `icons.get(name)` compiles on
--    first use and caches the result; a second call for the same name never
--    reads the file again.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local icons = require("ui.icons")
--
--   icons.NAMES          -- array of the 35 names, SORTED, for iteration/tests
--   icons.get(name)      -- bimg table | nil (lazy + cached; nil, never raises)
--   icons.loaded()       -- array of the names already cached (sorted)
--   icons.forget()       -- drop the cache so a test can start clean
--   icons.configure(opts)-- inject seams, or reset them with configure(nil)
--
--   icons.configure({ dir =, read =, compile = })
--     dir      -- override the icon directory
--     read     -- read(path) -> string | nil
--     compile  -- compile(source, name) -> chunk | nil, err
--   icons.configure(nil) resets all three to the defaults.
--
-- ===========================================================================
-- ADOPTED DESIGN DECISIONS (intentional, not oversights)
-- ===========================================================================
-- * LAZY + CACHED.  Nothing is read at module load; each file is read and
--   compiled at most once per process.
-- * NEGATIVE CACHING.  A missing/unreadable file, a raising chunk or a chunk
--   that returns a non-table each make `get` return nil AND remember the miss,
--   so the same broken name is never retried in a loop.  A missing icon costs
--   the user one icon, never the program.
-- * THE DIRECTORY IS RESOLVED ONCE, LAZILY, AND THE `require` SHIM IS NOT
--   CONSULTED.  Order: an injected `dir`, then the directory the running
--   program lives in, then the installed `/lib` location.
-- * NO GLOBALS AT LOAD TIME.  `fs`, `shell`, `load` and `term` are read
--   LAZILY, through `rawget(_G, ...)`, only inside the default seams -- so
--   `require("ui.icons")` succeeds on plain desktop Lua, where `fs`, `shell`
--   and `term` do not exist.
-- * MEASURE NOTHING, PRINT NOTHING.  No clocks, no `print`, no logging: the
--   caller decides what to report.
--
-- ===========================================================================
-- COMPATIBILITY
-- ===========================================================================
-- Lua 5.2 / CC:Tweaked Cobalt: no `//`, no bitwise operators, no
-- math.maxinteger, no collectgarbage, no string.dump, no os.exit and no
-- utf8.*.

local icons = {}

-- ---------------------------------------------------------------------------
-- The 35 names, SORTED.  Sorted literally rather than with table.sort so that
-- module load reads NO global at all (a `table` lookup is still a global read).
-- ---------------------------------------------------------------------------

icons.NAMES = {
  "Album",
  "Discover",
  "Favorite",
  "Favorite1",
  "Favorite2",
  "Home",
  "Like",
  "List",
  "Loading-circle",
  "LoopPlay",
  "LoopPlay2",
  "Maximise",
  "Menu",
  "MusicalNote",
  "NextSong",
  "Pause",
  "PauseCircle",
  "PlayCircle",
  "Podcast",
  "PreviousSong",
  "Recently",
  "Roaming",
  "Search",
  "Settings",
  "ShufflePlay",
  "TrashCan",
  "User",
  "Volume",
  "X",
  "chevron-down",
  "chevron-left",
  "chevron-right",
  "chevron-up",
  "circle-filled",
  "play",
}

-- known[name] -- membership test so an unknown name never touches the disk.
local known = {}
for index = 1, #icons.NAMES do
  known[icons.NAMES[index]] = true
end

-- The installed location under /lib, used when the running program's directory
-- cannot be determined.
local FALLBACK_DIR = "/lib/vendor/mplayer-icons"

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- Injected seams.  A nil field means "use the default seam".
local config = {
  dir = nil,
  read = nil,
  compile = nil,
}

-- cache[name] = <bimg table>  (hit)
--             = false         (negative: attempted and failed; do not retry)
local cache = {}

-- The directory, resolved at most once per configuration.  nil = not yet.
local resolved_dir = nil

-- ---------------------------------------------------------------------------
-- Lazy global access.  `rawget` bypasses a hostile `__index`, and nothing is
-- read from a global until one of these helpers is CALLED.
-- ---------------------------------------------------------------------------

local function raw_global(name)
  local called, value = pcall(rawget, _G, name)
  if called then
    return value
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Directory resolution: injected dir, then running-program dir, then /lib
-- ---------------------------------------------------------------------------

local function discover_dir()
  local shell = raw_global("shell")
  if type(shell) == "table" then
    local read_ok, get_program = pcall(function()
      return shell.getRunningProgram
    end)
    if read_ok and type(get_program) == "function" then
      local called, program = pcall(get_program)
      if called and type(program) == "string" and #program > 0 then
        local filesystem = raw_global("fs")
        if type(filesystem) == "table" then
          local dir_ok, get_dir = pcall(function()
            return filesystem.getDir
          end)
          if dir_ok and type(get_dir) == "function" then
            local ran, dir = pcall(get_dir, program)
            if ran and type(dir) == "string" and #dir > 0 then
              return dir .. "/vendor/mplayer-icons"
            end
          end
        end
      end
    end
  end
  return FALLBACK_DIR
end

local function lazily_resolve_dir()
  if resolved_dir ~= nil then
    return resolved_dir
  end
  local dir = config.dir
  if type(dir) ~= "string" or #dir == 0 then
    dir = discover_dir()
  end
  resolved_dir = dir
  return dir
end

-- ---------------------------------------------------------------------------
-- Default seams (used only when the caller injects nothing)
-- ---------------------------------------------------------------------------

-- read(path) -> string | nil.  Reads through the `fs` global, tolerating any
-- failure (missing fs, missing file, raising metatable) by returning nil.
local function default_read(path)
  local called, body = pcall(function()
    local filesystem = raw_global("fs")
    if type(filesystem) ~= "table" then
      return nil
    end
    local exists = filesystem.exists
    if type(exists) == "function" and exists(path) == false then
      return nil
    end
    local data = filesystem.read(path)
    if type(data) == "string" and #data > 0 then
      return data
    end
    return nil
  end)
  if called then
    return body
  end
  return nil
end

-- compile(source, name) -> chunk | nil, err.  Compiles through the `load`
-- global in text mode; a raise is reported, never propagated.
local function default_compile(source, name)
  local called, chunk, err = pcall(function()
    local loader = raw_global("load")
    if type(loader) ~= "function" then
      return nil, "load is unavailable"
    end
    return loader(source, "=" .. tostring(name), "t")
  end)
  if not called then
    return nil, "compile failed"
  end
  if chunk == nil then
    if type(err) == "string" then
      return nil, err
    end
    return nil, "compile failed"
  end
  return chunk
end

-- ---------------------------------------------------------------------------
-- Cache bookkeeping
-- ---------------------------------------------------------------------------

local function remember(name, value)
  cache[name] = value
end

-- Read, compile, execute and validate one icon.  NEVER raises: the whole body
-- runs under one pcall and any failure is a remembered nil.
local function load_icon(name)
  local ran, value = pcall(function()
    local dir = lazily_resolve_dir()
    if type(dir) ~= "string" or #dir == 0 then
      return nil
    end
    local path = dir .. "/" .. name .. ".lua"

    local read = config.read
    if type(read) ~= "function" then
      read = default_read
    end
    local source = read(path)
    if type(source) ~= "string" or #source == 0 then
      return nil
    end

    local compile = config.compile
    if type(compile) ~= "function" then
      compile = default_compile
    end
    local chunk = compile(source, name)
    if type(chunk) ~= "function" then
      return nil
    end

    local executed, result = pcall(chunk)
    if not executed then
      return nil
    end
    if type(result) ~= "table" then
      return nil
    end
    return result
  end)

  if ran and type(value) == "table" then
    remember(name, value)
    return value
  end
  remember(name, false)
  return nil
end

-- ---------------------------------------------------------------------------
-- Public interface
-- ---------------------------------------------------------------------------

-- get(name) -> bimg | nil.  Lazy and cached; a non-string or unknown name
-- returns nil without touching the disk.
function icons.get(name)
  if type(name) ~= "string" or #name == 0 or not known[name] then
    return nil
  end
  local cached = cache[name]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end
  return load_icon(name)
end

-- loaded() -> names already cached, sorted.  Includes names remembered as nil.
function icons.loaded()
  local result = {}
  for name in pairs(cache) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

-- Drop the cache so the next get reads again.
function icons.forget()
  cache = {}
  return true
end

-- configure(opts) -- inject seams; configure(nil) resets to the defaults.
function icons.configure(opts)
  if opts == nil then
    config = { dir = nil, read = nil, compile = nil }
    resolved_dir = nil
    return true
  end
  if type(opts) ~= "table" then
    return false
  end
  if opts.dir ~= nil then
    config.dir = opts.dir
  end
  if opts.read ~= nil then
    config.read = opts.read
  end
  if opts.compile ~= nil then
    config.compile = opts.compile
  end
  resolved_dir = nil
  return true
end

return icons
