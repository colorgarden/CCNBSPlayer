-- ui/screens/library.lua
--
-- THE FOUR LOCAL COLLECTIONS -- 本地 / 下载 / 收藏 / 最近播放.
--
-- The reference keeps these on its server because it has accounts: its sidebar
-- has 喜欢 / 收藏 / 最近, all fetched.  We have no accounts, so all four are
-- local, which makes them faster and independent of the network -- and it is why
-- this is one module producing four pages rather than four modules.
--
--   reference        ours
--   -------------    ---------------------------------------------------
--   喜欢 (Liked)     收藏 -- favourites, from ui/history
--   收藏 (Saved)     下载 -- songs downloaded into the working directory
--   最近 (History)   最近播放 -- recently played, from ui/history
--   (no counterpart) 本地 -- every .nbs file on this computer
--
-- ===========================================================================
-- EMPTY STATES ARE PER-PAGE, NOT SHARED
-- ===========================================================================
-- "No favourites yet" and "no songs downloaded yet" are different situations
-- with different remedies, so each page supplies its own hint.  A single shared
-- "nothing here" would leave the user unable to tell which list they were
-- looking at.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local library = {}

local collection = nil

local function collection_module(ctx)
  if type(ctx) == "table" and type(ctx.collection) == "table" then
    return ctx.collection
  end
  if collection == nil then
    -- Written as pcall(require, "literal") because this project's drift guard
    -- scans for exactly that shape.  Resolving require into a local first works
    -- at run time but hides the dependency from the guard, and an invisible
    -- dependency is how a shipping bug slipped through here before.
    local ok, value = pcall(require, "ui.screens.collection")
    if ok and type(value) == "table" then
      collection = value
    end
  end
  return collection
end

-- ---------------------------------------------------------------------------
-- A shared page skeleton
-- ---------------------------------------------------------------------------
-- `load(ctx, done)` fills the collection.  `done(items, state_name, details)`
-- reports the outcome.  Every page below differs only in its loader and its
-- activation behaviour, so the skeleton is written once.
local function make_page(ctx, opts)
  local collections = collection_module(ctx)
  local tr = ctx.tr or function(key) return tostring(key) end
  local palette = ctx.palette or {}
  local draw = ctx.draw or function() end

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local heading = page_frame:addLabel({
    x = 1, y = 1, width = "{parent.width-2}", height = 3,
    foreground = palette.fg, background = palette.bg,
  })
  draw(heading, tr(opts.title), "fg", "bg")

  local hint = page_frame:addLabel({
    x = 1, y = 4, width = "{parent.width-2}", height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  draw(hint, tr(opts.hint), "muted", "bg")

  local list_holder = page_frame:addFrame({
    x = 1, y = 5, width = "{parent.width}", height = "{parent.height-5}",
    background = palette.bg,
  })

  local list_ctx = {}
  for key, value in pairs(ctx) do
    list_ctx[key] = value
  end
  list_ctx.parent = list_holder

  local on_activate = opts.on_activate
  local list_page = collections.build(list_ctx, {
    title = "",
    empty_hint = opts.empty_hint,
    on_activate = function(item, index)
      if type(on_activate) == "function" then
        on_activate(item, index)
      end
    end,
  })

  -- `once` is the shell's page cache talking: a page is built once and shown
  -- many times, so the loader must not re-scan the disk on every show.  A
  -- `force` argument lets the user ask for a refresh after downloading.
  local loaded = false
  local page = {
    frame = page_frame,
    reload = function()
      list_page.set_items({}, "loading")
      opts.load(ctx, function(items, state_name, details)
        list_page.set_items(items, state_name, details)
      end)
    end,
  }

  page.refresh = function(force)
    if loaded and force ~= true then
      return
    end
    loaded = true
    page.reload()
  end

  page.reload()
  loaded = true
  return page
end

-- ---------------------------------------------------------------------------
-- 本地 -- every .nbs on this computer
-- ---------------------------------------------------------------------------

function library.build_local(ctx)
  local songs = ctx.songs
  return make_page(ctx, {
    title = "library.local_title",
    hint = "library.local_hint",
    empty_hint = "library.local_empty",
    on_activate = function(item)
      if type(ctx.on_play) == "function" then
        ctx.on_play(item)
      end
    end,
    load = function(inner, done)
      if type(songs) ~= "table" or type(songs.local_songs) ~= "function" then
        done({}, "error", { error = inner.tr("library.no_scanner") })
        return
      end
      local ok, items = pcall(songs.local_songs)
      if not ok or type(items) ~= "table" then
        done({}, "error", { error = inner.tr("library.scan_failed") })
        return
      end
      done(items, #items > 0 and "ready" or "empty")
    end,
  })
end

-- ---------------------------------------------------------------------------
-- 下载 -- songs already saved to disk
-- ---------------------------------------------------------------------------
-- This lists the same files as 本地 but through the DOWNLOADS lens: it is what a
-- user checks after pressing download, so it shares the scanner and differs only
-- in its wording and its empty state.
function library.build_downloads(ctx)
  local songs = ctx.songs
  return make_page(ctx, {
    title = "library.downloads_title",
    hint = "library.downloads_hint",
    empty_hint = "library.downloads_empty",
    on_activate = function(item)
      if type(ctx.on_play) == "function" then
        ctx.on_play(item)
      end
    end,
    load = function(inner, done)
      if type(songs) ~= "table" or type(songs.local_songs) ~= "function" then
        done({}, "error", { error = inner.tr("library.no_scanner") })
        return
      end
      local ok, items = pcall(songs.local_songs)
      if not ok or type(items) ~= "table" then
        done({}, "error", { error = inner.tr("library.scan_failed") })
        return
      end
      done(items, #items > 0 and "ready" or "empty")
    end,
  })
end

-- ---------------------------------------------------------------------------
-- 收藏 -- favourites
-- ---------------------------------------------------------------------------

function library.build_likes(ctx)
  local history = ctx.history
  return make_page(ctx, {
    title = "library.likes_title",
    hint = "library.likes_hint",
    empty_hint = "library.likes_empty",
    on_activate = function(item)
      if type(ctx.on_play) == "function" then
        ctx.on_play(item)
      end
    end,
    load = function(inner, done)
      if type(history) ~= "table"
        or type(history.favourites) ~= "function" then
        done({}, "error", { error = inner.tr("library.no_store") })
        return
      end
      local ok, items = pcall(history.favourites)
      if not ok or type(items) ~= "table" then
        done({}, "error", { error = inner.tr("library.store_failed") })
        return
      end
      done(items, #items > 0 and "ready" or "empty")
    end,
  })
end

-- ---------------------------------------------------------------------------
-- 最近播放 -- recently played
-- ---------------------------------------------------------------------------

function library.build_recent(ctx)
  local history = ctx.history
  return make_page(ctx, {
    title = "library.recent_title",
    hint = "library.recent_hint",
    empty_hint = "library.recent_empty",
    on_activate = function(item)
      if type(ctx.on_play) == "function" then
        ctx.on_play(item)
      end
    end,
    load = function(inner, done)
      if type(history) ~= "table" or type(history.list) ~= "function" then
        done({}, "error", { error = inner.tr("library.no_store") })
        return
      end
      local ok, items = pcall(history.list)
      if not ok or type(items) ~= "table" then
        done({}, "error", { error = inner.tr("library.store_failed") })
        return
      end
      done(items, #items > 0 and "ready" or "empty")
    end,
  })
end

return library
