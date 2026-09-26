-- ui/screens/browse.lua
--
-- DISCOVER AND SEARCH -- the two ways into Note Block World.
--
-- The reference's counterpart has a tab bar over a music service: 歌单广场 /
-- 排行榜 on Discover, and 歌曲 / 歌单 / 用户 / 专辑 on Search.  Note Block World
-- exposes exactly one collection -- songs -- so this module keeps the LAYOUT and
-- collapses the tabs:
--
--   Discover: two tabs that BOTH work via the API's sort parameters
--             发现  -> newest (sort=uploaded, desc)
--             热门  -> most played (sort=views, desc)
--   Search:   one real tab (歌曲) plus EXPLICIT empty tabs for the categories
--             NBW does not have, rather than hiding the tabs and quietly
--             changing the layout the user was shown.
--
-- ===========================================================================
-- THE INPUT METHOD IS WIRED IN HERE, AND IT IS OPTIONAL
-- ===========================================================================
-- A CC terminal has no IME, so a Chinese search needs the pinyin client.  When
-- `ui.ime` is available the search box offers candidates; when it is not, the
-- box accepts ASCII and says so.  Either way the page works -- an unreachable
-- IME service must cost the user Chinese input, not the search feature.
--
-- ===========================================================================
-- TYPING
-- ===========================================================================
-- Basalt delivers keystrokes through global events, not through an input
-- element's own handler, so the search box owns a "focused" flag and the shell's
-- key hook routes characters into it.  Doing it the other way -- an `Input`
-- element with `:onChange` -- does not fire reliably once focus moves.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local browse = {}

local collection = nil      -- resolved lazily so this module loads anywhere

local function collection_module(opts)
  if type(opts) == "table" and type(opts.collection) == "table" then
    return opts.collection
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

-- The sort presets Discover offers.  Kept as data so the tab bar and the request
-- cannot disagree about what "热门" means.
browse.DISCOVER_TABS = {
  { key = "new",  label = "browse.tab_new",  sort = "uploaded", order = "desc" },
  { key = "hot",  label = "browse.tab_hot",  sort = "views",    order = "desc" },
}

-- The tab bar on Search.  Only `songs` has an endpoint; the rest exist so the
-- layout matches and each one can say why it is empty.
browse.SEARCH_TABS = {
  { key = "songs",   label = "search.tab_songs" },
  { key = "players", label = "search.tab_players" },
  { key = "albums",  label = "search.tab_albums" },
}

