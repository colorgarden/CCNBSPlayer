-- ui/presenter.lua
--
-- THE PURE PRESENTATION LAYER -- player state in, displayable strings out.
--
-- ===========================================================================
-- WHY THIS MODULE IS PURE (and must stay so)
-- ===========================================================================
-- The project is replacing its hand-written terminal UI (player/tui.lua) with
-- the Basalt2 framework.  Basalt has NO headless mode, no mock terminal and no
-- test helpers: its run() blocks in its own event loop and is unusable in a
-- unit test.  So the framework layer is an UNTESTABLE integration layer, and
-- the ONLY way to keep the displayed behaviour verified is to move every
-- "what should the user see" decision into the pure functions HERE, leaving
-- Basalt as a dumb renderer.
--
-- Consequently this module contains NO UI framework, NO terminal call, NO
-- peripheral, NO clock and NO I/O.  It is requireable and testable in plain
-- Lua, and every function is total: it returns a string / table / integer for
-- ANY input and NEVER raises and NEVER renders the Lua `nil`.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local presenter = require("ui.presenter")
--
--   presenter.format_time(seconds)                   -> "MM:SS" | "H:MM:SS"
--       nil / negative / non-number -> "00:00".
--   presenter.progress_percent(position, duration)   -> integer 0..100, clamped
--       duration <= 0 or non-number -> 0 (never a division by zero).
--   presenter.song_label(song)                       -> one list-row line
--   presenter.song_detail(song)                      -> { line, ... }
--   presenter.attribution_line(song)                 -> author credit + link
--   presenter.transport_status(state)                -> "Playing  MM:SS / MM:SS"
--                                                       | "Paused" | "Stopped"
--   presenter.playback_lines(state, analysis, found) -> { line, ... }
--   presenter.local_song_items(files)                -> { {text,kind,ref}, ... }
--   presenter.nbw_song_items(songs)                  -> { {text,kind,ref}, ... }
--   presenter.list_item_count(items)                 -> integer
--   presenter.warning_lines(analysis, found)         -> { WARN line, ... } (maybe empty)
--   presenter.transport_help()                       -> key hints, localised
--   presenter.language_toggle_label()                -> what the key switches TO
--
-- ===========================================================================
-- WHO OWNS WHICH SENTENCE (nothing is re-implemented here)
-- ===========================================================================
--   * WARNING text is NOT formatted here.  warning_lines DELEGATES to
--     player/warnings.lua and only DECIDES WHICH codes apply (derived from the
--     analysis), so the `WARN[<code>]` protocol stays byte-identical.
--   * LICENCE wording is NOT written here.  song_detail delegates to
--     net/nbw.lua's license_label()/attribution(), so the two licences
--     ("standard" personal-listening-only vs "cc_by_sa") always render their
--     own, correct text.
--
--     net/nbw.lua is resolved as a LAZY, SOFT dependency (the same pattern
--     player/tui.lua uses for player/warnings.lua), because it is a runtime
--     module the installer's manifest does not ship yet and this module's
--     file-ownership boundary forbids editing installer.lua/installer.manifest
--     from here.  When the client is present -- which it is in the checkout and
--     in every test -- the wording is delegated to it.  The installer lane must
--     add `net/nbw.lua` (and this module) to the manifest when it wires the
--     Basalt UI; until then a lean install degrades to the raw licence code
--     rather than raising or rendering a nil.
--   * SPEAKER arithmetic is NOT recomputed here.  nbs/speakers.lua owns the
--     formula; this module only presents assess()'s result.
--
-- ===========================================================================
-- WHY THE SENTENCES LIVE IN A LOCAL TABLE (not ui/i18n.lua)
-- ===========================================================================
-- ui/i18n.lua is the shared prose module, but its FROZEN interface
-- (DEFAULT_LANGUAGE / languages / set_language / get_language / t / has /
-- missing_keys / translations) has NO key-registration API, so a new module
-- cannot add keys without editing it -- and this module must NOT edit a module
-- owned elsewhere.  Exactly as qa/ingame.lua already does, presenter.lua keeps
-- its OWN sentences in the L10N table below (one entry per language) and asks
-- i18n.get_language() which one is active.  Placeholders are NAMED ({title})
-- so Chinese can reorder them.  Warning and licence prose still go through
-- ui/i18n.lua indirectly, via player/warnings.lua and net/nbw.lua.
--
-- ===========================================================================
-- THE LICENCE DISPLAY IS A REQUIREMENT, NOT DECORATION
-- ===========================================================================
-- Half of the Note Block World catalogue is "standard" (personal listening
-- only), so song_detail() ALWAYS emits a licence line: the real label when the
-- song carries a licence, and an explicit "not specified" line otherwise.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.

