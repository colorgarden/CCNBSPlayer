-- ui/songs.lua
--
-- THE SONG DATA LAYER -- the SINGLE place the user interface asks for songs
-- through.  It hides WHERE a song came from (a local `.nbs` file or a Note
-- Block World entry) behind ONE normalised record shape, so no screen ever
-- touches HTTP or a filesystem path directly.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local songs = require("ui.songs")
--
--   songs.configure(opts)  -- inject seams (REPLACES nothing; merges the given
--                          --   fields).  configure(nil) resets every seam.
--       opts.http        -- the net.http-shaped client handed to net/nbw.lua
--       opts.json_decode -- the JSON decoder seam handed to net/nbw.lua
--       opts.fs          -- the filesystem table (exists/isDir/make_dir/move/
--                           delete/list/write/read)
--       opts.read        -- override function(path) -> string|nil
--       opts.write       -- override function(path, data) -> true|false
--       opts.list        -- override function(dir) -> array|nil
--       opts.dir         -- the directory songs.local() scans (default ".")
--
--   songs["local"]()       -> array of local records            (never fails)
--   songs.local_songs()    -> the SAME function, dot-callable alias
--   songs.search(opts)     -> { ok=true, songs=, page=, limit=, total= }
--                           | { ok=false, error=, code= }
--   songs.detail(id)       -> { ok=true, song= } | { ok=false, error=, code= }
--   songs.download(id, dest_dir, on_progress, opts)
--                          -> { ok=true, path=, bytes= }
--                           | { ok=false, error=, code= }
--
-- NOTE ON THE NAME: the interface calls this operation "local", but `local` is
-- a Lua RESERVED WORD and `t.local` does not even parse ("<name> expected near
-- 'local'").  The function therefore lives under the table key "local", reached
-- as songs["local"](), exactly as updater.lua already reaches its own "local"
-- key.  songs.local_songs is provided as an equally-supported, dot-callable
-- alias for callers that prefer ordinary method syntax.
--
--   songs.safe_filename(title)      -> string ending in ".nbs"   (PURE)
--   songs.unique_name(exists_fn, n) -> collision-free name       (PURE)
--   songs.normalise_nbw(raw)        -> one normalised record      (PURE)
--
--   songs.UNTITLED, songs.UNKNOWN_AUTHOR -- the stated, non-empty placeholders
--   songs.MAX_FILENAME                    -- the filename byte cap (incl. .nbs)
--
-- ===========================================================================
-- THE ONE RECORD SHAPE (both sources)
-- ===========================================================================
--   { kind = "local" | "nbw",   -- the discriminator the UI switches on
--     ref  = <path for local, publicId for nbw>,  -- what play/download needs
--     title = <string>, author = <string>,         -- NEVER nil, never empty
--     license = <string|nil>,                      -- nbw only: the human label
--     attribution = <string|nil>,                  -- nbw only: nbw.attribution
--     extra = <the raw source record> }            -- kept, never invented
--
--   * `title` and `author` are ALWAYS non-empty strings.  A record with no
--     usable title gets songs.UNTITLED; a record with no usable uploader falls
--     back to the original author and then to songs.UNKNOWN_AUTHOR.  A UI that
--     renders a nil crashes, so nil is never allowed out of here.
--   * `license` carries the human sentence from net/nbw.lua's license_label(),
--     NOT a re-written licence.  The raw code stays reachable in `extra`.
--   * `attribution` is exactly net/nbw.lua's attribution() output, so the
--     uploader + song-page credit has a single owner.
--
-- ===========================================================================
-- FAILURE vs EMPTY (do not flatten one into the other)
-- ===========================================================================
--   search/detail pass a net/nbw.lua FAILURE through UNCHANGED (ok == false,
--   with its `code`/`error`), while a success carries a `songs` array that may
--   legitimately be EMPTY.  A caller can therefore tell "no results" from "the
--   network failed": the first is ok == true with #songs == 0, the second is
--   ok == false.  Never return an empty list for a failure.
--
-- ===========================================================================
-- LICENCE OBLIGATION (inherited from net/nbw.lua -- do not weaken)
-- ===========================================================================
-- The project is GPL-2.0 and bundles NO song.  Half the Note Block World
-- catalogue is licensed "standard" (personal listening only).  Every nbw
-- record therefore carries `license` (nbw.license_label) and `attribution`
-- (nbw.attribution) so the interface can satisfy the credit obligation.
--
-- ===========================================================================
-- PURITY / INJECTED SEAMS
-- ===========================================================================
-- Nothing here touches the network, a JSON library or a real filesystem at
-- load time.  `fs`, `http` are read LAZILY inside the default seams and are
-- never indexed at require time.  songs["local"]()/search()/detail() never
-- write; songs.download() is THE ONE function that writes to disk.
--
-- ON DOWNLOAD ATOMICITY: download() writes the bytes to a TEMPORARY name
-- (`<final>.part`) and then RENAMES it onto the final, collision-free name.  A
-- failure anywhere deletes the partial file, so no half-written song ever
-- survives.  When the filesystem exposes no rename seam it falls back to
-- writing the final path directly and deleting it on failure.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.
-- Nothing here raises: every public function returns a value.

local nbw = require("net.nbw")

local songs = {}

-- ---------------------------------------------------------------------------
-- Constants and placeholders
-- ---------------------------------------------------------------------------

songs.EXTENSION = ".nbs"

-- The stated, non-empty placeholders a record falls back to.  They are exposed
-- so a view can compare against them and so tests can prove they are used.
songs.UNTITLED = "Untitled song"
songs.UNKNOWN_AUTHOR = "Unknown author"

-- The byte cap for a generated filename INCLUDING the ".nbs" extension.
songs.MAX_FILENAME = 64

-- songs["local"]() scans the current directory unless configure({ dir = ... }).
local DEFAULT_DIR = "."

-- ---------------------------------------------------------------------------
-- Module state: the injected seams and the title cache
-- ---------------------------------------------------------------------------
-- The cache maps a ref (publicId) to the normalised record last seen for it, so
-- download() can name a file after the song title WITHOUT a second round trip
-- when search()/detail() already returned the record.

local config = {}
local record_cache = {}

local function cache_record(record)
  if type(record) == "table"
    and type(record.ref) == "string" and record.ref ~= "" then
    record_cache[record.ref] = record
  end
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function failure(message, code)
  return { ok = false, error = tostring(message), code = code or "E_SONGS" }
end

local function non_empty_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

-- Read a global lazily and safely: a hostile environment that traps a global
-- must be caught here, never at require time.
local function read_global(name)
  local ok, value = pcall(function()
    return _G[name]
  end)
  if ok then
    return value
  end
  return nil
end

local function shallow_copy(source)
  local copy = {}
  if type(source) == "table" then
    for key, value in pairs(source) do
      copy[key] = value
    end
  end
  return copy
end

-- Join a directory and a file name without ever producing a doubled separator.
local function join_path(dir, name)
  if type(dir) ~= "string" or dir == "" or dir == "." then
    return name
  end
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

-- Strip a single trailing ".nbs" (case-insensitive), if present.
local function strip_extension(name)
  return (name:gsub("%.[nN][bB][sS]$", ""))
end

-- ---------------------------------------------------------------------------
-- Seam resolution (lazy; nothing touches a global until a call needs it)
-- ---------------------------------------------------------------------------

local function resolve_fs()
  if type(config.fs) == "table" then
    return config.fs
  end
  local value = read_global("fs")
  if type(value) == "table" then
    return value
  end
  return nil
end

local function resolve_write()
  if type(config.write) == "function" then
    return config.write
  end
  local filesystem = resolve_fs()
  if filesystem ~= nil and type(filesystem.write) == "function" then
    return filesystem.write
  end
  return nil
end

local function resolve_list()
  if type(config.list) == "function" then
    return config.list
  end
  local filesystem = resolve_fs()
  if filesystem ~= nil and type(filesystem.list) == "function" then
    return filesystem.list
  end
  return nil
end

local function resolve_exists()
  local filesystem = resolve_fs()
  if filesystem ~= nil and type(filesystem.exists) == "function" then
    return filesystem.exists
  end
  return nil
end

local function resolve_is_dir()
  local filesystem = resolve_fs()
  if filesystem ~= nil and type(filesystem.isDir) == "function" then
    return filesystem.isDir
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- PURE: safe_filename(title) -> a filesystem-safe "<name>.nbs"
-- ---------------------------------------------------------------------------
-- Replaces path separators and the punctuation a picky filesystem rejects,
-- replaces control characters, collapses separator/whitespace runs, strips
-- leading/trailing dots and spaces, caps the byte length (without splitting a
-- UTF-8 sequence) and always ends in ".nbs".  An empty or all-unsafe title
-- still yields a usable name, because a name that sanitises to nothing becomes
-- "song.nbs" rather than an empty string.
function songs.safe_filename(title)
  if type(title) ~= "string" then
    title = ""
  end

  local name = strip_extension(title)
  name = name:gsub("[/\\:*?\"<>|]", "_")
  name = name:gsub("%c", "_")
  name = name:gsub("%s+", " ")
  name = name:gsub("_+", "_")
  name = name:gsub("^[%.%s]+", "")
  name = name:gsub("[%.%s]+$", "")

  local max_base = songs.MAX_FILENAME - #songs.EXTENSION
  if #name > max_base then
    local cut = max_base
    local following = string.byte(name, cut + 1)
    if following ~= nil and following >= 128 and following < 192 then
      -- The cut landed inside a multi-byte sequence: back up over the trailing
      -- continuation bytes and drop the lead byte too.
      while cut > 0 do
        local current = string.byte(name, cut)
        if current ~= nil and current >= 128 and current < 192 then
          cut = cut - 1
        else
          cut = cut - 1
          break
        end
      end
    end
    name = name:sub(1, cut)
  end

  if name == "" then
    name = "song"
  end
  return name .. songs.EXTENSION
end

-- ---------------------------------------------------------------------------
-- PURE: unique_name(exists_fn, name) -> name, or name-2 / name-3 / ...
-- ---------------------------------------------------------------------------
-- `exists_fn(name)` is asked whether a candidate is already taken.  A missing
-- or raising seam is treated as "nothing is taken" so this NEVER raises.

local function split_extension(name)
  local base, ext = name:match("^(.*)(%.[^%.]*)$")
  if base == nil or base == "" then
    return name, ""
  end
  return base, ext
end

function songs.unique_name(exists_fn, name)
  if type(name) ~= "string" or name == "" then
    name = "song" .. songs.EXTENSION
  end
  if type(exists_fn) ~= "function" then
    return name
  end

  local called, taken = pcall(exists_fn, name)
  if not called or not taken then
    return name
  end

  local base, ext = split_extension(name)
  local index = 2
  while index < 10000 do
    local candidate = base .. "-" .. tostring(index) .. ext
    local probed, exists = pcall(exists_fn, candidate)
    if not probed or not exists then
      return candidate
    end
    index = index + 1
  end
  return base .. "-" .. tostring(index) .. ext
end

-- ---------------------------------------------------------------------------
-- PURE: normalise_nbw(raw) -> one record
-- ---------------------------------------------------------------------------
-- Delegates the licence sentence and the attribution to net/nbw.lua so there is
-- exactly one owner of that wording.  Never raises; `title` and `author` are
-- always non-empty strings.
function songs.normalise_nbw(raw)
  local record = {
    kind = "nbw",
    ref = "",
    title = songs.UNTITLED,
    author = songs.UNKNOWN_AUTHOR,
    license = nil,
    attribution = nbw.attribution(raw),
    extra = raw,
  }

  if type(raw) ~= "table" then
    return record
  end

  local ref = non_empty_string(raw.publicId)
  if ref == nil then
    ref = non_empty_string(raw.id)
  end
  if ref == nil and type(raw.id) == "number" then
    ref = tostring(raw.id)
  end
  if ref ~= nil then
    record.ref = ref
  end

  local title = non_empty_string(raw.title)
  if title ~= nil then
    record.title = title
  end

  local author = nil
  if type(raw.uploader) == "table" then
    author = non_empty_string(raw.uploader.username)
  end
  if author == nil then
    author = non_empty_string(raw.originalAuthor)
  end
  if author ~= nil then
    record.author = author
  end

  local code = non_empty_string(raw.license)
  if code == nil then
    code = non_empty_string(raw.licence)
  end
  if code ~= nil then
    record.license = nbw.license_label(code)
  end

  return record
end

-- ---------------------------------------------------------------------------
-- local()
-- ---------------------------------------------------------------------------

local function entry_name(entry)
  if type(entry) == "string" then
    if entry ~= "" then
      return entry
    end
    return nil
  end
  if type(entry) == "table" then
    local name = entry.name
    if type(name) == "string" and name ~= "" then
      return name
    end
  end
  return nil
end

local function entry_is_directory(entry, fullpath, is_dir_fn)
  if type(entry) == "table" then
    if entry.isDir == true or entry.is_directory == true then
      return true
    end
    if entry.type == "directory" then
      return true
    end
  end
  if type(is_dir_fn) == "function" then
    local called, value = pcall(is_dir_fn, fullpath)
    if called and value == true then
      return true
    end
  end
  return false
end

local function is_nbs_name(name)
  return name:sub(-4):lower() == songs.EXTENSION
end

local function local_title(name)
  local base = strip_extension(name)
  if base == "" then
    base = name
  end
  return base
end

local function local_impl()
  local list_fn = resolve_list()
  local dir = config.dir
  if type(dir) ~= "string" then
    dir = DEFAULT_DIR
  end

  local entries = nil
  if type(list_fn) == "function" then
    local called, result = pcall(list_fn, dir)
    if called then
      entries = result
    end
  end
  if type(entries) ~= "table" then
    return {}
  end

  local is_dir_fn = resolve_is_dir()
  local candidates = {}
  for index = 1, #entries do
    local entry = entries[index]
    local name = entry_name(entry)
    if name ~= nil and is_nbs_name(name) then
      local fullpath = join_path(dir, name)
      if not entry_is_directory(entry, fullpath, is_dir_fn) then
        candidates[#candidates + 1] = {
          name = name,
          entry = entry,
          fullpath = fullpath,
        }
      end
    end
  end

  table.sort(candidates, function(left, right)
    return left.name < right.name
  end)

  local records = {}
  for index = 1, #candidates do
    local candidate = candidates[index]
    records[#records + 1] = {
      kind = "local",
      ref = candidate.fullpath,
      title = local_title(candidate.name),
      author = songs.UNKNOWN_AUTHOR,
      license = nil,
      attribution = nil,
      extra = candidate.entry,
    }
  end
  return records
end

local function local_songs()
  local called, result = pcall(local_impl)
  if called and type(result) == "table" then
    return result
  end
  return {}
end

-- The operation is named "local"; the bracket key keeps the exact name while
-- `local_songs` offers the same function through ordinary dot syntax.
songs["local"] = local_songs
songs.local_songs = local_songs

-- ---------------------------------------------------------------------------
-- search(opts)
-- ---------------------------------------------------------------------------
-- Accepts the options the UI needs (query, page, limit, sort, order, category)
-- and maps `query` onto net/nbw.lua's `q`.  The injected seams fill in any
-- transport/decoder the caller did not pass per call.
local function search_impl(opts)
  local arguments = shallow_copy(opts)
  if arguments.query ~= nil and arguments.q == nil then
    arguments.q = arguments.query
  end
  if arguments.http == nil and type(config.http) == "table" then
    arguments.http = config.http
  end
  if arguments.json_decode == nil and config.json_decode ~= nil then
    arguments.json_decode = config.json_decode
  end

  local result = nbw.search(arguments)
  if type(result) ~= "table" then
    return failure("search returned no result", "E_SONGS_INTERNAL")
  end
  if result.ok ~= true then
    -- A failure is a failure: pass it through in kind, never as an empty list.
    return result
  end

  local normalised = {}
  if type(result.songs) == "table" then
    for index = 1, #result.songs do
      local record = songs.normalise_nbw(result.songs[index])
      cache_record(record)
      normalised[#normalised + 1] = record
    end
  end

  return {
    ok = true,
    songs = normalised,
    page = result.page,
    limit = result.limit,
    total = result.total,
  }
end

function songs.search(opts)
  local called, result = pcall(search_impl, opts)
  if called and type(result) == "table" then
    return result
  end
  return failure("internal error: " .. tostring(result), "E_SONGS_INTERNAL")
end

-- ---------------------------------------------------------------------------
-- detail(id)
-- ---------------------------------------------------------------------------

local function detail_impl(public_id)
  local arguments = {}
  if type(config.http) == "table" then
    arguments.http = config.http
  end
  if config.json_decode ~= nil then
    arguments.json_decode = config.json_decode
  end

  local result = nbw.detail(public_id, arguments)
  if type(result) ~= "table" then
    return failure("detail returned no result", "E_SONGS_INTERNAL")
  end
  if result.ok ~= true then
    return result
  end

  local record = songs.normalise_nbw(result.song)
  cache_record(record)
  return { ok = true, song = record }
end

function songs.detail(public_id)
  local called, result = pcall(detail_impl, public_id)
  if called and type(result) == "table" then
    return result
  end
  return failure("internal error: " .. tostring(result), "E_SONGS_INTERNAL")
end

-- ---------------------------------------------------------------------------
-- download(id, dest_dir, on_progress, opts)
-- ---------------------------------------------------------------------------
-- THE one function that writes to disk.  It fetches the bytes through
-- net/nbw.lua (passing its typed failure -- e.g. E_SONG_COMPRESSED -- through
-- unchanged), writes them under a sanitised, collision-free name, and reports
-- progress when the byte count is knowable.

local function exists_path(exists_fn, path)
  if type(exists_fn) ~= "function" then
    return false
  end
  local called, value = pcall(exists_fn, path)
  return called and value == true
end

local function ensure_directory(filesystem, exists_fn, dir)
  if type(filesystem) ~= "table" then
    return true
  end
  if exists_path(exists_fn, dir) then
    return true
  end
  if type(filesystem.make_dir) ~= "function" then
    -- No way to make it: let the write attempt surface the real error.
    return true
  end
  local called, value = pcall(filesystem.make_dir, dir)
  return called and value ~= false
end

local function secure_write(write_fn, path, data)
  if type(write_fn) ~= "function" then
    return false, "no write function available"
  end
  local called, value, err = pcall(write_fn, path, data)
  if not called then
    return false, tostring(value)
  end
  if value ~= true then
    return false, tostring(err or "write did not report success")
  end
  return true
end

local function remove_file(filesystem, path)
  if type(filesystem) == "table" and type(filesystem.delete) == "function" then
    pcall(filesystem.delete, path)
  end
end

-- Resolve the display title used to name the downloaded file:
--   1. the caller's opts.title when supplied;
--   2. the record cached by search()/detail() for this id;
--   3. a best-effort detail lookup;
--   4. the raw id, so a usable name is ALWAYS produced.
local function resolve_title(public_id, options)
  if type(options) == "table" then
    local provided = non_empty_string(options.title)
    if provided ~= nil then
      return provided
    end
  end

  local cached = record_cache[public_id]
  if type(cached) == "table" then
    local cached_title = non_empty_string(cached.title)
    if cached_title ~= nil then
      return cached_title
    end
  end

  local detail = songs.detail(public_id)
  if detail.ok == true and type(detail.song) == "table" then
    local detail_title = non_empty_string(detail.song.title)
    if detail_title ~= nil then
      return detail_title
    end
  end

  return public_id
end

local function download_impl(public_id, dest_dir, on_progress, options)
  if type(public_id) ~= "string" or public_id == "" then
    return failure("download requires a non-empty publicId", "E_SONGS_ARGS")
  end
  if type(dest_dir) ~= "string" or dest_dir == "" then
    return failure("download requires a destination directory", "E_SONGS_ARGS")
  end

  local filesystem = resolve_fs()
  local exists_fn = resolve_exists()
  if type(filesystem) ~= "table" or type(exists_fn) ~= "function" then
    return failure("no filesystem available; inject a fs seam", "E_SONGS_NO_FS")
  end
  local write_fn = resolve_write()
  if type(write_fn) ~= "function" then
    return failure("no write function available; inject a write seam",
      "E_SONGS_NO_FS")
  end

  local title = resolve_title(public_id, options)
  -- The collision check must look in the DESTINATION directory: unique_name
  -- asks this closure whether "name" is taken, so we probe dest_dir/name.
  local function destination_taken(name)
    return exists_path(exists_fn, join_path(dest_dir, name))
  end
  local filename = songs.unique_name(destination_taken, songs.safe_filename(title))
  local final_path = join_path(dest_dir, filename)
  local temp_path = final_path .. ".part"

  if not ensure_directory(filesystem, exists_fn, dest_dir) then
    return failure("could not create the destination directory " .. dest_dir,
      "E_SONGS_WRITE")
  end

  local fetch_options = {}
  if type(config.http) == "table" then
    fetch_options.http = config.http
  end
  if type(options) == "table" then
    if options.http ~= nil then
      fetch_options.http = options.http
    end
    if options.token ~= nil then
      fetch_options.token = options.token
    end
    if options.timeout ~= nil then
      fetch_options.timeout = options.timeout
    end
  end

  local fetched = nbw.download(public_id, fetch_options)
  if type(fetched) ~= "table" or fetched.ok ~= true then
    local code = "E_SONGS_DOWNLOAD"
    local message = "download failed"
    if type(fetched) == "table" then
      if fetched.code ~= nil then
        code = fetched.code
      end
      if fetched.error ~= nil then
        message = fetched.error
      end
    end
    return failure(message, code)
  end

  local data = fetched.data
  if type(data) ~= "string" then
    return failure("download returned no bytes", "E_SONGS_DOWNLOAD")
  end

  local total = #data
  if type(on_progress) == "function" then
    pcall(on_progress, 0, total)
  end

  local move_fn = filesystem.move
  if type(move_fn) == "function" then
    -- Preferred: write a temporary file, then rename it into place.  A failure
    -- at either step removes the partial file, so the final path is only ever
    -- the destination of a COMPLETE song.
    local wrote, write_error = secure_write(write_fn, temp_path, data)
    if not wrote then
      remove_file(filesystem, temp_path)
      return failure("could not write the song file: " .. tostring(write_error),
        "E_SONGS_WRITE")
    end
    local moved_ok, moved = pcall(move_fn, temp_path, final_path)
    if not moved_ok or moved ~= true then
      remove_file(filesystem, temp_path)
      return failure("could not finalise the song file", "E_SONGS_WRITE")
    end
  else
    -- No rename seam: write the final path directly and delete it on failure.
    local wrote, write_error = secure_write(write_fn, final_path, data)
    if not wrote then
      remove_file(filesystem, final_path)
      return failure("could not write the song file: " .. tostring(write_error),
        "E_SONGS_WRITE")
    end
  end

  if type(on_progress) == "function" then
    pcall(on_progress, total, total)
  end
  return { ok = true, path = final_path, bytes = total }
end

function songs.download(public_id, dest_dir, on_progress, options)
  local called, result =
    pcall(download_impl, public_id, dest_dir, on_progress, options)
  if called and type(result) == "table" then
    return result
  end
  return failure("internal error: " .. tostring(result), "E_SONGS_INTERNAL")
end

-- ---------------------------------------------------------------------------
-- configure(opts)
-- ---------------------------------------------------------------------------
-- Merges the provided seam fields into the active configuration.  Passing nil
-- (or no argument) CLEARS every seam and the title cache -- the explicit reset
-- a test or a re-launch needs.
function songs.configure(opts)
  if opts == nil then
    config = {}
    record_cache = {}
    return songs
  end
  if type(opts) ~= "table" then
    return songs
  end
  for key, value in pairs(opts) do
    config[key] = value
  end
  return songs
end

return songs
