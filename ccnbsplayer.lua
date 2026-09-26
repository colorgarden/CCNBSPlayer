-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSPlayer. Licensed under GPL-2.0; see LICENSE.
--
-- ccnbsplayer.lua
--
-- THE ROOT-LEVEL PROGRAM A USER RUNS.
--
--   ccnbsplayer           -- run from CC:Tweaked (or `lua ccnbsplayer.lua`)
--
-- It does three things and nothing else: assemble the screen builders, hand them
-- to the shell, and report the resulting exit code.  Every decision about how
-- the interface looks or behaves lives in the modules it names, so this file
-- holds no logic worth testing and stays a stable entry point.
--
-- ===========================================================================
-- WHY THE SCREENS ARE ASSEMBLED HERE RATHER THAN INSIDE THE SHELL
-- ===========================================================================
-- The shell knows how to lay out and route; it should not also know which pages
-- exist, or adding a page would mean editing the shell.  A table of
-- `id -> builder` keeps the shell generic and makes the page list a single
-- readable declaration -- which is also what lets a test drive the shell with
-- fake builders instead of real screens.
--
-- The old UI (ui/basalt_app.lua) is still shipped and still tested, so rolling
-- back is a one-line change here rather than a reinstall.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.

-- ---------------------------------------------------------------------------
-- Loading is DEFENSIVE, because a partial install must still start
-- ---------------------------------------------------------------------------
-- `safe_require` returns nil instead of raising.  A missing screen then costs
-- the user that one page rather than the whole program, and the shell already
-- treats an absent builder as "this route does not exist".
-- `try(ok, value)` unpacks a protected require: the module when it loaded, nil
-- otherwise.  Written this way so every dependency is loaded through a LITERAL
-- `pcall(require, "...")` -- the exact shape the installer's drift guard scans
-- for.  A wrapper that resolved `require` into a local first would work at run
-- time and be INVISIBLE to the guard, which is how a shipping bug slipped
-- through this project before.
local function try(ok, value)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

local shell = try(pcall(require, "ui.app_shell"))

-- A missing shell is the one failure worth reporting clearly: without it the
-- program cannot draw anything, and a silent exit would look like a hang.
if shell == nil then
  local printer = rawget(_G, "print")
  if type(printer) == "function" then
    printer("CCNBSPlayer: ui/app_shell.lua is missing; the install is incomplete.")
    printer("Re-run the installer:  wget run <repo>/installer.lua")
  end
  return 1
end

local frame = try(pcall(require, "ui.screens.frame"))

local home = try(pcall(require, "ui.screens.home"))
local browse = try(pcall(require, "ui.screens.browse"))
local library = try(pcall(require, "ui.screens.library"))
local detail_screen = try(pcall(require, "ui.screens.detail"))
local settings_screen = try(pcall(require, "ui.screens.settings"))
local about = try(pcall(require, "ui.screens.about"))
local help_screen = try(pcall(require, "ui.screens.help"))

local songs = try(pcall(require, "ui.songs"))
local transport = try(pcall(require, "ui.transport"))
local icons = try(pcall(require, "ui.icons"))
local ime = try(pcall(require, "ui.ime"))
local store = try(pcall(require, "ui.settings"))
local history = try(pcall(require, "ui.history"))
local nbw = try(pcall(require, "net.nbw"))
local cjk = try(pcall(require, "ui.cjk"))
local ccnbs = try(pcall(require, "ccnbs"))

-- ---------------------------------------------------------------------------
-- Shared state
-- ---------------------------------------------------------------------------
-- `overlay` holds the pages that are NOT routes.  The settings window is opened
-- over whatever page is showing rather than navigating to it, so it has to be
-- reachable from anywhere.
local overlay = {}

-- read_file(path) -> bytes | nil, using the live filesystem lazily.
local function read_file(path)
  if type(path) ~= "string" then
    return nil
  end
  local fs = rawget(_G, "fs")
  if type(fs) ~= "table" or type(fs.open) ~= "function" then
    return nil
  end
  local ok, handle = pcall(fs.open, path, "rb")
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

-- play_song(record) -> boolean
-- Turns a normalised record into playback.  A local file is read from disk; an
-- NBW song is downloaded first when it is not already here.
local function play_song(record)
  if type(transport) ~= "table" or type(ccnbs) ~= "table" then
    return false
  end
  if type(record) ~= "table" or type(record.ref) ~= "string" then
    return false
  end

  local bytes = nil
  if record.kind == "local" then
    bytes = read_file(record.ref)
  elseif record.kind == "nbw" and type(songs) == "table"
    and type(songs.download) == "function" then
    local ok, result = pcall(songs.download, record.ref, ".")
    if ok and type(result) == "table" and result.ok == true then
      bytes = read_file(result.path)
    end
  end
  if bytes == nil then
    return false
  end

  local decoded = ccnbs.decode(bytes)
  if type(decoded) ~= "table" or decoded.ok ~= true then
    return false
  end

  local analysis = ccnbs.analyze(decoded.song)
  local events = ccnbs.plan(decoded.song, analysis)

  -- Recorded before playing, so a song that crashes the scheduler still appears
  -- in "recently played" rather than vanishing.
  if type(history) == "table" and type(history.record) == "function" then
    pcall(history.record, record)
  end

  local played = transport.play(events, analysis)
  return type(played) == "table" and played.ok ~= false