local i18n = require("ui.i18n")
local warnings = require("player.warnings")
local speakers = require("nbs.speakers")

local presenter = {}

-- ---------------------------------------------------------------------------
-- Lazy soft dependency: the Note Block World client (licence/attribution owner)
-- ---------------------------------------------------------------------------
-- Resolved on first use and held, so this module stays requireable (and total)
-- even on an install that does not ship net/nbw.lua yet.  When it IS present,
-- all licence and attribution wording is delegated to it -- none is
-- re-implemented here.
--
-- The name is written as a LITERAL inside the pcall on purpose.  Naming it
-- through a variable would work at runtime but would hide the dependency from
-- the installer's manifest check, which scans the source for literal
-- `require("...")` / `pcall(require, "...")` calls to prove that a fresh
-- install ships everything the runtime needs.  Hiding it there would let a
-- missing module slip through with nothing to warn anyone, and the licence
-- text would silently degrade in production.  Keep it literal.
local nbw_cache = nil
local nbw_probed = false

local function nbw_client()
  if not nbw_probed then
    nbw_probed = true
    local ok, module = pcall(require, "net.nbw")
    if ok and type(module) == "table" then
      nbw_cache = module
    end
  end
  return nbw_cache
end

-- ---------------------------------------------------------------------------
-- Presentation prose -- one entry per language, NAMED placeholders only
-- ---------------------------------------------------------------------------

local DEFAULT_LANGUAGE = "en"

local L10N = {
  en = {
    ["presenter.untitled"] = "Untitled song",
    ["presenter.unknown_uploader"] = "Unknown uploader",
    ["presenter.detail.title"] = "Title: {title}",
    ["presenter.detail.author"] = "Author: {author}",
    ["presenter.detail.license"] = "License: {license}",
    ["presenter.detail.license_unknown"] =
      "License: not specified for this local file",
    ["presenter.detail.notes"] = "Notes: {count}",
    ["presenter.detail.attribution"] = "Credit: {credit}",
    ["presenter.playback.speakers_ok"] =
      "Speakers: {found} attached (need {required})",
    ["presenter.playback.speakers_short"] =
      "Speakers: {found} attached, but {required} are needed",
    ["presenter.transport.playing"] = "Playing  {position} / {duration}",
    ["presenter.transport.playing_plain"] = "Playing",
    ["presenter.transport.paused"] = "Paused",
    ["presenter.transport.stopped"] = "Stopped",
    ["presenter.transport.help"] = "Space/P pause or resume  |  S/Q stop",
    ["presenter.language.toggle_to"] = "Language: switch to {language}",
    ["presenter.language.name.en"] = "English",
    ["presenter.language.name.zh"] = "Chinese",
    ["presenter.local_item"] = "{index}. {title}",
    ["presenter.nbw_item"] = "{title} - {uploader}",
  },
  zh = {
    ["presenter.untitled"] = "未命名歌曲",
    ["presenter.unknown_uploader"] = "未知上传者",
    ["presenter.detail.title"] = "标题：{title}",
    ["presenter.detail.author"] = "作者：{author}",
    ["presenter.detail.license"] = "许可：{license}",
    ["presenter.detail.license_unknown"] = "许可：本地文件未提供许可信息",
    ["presenter.detail.notes"] = "音符数：{count}",
    ["presenter.detail.attribution"] = "署名：{credit}",
    ["presenter.playback.speakers_ok"] =
      "扬声器：已连接 {found} 个（需要 {required} 个）",
    ["presenter.playback.speakers_short"] =
      "扬声器：已连接 {found} 个，但需要 {required} 个",
    ["presenter.transport.playing"] = "播放中  {position} / {duration}",
    ["presenter.transport.playing_plain"] = "播放中",
    ["presenter.transport.paused"] = "已暂停",
    ["presenter.transport.stopped"] = "已停止",
    ["presenter.transport.help"] = "空格/P 暂停或继续  ｜  S/Q 停止",
    ["presenter.language.toggle_to"] = "语言：切换到 {language}",
    ["presenter.language.name.en"] = "English",
    ["presenter.language.name.zh"] = "中文",
    ["presenter.local_item"] = "{index}. {title}",
    ["presenter.nbw_item"] = "{title} - {uploader}",
  },
}