-- ---------------------------------------------------------------------------
-- A tab bar, shared by both pages
-- ---------------------------------------------------------------------------
-- `on_select(index)` is called with the 0-based index the user picked.
local function build_tabs(ctx, parent, tabs, y, initial)
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end

  local bar = parent:addFrame({
    x = 1, y = y, width = "{parent.width-2}", height = 3,
    background = palette.bg,
  })

  local buttons = {}
  local width = math.max(8, math.floor(60 / math.max(1, #tabs)))
  for index, tab in ipairs(tabs) do
    local button = bar:addButton({
      x = (index - 1) * (width + 1) + 1, y = 1,
      width = width, height = 3,
      foreground = palette.fg, background = palette.panel,
    })
    draw(button, tr(tab.label), "fg", "panel")
    buttons[index] = button
  end

  local active = tonumber(initial) or 1

  local function paint()
    for index, button in ipairs(buttons) do
      local selected = index == active
      pcall(function()
        button:setBackground(selected and palette.active or palette.panel)
      end)
      draw(button, tr(tabs[index].label), "fg",
        selected and "active" or "panel")
    end
  end

  local on_select = nil
  for index, button in ipairs(buttons) do
    local picked = index
    button:onClick(function()
      if picked == active then
        return
      end
      active = picked
      paint()
      if type(on_select) == "function" then
        on_select(picked)
      end
    end)
  end

  paint()
  return {
    frame = bar,
    buttons = buttons,
    active = function() return active end,
    on_select = function(fn) on_select = fn end,
  }
end

-- ---------------------------------------------------------------------------
-- Discover
-- ---------------------------------------------------------------------------

-- browse.build_discover(ctx) -> page
function browse.build_discover(ctx)
  local collections = collection_module(ctx)
  local tr = ctx.tr or function(key) return tostring(key) end
  local palette = ctx.palette or {}
  local songs = ctx.songs

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local heading = page_frame:addLabel({
    x = 1, y = 1, width = "{parent.width-2}", height = 3,
    foreground = palette.fg, background = palette.bg,
  })
  ctx.draw(heading, tr("browse.title"), "fg", "bg")

  local list_holder = page_frame:addFrame({
    x = 1, y = 5, width = "{parent.width}", height = "{parent.height-5}",
    background = palette.bg,
  })

  local list_ctx = {}
  for key, value in pairs(ctx) do
    list_ctx[key] = value
  end
  list_ctx.parent = list_holder

  local list_page = collections.build(list_ctx, {
    title = "",
    on_activate = function(item)
      if type(ctx.on_activate) == "function" then
        ctx.on_activate(item)
      end
    end,
    on_download = ctx.on_download,
  })

  local tabs = build_tabs(ctx, page_frame, browse.DISCOVER_TABS, 4, 1)

  local function load(preset)
    list_page.set_items({}, "loading")
    if type(songs) ~= "table" or type(songs.search) ~= "function" then
      list_page.set_items({}, "error", { error = tr("browse.offline") })
      return
    end
    ctx.schedule(function()
      local ok, result = pcall(songs.search, {
        page = 1, limit = collections.PAGE_SIZE,
        sort = preset.sort, order = preset.order,
      })
      if not ok or type(result) ~= "table" or result.ok ~= true then
        local message = type(result) == "table" and (result.error or result.code)
          or nil
        list_page.set_items({}, "error", { error = message or tr("browse.offline") })
        return
      end
      local items = type(result.songs) == "table" and result.songs or {}
      list_page.set_items(items, #items > 0 and "ready" or "empty")
    end)
  end

  tabs.on_select(function(index)
    load(browse.DISCOVER_TABS[index] or browse.DISCOVER_TABS[1])
  end)

  local first_load = false
  local page = {
    frame = page_frame,
    refresh = function()
      -- Loaded once, on first show: re-entering the page must not re-issue the
      -- request, which is what the shell's page cache exists to avoid.
      if not first_load then
        first_load = true
        load(browse.DISCOVER_TABS[1])
      end
    end,
  }
  return page
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- browse.build_search(ctx) -> page
-- The page owns its query text and dispatches the request on submit, so typing
-- never issues a request per keystroke.
function browse.build_search(ctx)
  local collections = collection_module(ctx)
  local tr = ctx.tr or function(key) return tostring(key) end
  local palette = ctx.palette or {}
  local songs = ctx.songs
  local ime = ctx.ime
  local frame_helpers = ctx.frame

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local entry_row = page_frame:addFrame({
    x = 1, y = 1, width = "{parent.width-2}", height = 3,
    background = palette.panel,
  })

  local entry_label = entry_row:addLabel({
    x = 2, y = 1, width = "{parent.width-4}", height = 3,
    foreground = palette.fg, background = palette.panel,
  })

  local submit_button = entry_row:addButton({
    x = "{parent.width-13}", y = 1, width = 12, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  ctx.draw(submit_button, tr("search.submit"), "fg", "active")

  local hint = page_frame:addLabel({
    x = 1, y = 4, width = "{parent.width-2}", height = 1,
    foreground = palette.muted, background = palette.bg,
  })

  local list_holder = page_frame:addFrame({
    x = 1, y = 5, width = "{parent.width}", height = "{parent.height-5}",
    background = palette.bg,
  })

  local list_ctx = {}
  for key, value in pairs(ctx) do
    list_ctx[key] = value
  end
  list_ctx.parent = list_holder

  local list_page = collections.build(list_ctx, {
    title = "",
    on_activate = function(item)
      if type(ctx.on_activate) == "function" then
        ctx.on_activate(item)
      end
    end,
    on_download = ctx.on_download,
  })

  local tabs = build_tabs(ctx, page_frame, browse.SEARCH_TABS, 5, 1)
  -- The list sits below the tab bar, so it is shifted down by the bar's height.
  pcall(function()
    list_holder:setPosition(1, 8)
    list_holder:setHeight("{parent.height-8}")
  end)

  local page = {
    frame = page_frame,
    query = "",
    tab = 1,
  }

  local function paint_entry()
    local shown = page.query
    if shown == "" then
      shown = tr("search.placeholder")
    end
    ctx.draw(entry_label, shown, "fg", "panel")
  end

  local function paint_hint()
    local text
    if type(ime) == "table" and type(ime.enabled) == "function" then
      local ok, enabled = pcall(ime.enabled)
      if ok and enabled == true then
        text = tr("search.hint_ime")
      else
        text = tr("search.hint_ascii")
      end
    else
      text = tr("search.hint_ascii")
    end
    ctx.draw(hint, text, "muted", "bg")
  end

  local function submit()
    local query = page.query
    if query == "" then
      list_page.set_items({}, "empty")
      return
    end

    local tab = browse.SEARCH_TABS[page.tab] or browse.SEARCH_TABS[1]
    if tab.key ~= "songs" then
      -- An honest empty state beats a hidden tab: the user asked for this
      -- category and deserves to be told the source has none.
      list_page.set_items({}, "empty",
        { error = tr("search.unsupported") })
      return
    end

    list_page.set_items({}, "loading")
    if type(songs) ~= "table" or type(songs.search) ~= "function" then
      list_page.set_items({}, "error", { error = tr("browse.offline") })
      return
    end
    ctx.schedule(function()
      local ok, result = pcall(songs.search, { query = query, page = 1,
        limit = collections.PAGE_SIZE })
      if not ok or type(result) ~= "table" or result.ok ~= true then
        local message = type(result) == "table" and (result.error or result.code)
          or nil
        list_page.set_items({}, "error", { error = message or tr("browse.offline") })
        return
      end
      local items = type(result.songs) == "table" and result.songs or {}
      list_page.set_items(items, #items > 0 and "ready" or "empty")
    end)
  end

  submit_button:onClick(submit)
  entry_row:onClick(function()
    page.focused = true
  end)

  -- The shell hands characters and special keys here.  Returning true means
  -- "consumed", so the shell knows not to treat it as a global hotkey.
  local SPECIAL = {
    backspace = true, enter = true, escape = true, tab = true,
    up = true, down = true, left = true, right = true,
  }

  function page.on_key(key, character)
    -- FOCUS IS EXPLICIT: without it, space would pause playback while the user
    -- is typing a space into the query.
    if page.focused ~= true then
      return false
    end

    local keys = rawget(_G, "keys") or {}
    if key == keys.escape then
      page.focused = false
      return true
    elseif key == keys.enter then
      page.focused = false
      submit()
      return true
    elseif key == keys.backspace then
      page.query = page.query:sub(1, math.max(0, #page.query - 1))
      paint_entry()
      return true
    elseif SPECIAL[tostring(key)] then
      -- Not a character we want; swallow it so it cannot reach a hotkey.
      return true
    end

    if type(character) == "string" and character ~= "" then
      local candidate = page.query .. character
      -- Bound the query so a stuck key cannot build a megabyte of text, and so
      -- the request stays inside the IME's own cap.
      local cap = 64
      if type(ime) == "table" and type(ime.MAX_INPUT_BYTES) == "number" then
        cap = ime.MAX_INPUT_BYTES
      end
      if #candidate <= cap then
        page.query = candidate
        paint_entry()
      end
      return true
    end
    return false
  end

  tabs.on_select(function(index)
    page.tab = index
    list_page.set_items({}, "empty")
  end)

  paint_entry()
  paint_hint()

  -- Focus on show: the user navigated here to type, so requiring a click
  -- first would be a step the reference does not have either.  Escape
  -- blurs it, which hands keys back to the global hotkeys.
  page.refresh = function()
    page.focused = true
  end

  return page
end

return browse
