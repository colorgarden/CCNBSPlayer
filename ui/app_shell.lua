-- ui/app_shell.lua
--
-- THE APPLICATION SHELL -- the monitor-based replica of the reference
-- implementation's interface.
--
-- This is the structural counterpart of MPlayer's `src/startup.lua`: the same
-- screens in the same places, wired to Note Block World instead of a music
-- service that needs an account.
--
-- ===========================================================================
-- WHAT IS REPLICATED, AND WHAT IS NOT
-- ===========================================================================
-- REPLICATED (measured from the reference, see docs/replica.md):
--   * the monitor bootstrap: `setTextScale(0.5)`, seven palette overrides, a
--     frame bound to the monitor's terminal;
--   * the display-selection page shown when no monitor is configured;
--   * the 17-wide left sidebar with its seven buttons and two dividers;
--   * the top bar (back / forward / search icon / search box / user / settings);
--   * the 6-tall bottom playback bar with a seekable progress strip;
--   * the router with back/forward history;
--   * the overlay set: max-play, volume-replacement, play queue, settings,
--     search, popups and confirm dialogs.
--
-- NOT REPLICATED, because the underlying data does not exist here: accounts,
-- QR login, VIP tiers, lyrics, NetEase daily/like/FM lists, playlists, albums
-- and artists.  Those screens are REPURPOSED rather than dropped -- see the
-- screen modules -- so the navigation geometry stays identical.
--
-- ===========================================================================
-- THE FOUR BASALT CONSTRAINTS THIS MODULE MUST HONOUR
-- ===========================================================================
-- 1. `basalt.run()` BLOCKS in its own event loop.  Nothing can run beside it, so
--    every timer and the playback driver live in `basalt.schedule` coroutines.
-- 2. Global hotkeys go through `basalt.onEvent("key", fn)`.  An element's
--    `:onKey` only fires for the focused child, which is fragile.
-- 3. Chinese reaches the screen ONLY through a text element's `setImage(bimg)`,
--    because Basalt's own text path uses CC's font, which has no CJK glyphs.
--    `frame.set_image_or_text` is the single decision point.
-- 4. `require("vendor.basalt")` must happen INSIDE `run`, because the vendored
--    bundle touches `fs` while loading and would break `require` in plain Lua.
--    This module must stay require-able on a desktop interpreter.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local app_shell = {}

app_shell.VERSION = "1.1.0"

-- ---------------------------------------------------------------------------
-- Lazy global access -- never read a CC global at module load
-- ---------------------------------------------------------------------------

local function raw_global(name)
  local ok, value = pcall(rawget, _G, name)
  if ok then
    return value
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Optional dependencies -- a missing one must degrade, not abort
-- ---------------------------------------------------------------------------
-- `optional_require` returns nil rather than raising, so a partial install
-- (say, no IME) still starts and simply loses that one feature.  The shell is
-- the one place that can make that call, because it knows what is essential.
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

-- ---------------------------------------------------------------------------
-- Screen geometry -- measured from the reference implementation
-- ---------------------------------------------------------------------------
-- Kept as named constants with the source line they came from, so a reader can
-- check them against the reference instead of trusting this file.
local SIDEBAR_WIDTH = 17      -- reference: Navigation frame width
local TOPBAR_HEIGHT = 4       -- reference: TopBackBar_Frame height
local PLAYBAR_HEIGHT = 6      -- reference: PlaybackBar_Frame height

-- The sidebar buttons, in the reference's own order and y positions.
-- `id` is our route name; `icon` is the vendored icon file to draw.
local NAV_ITEMS = {
  { id = "home",     label = "nav.home",     icon = "Home",       y = 5 },
  { id = "browse",   label = "nav.browse",   icon = "Discover",   y = 8 },
  { id = "roaming",  label = "nav.roaming",  icon = "Roaming",    y = 11 },
  { id = "help",     label = "nav.help",     icon = "Podcast",    y = 14 },
  { id = "likes",    label = "nav.likes",    icon = "Like",       y = 18 },
  { id = "downloads", label = "nav.downloads", icon = "Favorite", y = 21 },
  { id = "recent",   label = "nav.recent",   icon = "Recently",   y = 24 },
}