-- active_language() -> the code reported by ui/i18n.lua, defaulting to "en".
local function active_language()
  local code = i18n.get_language()
  if type(code) == "string" and L10N[code] ~= nil then
    return code
  end
  return DEFAULT_LANGUAGE
end

-- Replace "{name}" placeholders from args, leaving an unmatched one intact so a
-- Lua `nil` can NEVER reach a rendered string.  Plain byte gsub; no utf8.*.
local function substitute(text, args)
  if type(text) ~= "string" then
    return text
  end
  return (text:gsub("{([%w_]+)}", function(name)
    local value = args[name]
    if value == nil then
      return "{" .. name .. "}"
    end
    return tostring(value)
  end))
end

-- tr(key, args) -> the sentence for `key` in the ACTIVE language.  Never raises
-- and never returns nil: an unknown language falls back to English, and an
-- unknown key returns the key itself (a visible, greppable gap).
local function tr(key, args)
  local table_for_language = L10N[active_language()] or L10N[DEFAULT_LANGUAGE]
  local text = table_for_language[key]
  if type(text) ~= "string" then
    text = L10N[DEFAULT_LANGUAGE][key]
  end
  if type(text) ~= "string" then
    return key
  end
  if type(args) ~= "table" then
    args = {}
  end
  return substitute(text, args)
end

-- ---------------------------------------------------------------------------
-- Small defensive readers over a song of either shape
-- ---------------------------------------------------------------------------

