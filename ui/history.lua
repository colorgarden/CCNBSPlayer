-- ui/history.lua
--
-- THE LOCAL LIBRARY STATE -- recently played, and favourites.
--
-- The reference implementation keeps these on its server, because it has
-- accounts.  We have none, so they live on the computer: two small JSON files
-- under the settings directory, managed here.
--
-- ===========================================================================
-- WHY THIS IS A SEPARATE MODULE FROM ui/settings.lua
-- ===========================================================================
-- Settings are things the user TYPES; history is something the program WRITES
-- as a side effect of playing.  They have different failure postures: a corrupt
-- setting deserves a warning, while a corrupt history should silently reset --
-- nobody wants to be told their play history was lost, and the data is
-- worthless.  Splitting them keeps that distinction out of the caller's way.
--
-- ===========================================================================
-- THE CAP IS THE POINT
-- ===========================================================================
-- `record` is called on every song, forever.  Without a bound the file grows
-- until the computer runs out of disk, so the history is a bounded ring: the
-- newest entry is first, and the oldest is dropped once the cap is reached.
-- Favourites are NOT capped -- the user chose those deliberately, and a cap
-- would silently delete a deliberate choice.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.  All globals
-- are read lazily, so this module is require-able in plain desktop Lua.

local history = {}

-- How many recently-played entries to keep.
history.MAX_ENTRIES = 50

-- How many favourites to keep.  Generous, but still bounded: an unbounded list
-- is an unbounded file.
history.MAX_FAVOURITES = 500

history.DIRECTORY = "Settings"
history.HISTORY_FILE = "History.json"
history.FAVOURITES_FILE = "Favourites.json"

-- ---------------------------------------------------------------------------
-- Seams
-- ---------------------------------------------------------------------------

local seams = {
  fs = nil,
  json = nil,
  clock = nil,     -- function() -> number, for the "when" stamp
  dir = nil,
}

local function raw_global(name)
  local ok, value = pcall(rawget, _G, name)
  if ok then
    return value
  end
  return nil
end

-- default_clock(): seconds-since-epoch, lazily.  `os.epoch` is a CC extension;
-- `os.time` is the portable fallback.  A host with neither yields 0, and the
-- history still works -- only the ordering timestamp degrades.
local function default_clock()
  local oslib = raw_global("os")
  if type(oslib) ~= "table" then
    return 0
  end
  if type(oslib.epoch) == "function" then
    local ok, value = pcall(oslib.epoch, "utc")
    if ok and type(value) == "number" then
      return value
    end
  end
  if type(oslib.time) == "function" then
    local ok, value = pcall(oslib.time)
    if ok and type(value) == "number" then
      return value
    end
  end
  return 0
end

local function default_fs()
  local real = raw_global("fs")
  if type(real) ~= "table" then
    return nil
  end
  local adapter = {}
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
    local wrote_ok = pcall(function()
      handle.write(body)
    end)
    pcall(function()
      handle.close()
    end)
    return wrote_ok
  end
  return adapter
end

local function default_json()
  local textutils = raw_global("textutils")
  if type(textutils) ~= "table" then
    return nil
  end
  if type(textutils.serializeJSON) ~= "function"
    or type(textutils.unserializeJSON) ~= "function" then
    return nil
  end
  return {
    encode = function(value)
      local ok, text = pcall(textutils.serializeJSON, value)
      if ok and type(text) == "string" then
        return text
      end
      return nil
    end,
    decode = function(text)
      local ok, value = pcall(textutils.unserializeJSON, text)
      if ok and type(value) == "table" then
        return value
      end
      return nil
    end,
  }
end

local function fs_seam() return seams.fs or default_fs() end
local function json_seam() return seams.json or default_json() end
local function clock_seam() return seams.clock or default_clock end
local function dir_seam() return seams.dir or history.DIRECTORY end