end

-- A helper that copies the shell's context and bolts on the per-screen extras,
-- so a builder never receives the raw context and mutates it for the next one.
local function extend(ctx, extra)
  local inner = {}
  for key, value in pairs(ctx) do
    inner[key] = value
  end
  for key, value in pairs(extra or {}) do
    inner[key] = value
  end
  return inner
end

-- open_detail(item, ctx) -- show a song on the detail page and navigate to it.
local function open_detail(item, ctx)
  if type(overlay.detail) == "table"
    and type(overlay.detail.show) == "function" then
    overlay.detail.show(item)
  end
  if type(ctx) == "table" and type(ctx.navigate) == "function" then
    ctx.navigate("detail")
  end
end

-- download_item(item, ctx, report) -- the ONE place a download is started, so
-- every screen behaves the same way about where files land and what is said.
local function download_item(item, ctx, report)
  if type(songs) ~= "table" or type(songs.download) ~= "function" then
    if type(report) == "function" then
      report("download unavailable")
    end
    return
  end
  if type(item) ~= "table" or type(item.ref) ~= "string" then
    return
  end
  local function run()
    local ok, result = pcall(songs.download, item.ref, ".")
    if type(report) ~= "function" then
      return
    end
    if ok and type(result) == "table" and result.ok == true then
      report(ctx.tr("app.download_done", { name = tostring(result.path or "") }))
    elseif type(result) == "table" then
      -- The typed failure is surfaced rather than flattened: a compressed song
      -- fails with a code that tells the user to use the song page instead.
      report(ctx.tr("app.download_failed", {
        name = tostring(item.title or ""),
        detail = tostring(result.code or result.error or ""),
      }))
    else
      report(ctx.tr("app.download_failed",
        { name = tostring(item.title or ""), detail = "?" }))
    end
  end
  -- Inside a scheduled coroutine: a download must not block the event loop.
  ctx.schedule(run)
end

-- ---------------------------------------------------------------------------
-- The screen builders
-- ---------------------------------------------------------------------------
-- The keys ARE the route names the sidebar and the top bar navigate to, so the
-- two cannot drift: a button naming a route absent from this table simply does
-- nothing, which is visible, rather than crashing.
local screens = {}

if home ~= nil then
  screens.home = function(ctx)
    return home.build(extend(ctx, { on_play = play_song }))
  end
end

local function browse_page(builder)
  return function(ctx)
    return builder(extend(ctx, {
      nbw = nbw,
      on_activate = function(item)
        open_detail(item, ctx)
      end,
      on_download = function(item)
        download_item(item, ctx)
      end,
    }))
  end
end

if browse ~= nil then
  screens.browse = browse_page(browse.build_discover)
  screens.search = browse_page(browse.build_search)
  -- 随机 reuses the discover page: the API has no "random" endpoint, and a
  -- differently sorted list is the honest approximation of "surprise me".
  screens.roaming = browse_page(browse.build_discover)
end

if library ~= nil then
  local function library_page(builder)
    return function(ctx)
      return builder(extend(ctx, { on_play = play_song }))
    end
  end
  screens.local_files = library_page(library.build_local)
  screens.downloads = library_page(library.build_downloads)
  screens.likes = library_page(library.build_likes)
  screens.recent = library_page(library.build_recent)
end

if detail_screen ~= nil then
  screens.detail = function(ctx)
    local page = detail_screen.build(extend(ctx, {
      nbw = nbw,
      on_play = play_song,
      on_download = function(item, report)
        download_item(item, ctx, report)
      end,
    }))
    overlay.detail = page
    return page
  end
end

if settings_screen ~= nil then
  screens.settings = function(ctx)
    local page = settings_screen.build(extend(ctx, { ime = ime }))
    overlay.settings = page
    return page
  end
end

if about ~= nil then
  screens.about = function(ctx)
    return about.build(extend(ctx, { version = shell.VERSION }))
  end
end

if help_screen ~= nil then
  screens.help = function(ctx)
    return help_screen.build(ctx)
  end
end

-- ---------------------------------------------------------------------------
-- Go
-- ---------------------------------------------------------------------------
local result = shell.run({
  screens = screens,
  songs = songs,
  transport = transport,
  icons = icons,
  ime = ime,
  settings = store,
  history = history,
  frame = frame,
  nbw = nbw,
  cjk = cjk,
})

local exit_code = 0
if type(result) == "table" and type(result.exit_code) == "number" then
  exit_code = result.exit_code
end

return exit_code