local function non_empty_string(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

-- song_title(song) -> title | nil.  A Note Block World API song carries
-- `title`; a decoded .nbs song carries `header.name`.
local function song_title(song)
  if type(song) ~= "table" then
    return nil
  end
  local title = non_empty_string(song.title)
  if title ~= nil then
    return title
  end
  local header = song.header
  if type(header) == "table" then
    return non_empty_string(header.name)
  end
  return nil
end

-- song_author(song) -> author | nil, preferring the original author (the
-- fallback chain the frozen interface specifies), then the uploader, then the
-- decoded header's author fields.
local function song_author(song)
  if type(song) ~= "table" then
    return nil
  end
  local author = non_empty_string(song.originalAuthor)
  if author ~= nil then
    return author
  end
  if type(song.uploader) == "table" then
    author = non_empty_string(song.uploader.username)
    if author ~= nil then
      return author
    end
  end
  local header = song.header
  if type(header) == "table" then
    author = non_empty_string(header.author)
    if author ~= nil then
      return author
    end
    return non_empty_string(header.original_author)
  end
  return nil
end

-- song_uploader(song) -> the display name for a list row, or nil.  Kept
-- separate from song_author so a list row credits the uploader even when the
-- author fallback above would pick the original author.
local function song_uploader(song)
  if type(song) ~= "table" then
    return nil
  end
  if type(song.uploader) == "table" then
    local name = non_empty_string(song.uploader.username)
    if name ~= nil then
      return name
    end
  end
  return song_author(song)
end

-- song_id(song) -> publicId / id as a string, or nil.
local function song_id(song)
  if type(song) ~= "table" then
    return nil
  end
  local id = non_empty_string(song.publicId)
  if id ~= nil then
    return id
  end
  id = non_empty_string(song.id)
  if id ~= nil then
    return id
  end
  if type(song.id) == "number" then
    return tostring(song.id)
  end
  return nil
end

-- A minimal, non-interpreting credit used ONLY when the Note Block World client
-- is unavailable, so an attribution line is still produced and the Lua nil
-- never leaks.  It does NOT interpret a licence or reproduce nbw's wording.
local function fallback_credit(song)
  local title = song_title(song)
  if title == nil then
    title = presenter.song_label(song)
  end
  local uploader = song_uploader(song)
  if uploader == nil then
    return title
  end
  return title .. " - " .. uploader
end

-- ---------------------------------------------------------------------------
-- Time and progress
-- ---------------------------------------------------------------------------

-- format_time(seconds) -> "MM:SS", or "H:MM:SS" past an hour.
-- nil / negative / non-number / NaN / infinity -> "00:00".
function presenter.format_time(seconds)
  if type(seconds) ~= "number" then
    return "00:00"
  end
  if seconds ~= seconds or seconds == math.huge or seconds == -math.huge then
    return "00:00"
  end
  if seconds < 0 then
    return "00:00"
  end

  local total = math.floor(seconds)
  local hours = math.floor(total / 3600)
  local minutes = math.floor(total / 60) % 60
  local secs = total % 60

  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, secs)
  end
  return string.format("%02d:%02d", minutes, secs)
end

-- progress_percent(position, duration) -> integer 0..100, clamped.
-- A non-positive / non-number duration, or a non-number position, yields 0
-- WITHOUT dividing (so there is never a division by zero).
function presenter.progress_percent(position, duration)
  if type(position) ~= "number" or type(duration) ~= "number" then
    return 0
  end
  if position ~= position or duration ~= duration then
    return 0
  end
  if duration <= 0 then
    return 0
  end
  if position <= 0 then
    return 0
  end
  if position >= duration then
    return 100
  end
  return math.floor(position / duration * 100)
end

-- ---------------------------------------------------------------------------
-- Song identification
-- ---------------------------------------------------------------------------

-- song_label(song) -> one non-empty line, falling back through
-- title -> original author -> song id -> a generic placeholder.
function presenter.song_label(song)
  local title = song_title(song)
  if title ~= nil then
    return title
  end
  local author = song_author(song)
  if author ~= nil then
    return author
  end
  local id = song_id(song)
  if id ~= nil then
    return id
  end
  return tr("presenter.untitled")
end