-- history.configure(opts) -> inject seams; `nil` restores the defaults.
function history.configure(opts)
  if type(opts) ~= "table" then
    seams.fs = nil
    seams.json = nil
    seams.clock = nil
    seams.dir = nil
    return history
  end
  seams.fs = type(opts.fs) == "table" and opts.fs or nil
  seams.json = type(opts.json) == "table" and opts.json or nil
  seams.clock = type(opts.clock) == "function" and opts.clock or nil
  seams.dir = type(opts.dir) == "string" and opts.dir or nil
  return history
end

-- ---------------------------------------------------------------------------
-- PURE parts -- the identity of an entry, and the capping rule
-- ---------------------------------------------------------------------------

-- history.entry_key(item) -> a stable string identifying a song.
-- A local file is identified by its path; an NBW song by its public id.
-- A record with neither still yields a key (so it is not lost), derived from
-- its title and author, which is the best available identity.
function history.entry_key(item)
  if type(item) ~= "table" then
    return nil
  end
  local kind = item.kind
  local ref = item.ref
  if type(ref) == "string" and ref ~= "" then
    return tostring(kind or "?") .. ":" .. ref
  end
  local title = type(item.title) == "string" and item.title or "?"
  local author = type(item.author) == "string" and item.author or "?"
  return tostring(kind or "?") .. ":" .. title .. "\0" .. author
end