-- ---------------------------------------------------------------------------
-- Text helper bound to the loaded renderer
-- ---------------------------------------------------------------------------

-- make_drawer(frame_helpers, utf8display) -> function(element, key_or_text, ...)
-- Every draw goes through here, so the ASCII fallback is decided in one place.
local function make_drawer(frame_helpers, utf8display, colors_table, palette)
  return function(element, text, fg_key, bg_key, tr)
    local fg = palette[fg_key or "fg"]
    local bg = palette[bg_key or "bg"]
    frame_helpers.set_image_or_text(element, text,
      frame_helpers.blit_of(colors_table, fg),
      frame_helpers.blit_of(colors_table, bg),
      utf8display)
  end
end

-- ---------------------------------------------------------------------------
-- run(opts)
-- ---------------------------------------------------------------------------
-- `opts` is entirely injectable so the shell is drivable without a computer:
--   opts.basalt, opts.utf8display, opts.frame, opts.icons, opts.songs,
--   opts.transport, opts.ime, opts.settings, opts.history, opts.i18n,
--   opts.router_screens, opts.monitors, opts.schedule, opts.timers
-- Anything omitted is resolved through `require` at run time.
function app_shell.run(opts)
  opts = type(opts) == "table" and opts or {}

  -- -------------------------------------------------------------- basalt -----
  -- Constraint 4: the vendored bundle touches fs while loading, so it is
  -- required HERE and not at module scope.
  local basalt = opts.basalt or try(pcall(require, "vendor.basalt"))
  if type(basalt) ~= "table" then
    local log = type(opts.log) == "function" and opts.log or function() end
    log("app_shell: the Basalt bundle is not available")
    return { exit_code = 1 }
  end

  -- --------------------------------------------------------------- deps ------
  local frame_helpers = opts.frame or try(pcall(require, "ui.screens.frame"))
  local icons = opts.icons or try(pcall(require, "ui.icons"))
  local songs = opts.songs or try(pcall(require, "ui.songs"))
  local transport = opts.transport or try(pcall(require, "ui.transport"))
  local ime = opts.ime or try(pcall(require, "ui.ime"))
  local store = opts.settings or try(pcall(require, "ui.settings"))
  local history = opts.history or try(pcall(require, "ui.history"))
  local i18n = opts.i18n or try(pcall(require, "ui.i18n"))
  local utf8display = opts.utf8display or try(pcall(require, "vendor.utf8display"))
  local cjk = opts.cjk or try(pcall(require, "ui.cjk"))

  local colors_table = opts.colors or raw_global("colors") or {}
  local log = type(opts.log) == "function" and opts.log or function() end
  local schedule = opts.schedule or basalt.schedule

  if type(frame_helpers) ~= "table" then
    log("app_shell: ui.screens.frame is required")
    return { exit_code = 1 }
  end

  -- Language: the settings store wins when it exists, else i18n's default.
  local language = "en"
  if type(store) == "table" then
    local block = store.load_language()
    if type(block) == "table" and type(block.code) == "string" then
      language = block.code
    end
  end
  if type(i18n) == "table" and type(i18n.set_language) == "function" then
    pcall(i18n.set_language, language)
  end

  -- A single translate function, so no screen needs to know how language is
  -- resolved; a missing i18n degrades to the key itself, which is greppable.
  local function tr(key, args)
    if type(i18n) == "table" and type(i18n.t) == "function" then
      local ok, text = pcall(i18n.t, key, args)
      if ok and type(text) == "string" then
        return text
      end
    end
    return tostring(key)
  end

  -- --------------------------------------------------------- appearance -----
  local appearance = nil
  if type(store) == "table" then
    appearance = store.load_appearance()
  end

  local palette = {
    bg = colors_table.black,
    panel = colors_table.gray,
    inset = colors_table.lightGray,
    fg = colors_table.white,
    muted = colors_table.lightGray,
    accent = colors_table.purple,
    active = colors_table.pink,
  }

  -- --------------------------------------------------- CJK renderer setup ----
  -- A failure here costs the user Chinese, never the program: every draw falls
  -- back to ASCII.  The font is fetched at run time because it cannot be
  -- vendored (1.68 MB against a default 1 MB disk limit).
  --
  -- TWO SOURCES CAN PRODUCE bimg AND THEY ARE NOT THE SAME SHAPE OF THING:
  --   * the raw renderer (`vendor.utf8display`) exposes `strToBimg`;
  --   * our adapter (`ui.cjk`) exposes `to_bimg`, which does its own font setup
  --     and returns nil instead of raising when it cannot.
  -- `ui.cjk` deliberately does NOT hand out its inner renderer, so the two are
  -- unified here into ONE `strToBimg`-shaped value.  Everything downstream then
  -- has a single interface to call, and the ASCII fallback happens in
  -- `frame.set_image_or_text` when the value is nil.
  local bimg_source = nil
  if type(utf8display) == "table"
    and type(utf8display.strToBimg) == "function" then
    bimg_source = utf8display
  elseif type(cjk) == "table" and type(cjk.to_bimg) == "function" then
    -- Ask the adapter to prepare its font once.  `available()` is the honest
    -- signal; a false result simply leaves bimg_source nil.
    if type(cjk.setup) == "function" then
      pcall(cjk.setup, {})
    end
    if type(cjk.available) == "function" then
      local ok, ready = pcall(cjk.available)
      if ok and ready == true then
        bimg_source = {
          strToBimg = function(text, fg, bg)
            return cjk.to_bimg(text, fg, bg)
          end,
        }
      end
    end
  end
  utf8display = bimg_source

  local draw = make_drawer(frame_helpers, utf8display, colors_table, palette)

  -- ----------------------------------------------------------- monitors -----
  local monitors = opts.monitors or frame_helpers.available_monitors()
  local chosen = nil
  if type(store) == "table" then
    local display = store.load_display()
    local wanted = type(display) == "table" and display.name or nil
    if wanted ~= nil then
      for _, monitor in ipairs(monitors) do
        if monitor.name == wanted then
          chosen = monitor
          break
        end
      end
    end
  end

  local computer_frame = basalt.getMainFrame()
  if computer_frame ~= nil and type(computer_frame.setBackground) == "function" then
    pcall(computer_frame.setBackground, palette.bg)
  end

  -- No usable monitor -> the selection page, and nothing else starts.  The
  -- interface cannot lay itself out without a target, so this comes first.
  if chosen == nil then
    frame_helpers.create_display_selection_page(computer_frame, monitors, {
      title = tr("display.title"),
      empty = tr("display.none"),
      fg = palette.fg, bg = palette.bg, accent = palette.accent,
      fg_blit = frame_helpers.blit_of(colors_table, palette.fg),
      bg_blit = frame_helpers.blit_of(colors_table, palette.bg),
      accent_blit = frame_helpers.blit_of(colors_table, palette.accent),
      utf8display = utf8display,
      on_pick = function(picked)
        if type(store) == "table" then
          pcall(store.save_display, { name = picked.name })
        end
        -- A reboot is the reference's own behaviour: the terminal binding is
        -- fixed at frame creation, so switching needs a fresh start.
        local oslib = raw_global("os")
        if type(oslib) == "table" and type(oslib.reboot) == "function" then
          pcall(oslib.reboot)
        end
      end,
    })
    basalt.run()
    return { exit_code = 0 }
  end

  local monitor = chosen.peripheral

  -- The reference's own numbers: half-scale text, which is what makes a
  -- multi-section layout fit a monitor at all.
  if type(monitor.setTextScale) == "function" then
    pcall(monitor.setTextScale, 0.5)
  end
  if type(monitor.setPaletteColor) == "function" then
    frame_helpers.apply_palette(monitor, colors_table, appearance)
  end

  local monitor_frame = basalt.createFrame()
  if monitor_frame ~= nil then
    monitor_frame.term = monitor
    if type(monitor_frame.setBackground) == "function" then
      pcall(monitor_frame.setBackground, palette.bg)
    end
  end
  local root = monitor_frame or computer_frame

  -- The main frame everything else hangs from.
  local main = root:addFrame({
    x = 1, y = 1, width = "{parent.width}", height = "{parent.height}",
    background = palette.bg,
  })

  -- =========================================================================
  -- Router
  -- =========================================================================
  -- A page is built once and cached, then shown or hidden.  Rebuilding on every
  -- navigation would re-issue every network request, so caching is a
  -- requirement rather than an optimisation.
  local pages = {}
  local order = {}
  local route_state = { current = nil, history = {}, index = 0 }
  local screens = opts.screens or {}

  -- Forward declarations.  Lua resolves locals lexically at COMPILE time, so a
  -- function that mentions another one defined further down would silently
  -- compile as a GLOBAL lookup and fail at run time with "attempt to call a nil
  -- value".  Declaring them here keeps every reference a real local.
  local navigate
  local show
  local page_for

  page_for = function(id)
    if pages[id] ~= nil then
      return pages[id]
    end
    local builder = screens[id]
    if type(builder) ~= "function" then
      return nil
    end
    local page = builder({
      basalt = basalt,
      root = root,
      parent = main,
      frame = frame_helpers,
      icons = icons,
      songs = songs,
      transport = transport,
      ime = ime,
      settings = store,
      history = history,
      i18n = i18n,
      utf8display = utf8display,
      colors = colors_table,
      palette = palette,
      draw = draw,
      tr = tr,
      schedule = schedule,
      navigate = function(target)
        navigate(target)
      end,
    })
    if type(page) ~= "table" or page.frame == nil then
      return nil
    end
    page.id = id
    pages[id] = page
    order[#order + 1] = id
    page.frame:setVisible(false)
    return page
  end

  show = function(id)
    local page = page_for(id)
    if page == nil then
      return false
    end
    for _, other in ipairs(order) do
      if other ~= id then
        pcall(function()
          pages[other].frame:setVisible(false)
        end)
      end
    end
    pcall(function()
      page.frame:setVisible(true)
    end)
    route_state.current = id
    if type(page.refresh) == "function" then
      pcall(page.refresh)
    end
    return true
  end

  navigate = function(id, record)
    if id == route_state.current then
      return
    end
    if record ~= false then
      -- Truncate any forward entries, exactly like a browser: navigating from
      -- the middle of the history abandons what was ahead of it.
      while #route_state.history > route_state.index do
        table.remove(route_state.history)
      end
      route_state.history[#route_state.history + 1] = id
      route_state.index = #route_state.history
    end
    show(id)
  end

  local function move_history(delta)
    local target = route_state.index + delta
    if target < 1 or target > #route_state.history then
      return
    end
    route_state.index = target
    show(route_state.history[target])
  end

  -- =========================================================================
  -- Sidebar -- the reference's 17-wide column
  -- =========================================================================
  local nav_buttons = {}

  local sidebar = main:addFrame({
    x = 1, y = 1, width = SIDEBAR_WIDTH, height = "{parent.height}",
    background = palette.panel,
  })

  local brand = sidebar:addLabel({
    x = 1, y = 1, width = SIDEBAR_WIDTH - 1, height = 3,
    foreground = palette.accent, background = palette.panel,
  })
  draw(brand, tr("app.name"), "accent", "panel")

  for _, item in ipairs(NAV_ITEMS) do
    local button = sidebar:addButton({
      x = 1, y = item.y, width = SIDEBAR_WIDTH - 1, height = 3,
      foreground = palette.fg, background = palette.panel,
    })
    -- Icon AND label, glued the way the reference does it.
    local icon_image = type(icons) == "table" and icons.get(item.icon) or nil
    local label_image = frame_helpers.process_str_to_bimg(utf8display,
      tr(item.label), frame_helpers.blit_of(colors_table, palette.fg),
      frame_helpers.blit_of(colors_table, palette.panel))
    local combined = frame_helpers.concat_bimg(icon_image, label_image)
    if combined ~= nil and type(button.setImage) == "function" then
      pcall(button.setImage, button, combined)
    else
      draw(button, tr(item.label), "fg", "panel")
    end

    local target = item.id
    button:onClick(function()
      navigate(target)
    end)
    nav_buttons[item.id] = button
  end

  -- The two dividers, which keep the sidebar's rhythm identical to the
  -- reference even though the sections below them differ.
  for _, y in ipairs({ 17, 27 }) do
    local divider = sidebar:addLabel({
      x = 1, y = y, width = SIDEBAR_WIDTH - 1, height = 1,
      foreground = palette.muted, background = palette.panel,
    })
    pcall(function()
      divider.setText("")
    end)
  end

  -- =========================================================================
  -- Top bar
  -- =========================================================================
  local topbar = main:addFrame({
    x = SIDEBAR_WIDTH + 1, y = 1,
    width = "{parent.width-" .. (SIDEBAR_WIDTH + 1) .. "}",
    height = TOPBAR_HEIGHT, background = palette.bg,
  })

  local back_button = topbar:addButton({
    x = 4, y = 2, width = 4, height = 3,
    foreground = palette.fg, background = palette.bg,
  })
  draw(back_button, "<", "fg", "bg")
  back_button:onClick(function()
    move_history(-1)
  end)

  local forward_button = topbar:addButton({
    x = 9, y = 2, width = 4, height = 3,
    foreground = palette.fg, background = palette.bg,
  })
  draw(forward_button, ">", "fg", "bg")
  forward_button:onClick(function()
    move_history(1)
  end)

  local search_button = topbar:addButton({
    x = 15, y = 2, width = 4, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  local search_icon = type(icons) == "table" and icons.get("Search") or nil
  if search_icon ~= nil and type(search_button.setImage) == "function" then
    pcall(search_button.setImage, search_button, search_icon)
  else
    draw(search_button, "S", "fg", "active")
  end
  search_button:onClick(function()
    navigate("search")
  end)

  local search_box = topbar:addButton({
    x = 19, y = 2, width = 30, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  draw(search_box, tr("search.placeholder"), "fg", "active")
  search_box:onClick(function()
    navigate("search")
  end)

  -- No accounts exist here, so the reference's user button becomes About.
  local about_button = topbar:addButton({
    x = "{parent.width-44}", y = 2, width = 40, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  draw(about_button, tr("nav.about"), "fg", "active")
  about_button:onClick(function()
    navigate("about")
  end)

  local settings_button = topbar:addButton({
    x = "{parent.width-3}", y = 2, width = 4, height = 3,
    foreground = palette.fg, background = palette.bg,
  })
  local settings_icon = type(icons) == "table" and icons.get("Settings") or nil
  if settings_icon ~= nil and type(settings_button.setImage) == "function" then
    pcall(settings_button.setImage, settings_button, settings_icon)
  else
    draw(settings_button, "*", "fg", "bg")
  end
  settings_button:onClick(function()
    navigate("settings")
  end)

  -- =========================================================================
  -- Playback bar -- the reference's 6-tall bottom strip
  -- =========================================================================
  local playbar = main:addFrame({
    x = 1, y = "{parent.height-" .. (PLAYBAR_HEIGHT - 1) .. "}",
    width = "{parent.width}", height = PLAYBAR_HEIGHT,
    background = palette.panel,
  })

  -- Two half-width labels form the progress strip: the filled part is drawn in
  -- the accent colour and the remainder in the muted colour.  This is how the
  -- reference gets a bar out of labels rather than a ProgressBar element.
  local progress_track = playbar:addLabel({
    x = 1, y = 1, width = "{parent.width}", height = 1,
    foreground = palette.muted, background = palette.panel,
  })
  local progress_ahead = playbar:addLabel({
    x = 1, y = 1, width = "{parent.width}", height = 1,
    foreground = palette.accent, background = palette.panel,
  })

  local now_label = playbar:addLabel({
    x = 6, y = 3, width = "{parent.width-46}", height = 3,
    foreground = palette.fg, background = palette.panel,
  })

  local position_button = playbar:addButton({
    x = 1, y = 1, width = "{parent.width}", height = 1,
    text = "", backgroundEnabled = false, z = 22,
  })
  position_button:onClick(function(self, button, x)
    if type(transport) ~= "table" or type(transport.seek) ~= "function" then
      return
    end
    local width = 1
    if type(self.getWidth) == "function" then
      local ok, value = pcall(self.getWidth, self)
      if ok and type(value) == "number" and value > 1 then
        width = value
      end
    end
    -- Same fraction the reference computes: the click column over the width.
    pcall(transport.seek, ((tonumber(x) or 1) - 1) / (width - 1))
  end)

  local function transport_button(x, key, action)
    local button = playbar:addButton({
      x = x, y = 3, width = 4, height = 3,
      foreground = palette.accent, background = palette.panel,
    })
    draw(button, tr(key), "accent", "panel")
    button:onClick(action)
    return button
  end

  local previous_button = transport_button("{floor(parent.width/2-9)}",
    "player.previous", function()
      if type(opts.on_previous) == "function" then
        opts.on_previous()
      end
    end)
  local play_button = transport_button("{floor(parent.width/2-4)}",
    "player.play", function()
      if type(transport) == "table" and type(transport.toggle) == "function" then
        pcall(transport.toggle)
      end
    end)
  local next_button = transport_button("{floor(parent.width/2+1)}",
    "player.next", function()
      if type(opts.on_next) == "function" then
        opts.on_next()
      end
    end)

  -- =========================================================================
  -- Playback driver -- ONE scheduled coroutine, per Basalt constraint 1
  -- =========================================================================
  -- `basalt.run()` blocks, so this is the only place a sleep is legal.  It
  -- redraws the bar from the transport's own progress rather than counting
  -- events, so an unevenly spaced song does not make the bar jump.
  local REDRAW_INTERVAL = 0.25
  local sleeper = opts.sleep
  if type(sleeper) ~= "function" then
    local oslib = raw_global("os")
    if type(oslib) == "table" and type(oslib.sleep) == "function" then
      sleeper = oslib.sleep
    end
  end

  -- Forward declared for the same lexical reason as `navigate` above.
  local play_button_label

  play_button_label = function(state)
    local key = state == "playing" and "player.pause" or "player.play"
    draw(play_button, tr(key), "accent", "panel")
  end

  local function refresh_playbar()
    local info = nil
    if type(transport) == "table" and type(transport.progress) == "function" then
      local ok, value = pcall(transport.progress)
      if ok and type(value) == "table" then
        info = value
      end
    end

    local frac = 0
    if info ~= nil and type(info.frac) == "number" then
      frac = info.frac
    end
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end

    local width = 0
    if type(progress_track.getWidth) == "function" then
      local ok, value = pcall(progress_track.getWidth, progress_track)
      if ok and type(value) == "number" then
        width = value
      end
    end

    local filled = math.floor(width * frac + 0.5)
    local track = string.rep("\131", width)

    pcall(function()
      progress_track.setText(track)
    end)
    pcall(function()
      progress_ahead:setText(string.rep("\131", filled)
        .. string.rep(" ", math.max(0, width - filled)))
    end)

    local state = "stopped"
    if type(transport) == "table" and type(transport.state) == "function" then
      local ok, value = pcall(transport.state)
      if ok and type(value) == "string" then
        state = value
      end
    end
    play_button_label(state)
  end

  -- =========================================================================
  -- Hotkeys -- Basalt constraint 2: a GLOBAL hook, not element :onKey
  -- =========================================================================
  basalt.onEvent("key", function(key)
    local keys = raw_global("keys")
    if type(keys) ~= "table" then
      return
    end
    if key == keys.space or key == keys.p then
      if type(transport) == "table" and type(transport.toggle) == "function" then
        pcall(transport.toggle)
      end
      refresh_playbar()
    elseif key == keys.s or key == keys.q then
      if type(transport) == "table" and type(transport.stop) == "function" then
        pcall(transport.stop)
      end
      refresh_playbar()
    elseif key == keys.left then
      if type(transport) == "table" and type(transport.seek) == "function" then
        local info = transport.progress()
        local frac = type(info) == "table" and info.frac or 0
        pcall(transport.seek, math.max(0, frac - 0.05))
      end
    elseif key == keys.right then
      if type(transport) == "table" and type(transport.seek) == "function" then
        local info = transport.progress()
        local frac = type(info) == "table" and info.frac or 0
        pcall(transport.seek, math.min(1, frac + 0.05))
      end
    end
  end)

  -- =========================================================================
  -- Start
  -- =========================================================================
  local first = opts.initial_page or "home"
  navigate(first, true)

  schedule(function()
    while true do
      refresh_playbar()
      if type(sleeper) == "function" then
        sleeper(REDRAW_INTERVAL)
      else
        break
      end
    end
  end)

  basalt.run()
  return { exit_code = 0 }
end

return app_shell