-- song_detail(song) -> { line, ... }.  Includes, when the data is present:
-- the title, the author, the LICENCE (delegated to net/nbw.lua) and the
-- attribution line.  The licence line is ALWAYS present -- a missing licence
-- renders an explicit "not specified" sentence, never the Lua nil.
function presenter.song_detail(song)
  local lines = {}
  if type(song) ~= "table" then
    return lines
  end

  local title = song_title(song)
  if title == nil then
    title = presenter.song_label(song)
  end
  lines[#lines + 1] = tr("presenter.detail.title", { title = title })

  local author = song_author(song)
  if author ~= nil then
    lines[#lines + 1] = tr("presenter.detail.author", { author = author })
  end

  -- The LICENCE line is mandatory: use the real label when the song carries a
  -- licence, otherwise say so explicitly.  Wording is owned by net/nbw.lua.
  local license_code = non_empty_string(song.license)
  if license_code == nil then
    license_code = non_empty_string(song.licence)
  end
  if license_code ~= nil then
    local client = nbw_client()
    local license_text = license_code
    if client ~= nil and type(client.license_label) == "function" then
      license_text = client.license_label(license_code)
    end
    lines[#lines + 1] = tr("presenter.detail.license",
      { license = license_text })
  else
    lines[#lines + 1] = tr("presenter.detail.license_unknown")
  end

  if type(song.stats) == "table" and type(song.stats.noteCount) == "number" then
    lines[#lines + 1] = tr("presenter.detail.notes",
      { count = tostring(song.stats.noteCount) })
  end

  local client = nbw_client()
  local credit = fallback_credit(song)
  if client ~= nil and type(client.attribution) == "function" then
    credit = client.attribution(song)
  end
  lines[#lines + 1] = tr("presenter.detail.attribution", { credit = credit })

  return lines
end

-- attribution_line(song) -> author credit + song-page link.  Delegated to
-- net/nbw.lua so the attribution wording has ONE owner.
function presenter.attribution_line(song)
  local client = nbw_client()
  if client ~= nil and type(client.attribution) == "function" then
    return client.attribution(song)
  end
  return fallback_credit(song)
end

-- ---------------------------------------------------------------------------
-- Playback
-- ---------------------------------------------------------------------------

-- transport_status(state) -> the single-line transport summary.
-- `state.status` ("playing" / "paused" / "stopped") wins; otherwise the
-- booleans `state.paused` / `state.playing` are honoured; anything else reads
-- as stopped.  A playing state with numeric position/duration shows both times
-- around a separator.
function presenter.transport_status(state)
  local status = "stopped"
  local position = nil
  local duration = nil

  if type(state) == "table" then
    position = state.position
    duration = state.duration
    if type(state.status) == "string" then
      local lowered = state.status:lower()
      if lowered == "playing" or lowered == "paused" or lowered == "stopped" then
        status = lowered
      end
    elseif state.paused == true then
      status = "paused"
    elseif state.playing == true then
      status = "playing"
    end
  end

  if status == "playing" then
    if type(position) == "number" and type(duration) == "number" then
      return tr("presenter.transport.playing", {
        position = presenter.format_time(position),
        duration = presenter.format_time(duration),
      })
    end
    return tr("presenter.transport.playing_plain")
  elseif status == "paused" then
    return tr("presenter.transport.paused")
  end
  return tr("presenter.transport.stopped")
end

-- warning_lines(analysis, speakers_found) -> { WARN line, ... }.
--
-- Delegates the TEXT to player/warnings.lua and only decides WHICH codes apply,
-- each derived from the analysis (never invented):
--   * extended-range  -- analysis.has_extended_range
--   * speakers        -- nbs/speakers.assess() reports a shortfall
--   * custom-instrument -- analysis.custom_notes_at_peak > 0
-- Returns an EMPTY table when there is nothing to warn about.
function presenter.warning_lines(analysis, speakers_found)
  local lines = {}
  local a = analysis
  if type(a) ~= "table" then
    a = {}
  end

  if a.has_extended_range == true then
    lines[#lines + 1] = warnings.format(warnings.CODES.EXTENDED_RANGE, {
      min_key = a.min_key,
      max_key = a.max_key,
    })
  end

  local found = speakers_found
  if type(found) ~= "number" then
    found = 0
  end
  local assessment = speakers.assess(a, found)
  if assessment.sufficient ~= true then
    lines[#lines + 1] = warnings.format(warnings.CODES.SPEAKERS, {
      peak = a.peak_concurrent,
      required = assessment.required,
      found = assessment.found,
    })
  end

  local custom = a.custom_notes_at_peak
  if type(custom) == "number" and custom > 0 then
    lines[#lines + 1] = warnings.format(warnings.CODES.CUSTOM_INSTRUMENT,
      { count = custom })
  end

  return lines
end

-- playback_lines(state, analysis, speakers_found) -> { line, ... }.
--
-- The SINGLE call a view makes to render the "what the user needs to know
-- before/while this plays" block.  Order matters and is deliberate: the song
-- identity FIRST, then the speaker situation, then the warnings -- the user
-- learns WHAT is playing before being told what is wrong with it.
function presenter.playback_lines(state, analysis, speakers_found)
  local lines = {}
  local a = analysis
  if type(a) ~= "table" then
    a = {}
  end

  -- 1. Identity (title / author / licence / attribution).
  local song = nil
  if type(state) == "table" then
    song = state.song
  end
  if type(song) == "table" then
    local detail = presenter.song_detail(song)
    for index = 1, #detail do
      lines[#lines + 1] = detail[index]
    end
  else
    lines[#lines + 1] = tr("presenter.detail.title",
      { title = presenter.song_label(song) })
  end

  -- 2. The speaker situation (requirement vs found).
  local found = speakers_found
  if type(found) ~= "number" then
    found = 0
  end
  local assessment = speakers.assess(a, found)
  local key = "presenter.playback.speakers_short"
  if assessment.sufficient == true then
    key = "presenter.playback.speakers_ok"
  end
  lines[#lines + 1] = tr(key, {
    found = tostring(assessment.found),
    required = tostring(assessment.required),
  })

  -- 3. Warnings.
  local warns = presenter.warning_lines(a, found)
  for index = 1, #warns do
    lines[#lines + 1] = warns[index]
  end

  return lines
end

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------

-- local_song_items(files) -> { { text =, kind = "local", ref = <path> }, ... }.
-- Non-string / empty entries are skipped, so a row's `text` is never blank.
function presenter.local_song_items(files)
  local items = {}
  if type(files) ~= "table" then
    return items
  end
  for index = 1, #files do
    local path = files[index]
    if type(path) == "string" and path ~= "" then
      items[#items + 1] = {
        text = tr("presenter.local_item", {
          index = tostring(#items + 1),
          title = path,
        }),
        kind = "local",
        ref = path,
      }
    end
  end
  return items
end

-- nbw_song_items(songs) -> { { text =, kind = "nbw", ref = <publicId> }, ... }.
-- Non-table entries are skipped; `ref` is always a string.
function presenter.nbw_song_items(songs)
  local items = {}
  if type(songs) ~= "table" then
    return items
  end
  for index = 1, #songs do
    local song = songs[index]
    if type(song) == "table" then
      local title = song_title(song)
      if title == nil then
        title = presenter.song_label(song)
      end
      local uploader = song_uploader(song)
      if uploader == nil then
        uploader = tr("presenter.unknown_uploader")
      end
      local id = song_id(song)
      local ref = ""
      if id ~= nil then
        ref = id
      end
      items[#items + 1] = {
        text = tr("presenter.nbw_item", { title = title, uploader = uploader }),
        kind = "nbw",
        ref = ref,
      }
    end
  end
  return items
end

-- list_item_count(items) -> #items, or 0 for nil / non-table.
function presenter.list_item_count(items)
  if type(items) ~= "table" then
    return 0
  end
  return #items
end

-- ---------------------------------------------------------------------------
-- Help / affordances -- both reflect the ACTIVE language
-- ---------------------------------------------------------------------------

-- transport_help() -> the transport key hints, in the active language.
function presenter.transport_help()
  return tr("presenter.transport.help")
end

-- language_toggle_label() -> what the language key will switch TO, in the
-- active language.  Picks a language code other than the active one.
function presenter.language_toggle_label()
  local active = active_language()
  local target = active

  local codes = i18n.languages()
  for index = 1, #codes do
    if codes[index] ~= active then
      target = codes[index]
      break
    end
  end

  local name = tr("presenter.language.name." .. target)
  return tr("presenter.language.toggle_to", { language = name })
end

return presenter