-- history.push(list, entry, cap) -> a NEW list with `entry` first.
--   * the entry is REMOVED from wherever it already was, so replaying a song
--     moves it to the top instead of appearing twice -- which is what a user
--     means by "recently played";
--   * the result is capped, dropping the oldest;
--   * PURE: the input list is never mutated, so a caller's state cannot be
--     corrupted by a call it did not expect to change anything.
function history.push(list, entry, cap)
  local out = {}
  if type(list) == "table" then
    for _, item in ipairs(list) do
      out[#out + 1] = item
    end
  end
  if type(entry) ~= "table" then
    return out
  end

  local key = history.entry_key(entry)
  local kept = {}
  for _, item in ipairs(out) do
    if history.entry_key(item) ~= key then
      kept[#kept + 1] = item
    end
  end

  local result = { entry }
  for _, item in ipairs(kept) do
    result[#result + 1] = item
  end

  local limit = tonumber(cap) or history.MAX_ENTRIES
  if limit < 1 then
    limit = 1
  end
  while #result > limit do
    table.remove(result)
  end
  return result
end

-- history.remove_key(list, key) -> a NEW list without that key.
function history.remove_key(list, key)
  local out = {}
  if type(list) ~= "table" or key == nil then
    return out
  end
  for _, item in ipairs(list) do
    if history.entry_key(item) ~= key then
      out[#out + 1] = item
    end
  end
  return out
end

-- history.has_key(list, key) -> boolean.
function history.has_key(list, key)
  if type(list) ~= "table" or key == nil then
    return false
  end
  for _, item in ipairs(list) do
    if history.entry_key(item) == key then
      return true
    end
  end
  return false
end

-- history.sanitise(list, cap) -> a validated copy.
-- Everything read off disk is untrusted: a hand-edited or truncated file must
-- not put a non-table into the list, because the UI would then render nil.
function history.sanitise(list, cap)
  local out = {}
  if type(list) ~= "table" then
    return out
  end
  local limit = tonumber(cap) or history.MAX_ENTRIES
  for _, item in ipairs(list) do
    if type(item) == "table" then
      local entry = {
        kind = type(item.kind) == "string" and item.kind or "?",
        ref = type(item.ref) == "string" and item.ref or nil,
        title = type(item.title) == "string" and item.title or "Untitled song",
        author = type(item.author) == "string" and item.author or "Unknown author",
        license = type(item.license) == "string" and item.license or nil,
        attribution = type(item.attribution) == "string" and item.attribution
          or nil,
        at = tonumber(item.at) or 0,
      }
      out[#out + 1] = entry
      if #out >= limit then
        break
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

function history.path(file)
  return dir_seam() .. "/" .. tostring(file)
end

-- read_list(file, cap) -> array.
-- A missing file, an unreadable file and a corrupt file ALL yield an empty
-- list, silently: see the module header for why history does not warn.
local function read_list(file, cap)
  local fs = fs_seam()
  local json = json_seam()
  if fs == nil or json == nil then
    return {}
  end
  local path = history.path(file)
  if not fs.exists(path) then
    return {}
  end
  local body = fs.read(path)
  if type(body) ~= "string" then
    return {}
  end
  local decoded = json.decode(body)
  if type(decoded) ~= "table" then
    return {}
  end
  -- Accept either a bare array or a { entries = {...} } wrapper, so the file
  -- can grow a field later without breaking existing data.
  local list = decoded
  if type(decoded.entries) == "table" then
    list = decoded.entries
  end
  return history.sanitise(list, cap)
end

-- write_list(file, list) -> true | false.
local function write_list(file, list)
  local fs = fs_seam()
  local json = json_seam()
  if fs == nil or json == nil then
    return false
  end
  local dir = dir_seam()
  if not fs.exists(dir) then
    if not fs.make_dir(dir) then
      return false
    end
  end
  local text = json.encode(list)
  if type(text) ~= "string" then
    return false
  end
  return fs.write(history.path(file), text) == true
end

-- ---------------------------------------------------------------------------
-- Recently played
-- ---------------------------------------------------------------------------

-- history.record(song) -> true | false.
-- Adds a song to the top of the recent list.  Called on every play, so it must
-- be cheap and must never raise.
function history.record(song)
  if type(song) ~= "table" then
    return false
  end
  local entry = {
    kind = type(song.kind) == "string" and song.kind or "?",
    ref = type(song.ref) == "string" and song.ref or nil,
    title = type(song.title) == "string" and song.title or "Untitled song",
    author = type(song.author) == "string" and song.author or "Unknown author",
    license = type(song.license) == "string" and song.license or nil,
    attribution = type(song.attribution) == "string" and song.attribution
      or nil,
    at = clock_seam()(),
  }
  local list = read_list(history.HISTORY_FILE, history.MAX_ENTRIES)
  return write_list(history.HISTORY_FILE,
    history.push(list, entry, history.MAX_ENTRIES))
end

-- history.list() -> array of entries, newest first.
function history.list()
  return read_list(history.HISTORY_FILE, history.MAX_ENTRIES)
end

-- history.clear() -> true | false.
-- Idempotent: clearing an empty history succeeds, because the user's intent
-- ("there should be nothing here") is already satisfied.
function history.clear()
  return write_list(history.HISTORY_FILE, {})
end

-- ---------------------------------------------------------------------------
-- Favourites
-- ---------------------------------------------------------------------------

-- history.is_favourite(id_or_entry) -> boolean.
-- Accepts either an identifier table (with kind/ref) or a raw key string.
function history.is_favourite(id_or_entry)
  local key
  if type(id_or_entry) == "string" then
    key = id_or_entry
  else
    key = history.entry_key(id_or_entry)
  end
  return history.has_key(history.favourites(), key)
end

-- history.toggle_favourite(song) -> true if it is now a favourite, false if not.
function history.toggle_favourite(song)
  if type(song) ~= "table" then
    return false
  end
  local key = history.entry_key(song)
  local list = history.favourites()
  if history.has_key(list, key) then
    write_list(history.FAVOURITES_FILE,
      history.remove_key(list, key))
    return false
  end

  local entry = {
    kind = type(song.kind) == "string" and song.kind or "?",
    ref = type(song.ref) == "string" and song.ref or nil,
    title = type(song.title) == "string" and song.title or "Untitled song",
    author = type(song.author) == "string" and song.author or "Unknown author",
    license = type(song.license) == "string" and song.license or nil,
    attribution = type(song.attribution) == "string" and song.attribution
      or nil,
    at = clock_seam()(),
  }
  write_list(history.FAVOURITES_FILE,
    history.push(list, entry, history.MAX_FAVOURITES))
  return true
end

-- history.favourites() -> array of entries, most recently added first.
function history.favourites()
  return read_list(history.FAVOURITES_FILE, history.MAX_FAVOURITES)
end

-- history.clear_favourites() -> true | false.
function history.clear_favourites()
  return write_list(history.FAVOURITES_FILE, {})
end

return history
