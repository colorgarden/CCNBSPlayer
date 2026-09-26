-- ui/screens/settings.lua
--
-- THE SETTINGS WINDOW -- an overlay with a side navigation, as the reference has.
--
-- The reference's window has eight pages (常规 / 歌词 / 网络 / 音频 / 外观 / 显示 /
-- 关于 / 更新).  Ours has seven, because there are no lyrics here, and the pages
-- that remain hold OUR settings rather than NetEase's:
--
--   网络  holds the two ENDPOINTS, and this is the point of the window: the
--         reference reads its IME address from settings and only falls back to
--         the built-in one, and the user asked for the same behaviour by name
--         ("并非硬编码，在MPlayer设置里可以更改").  So the address is editable
--         here and takes effect without touching a file.
--   显示  chooses the monitor.
--   外观  edits the seven palette colours.
--   常规  the interface language and a way to clear local data.
--   音频  reports the speakers this computer can reach.
--   关于  the version and the licence situation.
--   更新  points at the updater.
--
-- ===========================================================================
-- SAVING IS EXPLICIT AND PER-FIELD VALIDATION IS VISIBLE
-- ===========================================================================
-- A rejected value must not be swallowed.  Typing a malformed URL and getting a
-- silent no-op is how a user ends up believing they configured something they
-- did not, so each page reports what it refused and why.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local settings_screen = {}

-- The page list, in the reference's order with 歌词 removed.
settings_screen.PAGES = {
  { key = "general",  label = "settings.general" },
  { key = "network",  label = "settings.network" },
  { key = "display",  label = "settings.display" },
  { key = "audio",    label = "settings.audio" },
  { key = "appearance", label = "settings.appearance" },
  { key = "about",    label = "settings.about" },
  { key = "update",   label = "settings.update" },
}

-- ---------------------------------------------------------------------------
-- Pure helpers -- validation the screen reports, shared with the store
-- ---------------------------------------------------------------------------

-- settings_screen.validate_url_input(text, store) -> url | nil, error_key.
-- Delegates to the store's validator so the screen and the file agree on what a
-- URL is; the screen only adds the message key.
function settings_screen.validate_url_input(text, store)
  if type(store) ~= "table" or type(store.valid_url) ~= "function" then
    if type(text) == "string" and text:match("^https?://") then
      return text, nil
    end
    return nil, "settings.bad_url"
  end
  local url = store.valid_url(text)
  if url == nil then
    return nil, "settings.bad_url"
  end
  return url, nil
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

-- settings_screen.build(ctx) -> page
--   page.show()   open the window
--   page.hide()   close it
function settings_screen.build(ctx)
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end
  local store = ctx.settings
  local ime = ctx.ime

  local width = "{parent.width-4}"
  local window = ctx.parent:addFrame({
    x = 2, y = 2, width = width, height = "{parent.height-4}",
    background = palette.panel, z = 30,
  })

  local title = window:addLabel({
    x = 2, y = 1, width = "{parent.width-4}", height = 3,
    foreground = palette.accent, background = palette.panel,
  })
  draw(title, tr("settings.title"), "accent", "panel")

  -- The side navigation, 18 wide, mirroring the reference's own sidebar width
  -- so the two windows have the same proportions.
  local nav = window:addFrame({
    x = 1, y = 4, width = 18, height = "{parent.height-5}",
    background = palette.panel,
  })

  local body = window:addFrame({
    x = 19, y = 4, width = "{parent.width-20}", height = "{parent.height-5}",
    background = palette.bg,
  })

  local status = window:addLabel({
    x = 2, y = "{parent.height-2}", width = "{parent.width-4}", height = 1,
    foreground = palette.muted, background = palette.panel,
  })

  local function set_status(message)
    draw(status, tostring(message or ""), "muted", "panel")
  end

  -- ------------------------------------------------------------- pages ------
  -- Each page is a frame inside `body`, shown or hidden by the navigation.
  local pages = {}
  local nav_buttons = {}
  local current = nil

  local function page_frame_for(key)
    if pages[key] ~= nil then
      return pages[key].frame
    end
    local holder = body:addFrame({
      x = 1, y = 1, width = "{parent.width}", height = "{parent.height}",
      background = palette.bg,
    })
    pages[key] = { frame = holder, widgets = {} }
    holder:setVisible(false)
    return holder
  end

  -- A labelled text row plus, optionally, an editable field.  Editable fields
  -- are BUTTONS, because Basalt's `Input` element does not take focus reliably
  -- once other elements are on screen -- the same reason the search box is a
  -- button with a hand-rolled key path.
  local function text_row(holder, y, caption_key, value, on_edit)
    local caption = holder:addLabel({
      x = 1, y = y, width = 20, height = 1,
      foreground = palette.muted, background = palette.bg,
    })
    draw(caption, tr(caption_key), "muted", "bg")

    local shown = tostring(value or "")
    if type(on_edit) == "function" then
      local button = holder:addButton({
        x = 21, y = y, width = "{parent.width-22}", height = 1,
        foreground = palette.fg, background = palette.inset,
      })
      draw(button, shown, "fg", "inset")
      button:onClick(function()
        on_edit(shown)
      end)
      return button
    end

    local label = holder:addLabel({
      x = 21, y = y, width = "{parent.width-22}", height = 1,
      foreground = palette.fg, background = palette.bg,
    })
    draw(label, shown, "fg", "bg")
    return label
  end

  -- ------------------------------------------------------------- 网络 -------
  local network = page_frame_for("network")
  local function paint_network()
    for _, widget in ipairs(pages.network.widgets) do
      pcall(function()
        widget:setVisible(false)
      end)
    end
    pages.network.widgets = {}

    local api = nil
    local ime_block = nil
    if type(store) == "table" then
      api = store.load_api()
      ime_block = store.load_ime()
    end

    local y = 1

    local heading = network:addLabel({
      x = 1, y = y, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(heading, tr("settings.nbw_section"), "accent", "bg")
    pages.network.widgets[#pages.network.widgets + 1] = heading
    y = y + 2

    pages.network.widgets[#pages.network.widgets + 1] =
      text_row(network, y, "settings.nbw_url",
        type(api) == "table" and api.url or "", nil)
    y = y + 1
    pages.network.widgets[#pages.network.widgets + 1] =
      text_row(network, y, "settings.nbw_timeout",
        type(api) == "table" and api.timeout or "", nil)
    y = y + 1
    pages.network.widgets[#pages.network.widgets + 1] =
      text_row(network, y, "settings.nbw_retries",
        type(api) == "table" and api.maxRetries or "", nil)
    y = y + 2

    -- THE IME ENDPOINT -- the reason this window exists.
    local ime_heading = network:addLabel({
      x = 1, y = y, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(ime_heading, tr("settings.ime_section"), "accent", "bg")
    pages.network.widgets[#pages.network.widgets + 1] = ime_heading
    y = y + 2

    local ime_state = "?"
    if type(ime) == "table" and type(ime.enabled) == "function" then
      local ok, value = pcall(ime.enabled)
      if ok then
        ime_state = value and tr("settings.on") or tr("settings.off")
      end
    end

    pages.network.widgets[#pages.network.widgets + 1] =
      text_row(network, y, "settings.ime_enabled", ime_state, function()
        if type(ime) ~= "table" then
          set_status(tr("settings.ime_unavailable"))
          return
        end
        local ok, value = pcall(ime.enabled)
        local next_enabled = not (ok and value == true)
        pcall(ime.configure, { enabled = next_enabled })
        if type(store) == "table" then
          local block = store.load_ime()
          if type(block) == "table" then
            block.enabled = next_enabled
            store.save_ime(block)
          end
        end
        set_status(tr("settings.saved"))
        paint_network()
      end)
    y = y + 1

    -- The address itself.  Editing uses the same key path as the search box, so
    -- the shell routes characters here while `editing` is set.
    pages.network.widgets[#pages.network.widgets + 1] =
      text_row(network, y, "settings.ime_url",
        type(ime_block) == "table" and ime_block.url or "",
        function(value)
          network.editing = { field = "ime_url", buffer = value }
          set_status(tr("settings.ime_edit_hint"))
        end)
    y = y + 1

    pages.network.widgets[#pages.network.widgets + 1] =
      text_row(network, y, "settings.ime_timeout",
        type(ime_block) == "table" and ime_block.timeout or "", nil)
    y = y + 2

    local note = network:addLabel({
      x = 1, y = y, width = "{parent.width-2}", height = 2,
      foreground = palette.muted, background = palette.bg,
    })
    draw(note, tr("settings.ime_note"), "muted", "bg")
    pages.network.widgets[#pages.network.widgets + 1] = note
  end

  -- ------------------------------------------------------------- 显示 -------
  local display_page = page_frame_for("display")
  local function paint_display()
    local heading = display_page:addLabel({
      x = 1, y = 1, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(heading, tr("settings.display_section"), "accent", "bg")

    local current_name = "?"
    if type(store) == "table" then
      local block = store.load_display()
      if type(block) == "table" and type(block.name) == "string" then
        current_name = block.name
      end
    end
    text_row(display_page, 3, "settings.display_current", current_name, nil)

    local note = display_page:addLabel({
      x = 1, y = 5, width = "{parent.width-2}", height = 2,
      foreground = palette.muted, background = palette.bg,
    })
    draw(note, tr("settings.display_note"), "muted", "bg")
  end

  -- ------------------------------------------------------------- 外观 -------
  local appearance_page = page_frame_for("appearance")
  local function paint_appearance()
    for _, widget in ipairs(pages.appearance.widgets or {}) do
      pcall(function()
        widget:setVisible(false)
      end)
    end
    pages.appearance.widgets = {}

    local heading = appearance_page:addLabel({
      x = 1, y = 1, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(heading, tr("settings.appearance_section"), "accent", "bg")
    pages.appearance.widgets[#pages.appearance.widgets + 1] = heading

    local block = type(store) == "table" and store.load_appearance() or {}
    local keys = type(store) == "table" and store.PALETTE_KEYS
      or { "black", "gray", "lightGray", "orange", "magenta", "pink", "purple" }

    local y = 3
    for _, name in ipairs(keys) do
      local caption = appearance_page:addLabel({
        x = 1, y = y, width = 20, height = 1,
        foreground = palette.muted, background = palette.bg,
      })
      draw(caption, tostring(name), "muted", "bg")
      pages.appearance.widgets[#pages.appearance.widgets + 1] = caption

      local value = block[name]
      local shown = "?"
      if type(value) == "number" then
        shown = string.format("#%06X", value)
      end
      local field = appearance_page:addLabel({
        x = 21, y = y, width = "{parent.width-22}", height = 1,
        foreground = palette.fg, background = palette.bg,
      })
      draw(field, shown, "fg", "bg")
      pages.appearance.widgets[#pages.appearance.widgets + 1] = field
      y = y + 1
    end

    local note = appearance_page:addLabel({
      x = 1, y = y + 1, width = "{parent.width-2}", height = 2,
      foreground = palette.muted, background = palette.bg,
    })
    draw(note, tr("settings.appearance_note"), "muted", "bg")
    pages.appearance.widgets[#pages.appearance.widgets + 1] = note
  end

  -- ------------------------------------------------------------- 音频 -------
  local audio_page = page_frame_for("audio")
  local function paint_audio()
    local heading = audio_page:addLabel({
      x = 1, y = 1, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(heading, tr("settings.audio_section"), "accent", "bg")

    -- Report what the computer can actually reach, rather than offering a
    -- volume slider that does nothing: the transport has no gain stage.
    local found = 0
    local speaker_module = nil
    local require_fn = rawget(_G, "require")
    if type(require_fn) == "function" then
      local ok, value = pcall(require_fn, "player.speaker")
      if ok and type(value) == "table" then
        speaker_module = value
      end
    end
    if speaker_module ~= nil and type(speaker_module.discover) == "function" then
      local ok, list = pcall(speaker_module.discover)
      if ok and type(list) == "table" then
        found = #list
      end
    end

    text_row(audio_page, 3, "settings.audio_speakers", tostring(found), nil)
    local note = audio_page:addLabel({
      x = 1, y = 5, width = "{parent.width-2}", height = 2,
      foreground = palette.muted, background = palette.bg,
    })
    draw(note, tr("settings.audio_note"), "muted", "bg")
  end

  -- ------------------------------------------------------------- 常规 -------
  local general_page = page_frame_for("general")
  local function paint_general()
    local heading = general_page:addLabel({
      x = 1, y = 1, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(heading, tr("settings.general_section"), "accent", "bg")

    local language = "en"
    if type(store) == "table" then
      local block = store.load_language()
      if type(block) == "table" and type(block.code) == "string" then
        language = block.code
      end
    end
    text_row(general_page, 3, "settings.language", language, function()
      local next_code = language == "zh" and "en" or "zh"
      if type(store) == "table" then
        store.save_language({ code = next_code })
      end
      set_status(tr("settings.restart_required"))
    end)

    local clear = general_page:addButton({
      x = 1, y = 5, width = 24, height = 3,
      foreground = palette.fg, background = palette.active,
    })
    draw(clear, tr("settings.clear_history"), "fg", "active")
    clear:onClick(function()
      local history = ctx.history
      if type(history) == "table" and type(history.clear) == "function" then
        pcall(history.clear)
      end
      if type(history) == "table"
        and type(history.clear_favourites) == "function" then
        pcall(history.clear_favourites)
      end
      set_status(tr("settings.cleared"))
    end)
  end

  -- ------------------------------------------------------------- 关于 -------
  local about_page = page_frame_for("about")
  do
    local line_key = {
      "about.title", "about.purpose", "about.not_official", "about.licence",
      "about.basalt", "about.utf8", "about.font", "about.nbw", "about.keyboard",
    }
    local y = 1
    for _, key in ipairs(line_key) do
      local label = about_page:addLabel({
        x = 1, y = y, width = "{parent.width-2}", height = 2,
        foreground = y == 1 and palette.accent or palette.fg,
        background = palette.bg,
      })
      draw(label, tr(key), y == 1 and "accent" or "fg", "bg")
      y = y + 2
    end
  end

  -- ------------------------------------------------------------- 更新 -------
  local update_page = page_frame_for("update")
  do
    local heading = update_page:addLabel({
      x = 1, y = 1, width = "{parent.width-2}", height = 1,
      foreground = palette.accent, background = palette.bg,
    })
    draw(heading, tr("settings.update_section"), "accent", "bg")

    local note = update_page:addLabel({
      x = 1, y = 3, width = "{parent.width-2}", height = 4,
      foreground = palette.fg, background = palette.bg,
    })
    draw(note, tr("settings.update_note"), "fg", "bg")
  end

  -- ------------------------------------------------------- navigation -------
  local show_page

  show_page = function(key)
    for page_key, entry in pairs(pages) do
      pcall(function()
        entry.frame:setVisible(page_key == key)
      end)
    end
    for button_key, button in pairs(nav_buttons) do
      local selected = button_key == key
      pcall(function()
        button:setBackground(selected and palette.active or palette.panel)
      end)
    end
    current = key
    if key == "network" then
      paint_network()
    elseif key == "display" then
      paint_display()
    elseif key == "appearance" then
      paint_appearance()
    elseif key == "audio" then
      paint_audio()
    elseif key == "general" then
      paint_general()
    end
  end

  local y = 1
  for _, entry in ipairs(settings_screen.PAGES) do
    page_frame_for(entry.key)
    local button = nav:addButton({
      x = 1, y = y, width = 17, height = 3,
      foreground = palette.fg, background = palette.panel,
    })
    draw(button, tr(entry.label), "fg", "panel")
    local key = entry.key
    button:onClick(function()
      show_page(key)
    end)
    nav_buttons[key] = button
    y = y + 4
  end

  local close_button = window:addButton({
    x = "{parent.width-13}", y = 1, width = 12, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  draw(close_button, tr("settings.close"), "fg", "active")

  local page = {
    frame = window,
  }

  function page.show()
    window:setVisible(true)
    show_page(current or "network")
    set_status("")
  end

  function page.hide()
    window:setVisible(false)
    -- Hand focus back: the window is the only thing that wanted keystrokes.
    page.editing = nil
  end

  close_button:onClick(function()
    page.hide()
  end)

  -- The shell routes characters here while `editing` is set, the same way it
  -- does for the search box.
  function page.on_key(key, character)
    local editing = page.editing
    if editing == nil then
      return false
    end
    local keys = rawget(_G, "keys") or {}
    if key == keys.escape then
      page.editing = nil
      set_status(tr("settings.edit_cancelled"))
      return true
    elseif key == keys.backspace then
      editing.buffer = editing.buffer:sub(1, math.max(0, #editing.buffer - 1))
      set_status(tr("settings.editing", { value = editing.buffer }))
      return true
    elseif key == keys.enter then
      local url, error_key = settings_screen.validate_url_input(editing.buffer,
        store)
      if url == nil then
        -- Reported, not swallowed: a silent no-op is how a user comes to
        -- believe they configured something they did not.
        set_status(tr(error_key))
        return true
      end
      if type(store) == "table" then
        local block = store.load_ime()
        if type(block) ~= "table" then
          block = {}
        end
        block.url = url
        store.save_ime(block)
      end
      if type(ime) == "table" and type(ime.configure) == "function" then
        pcall(ime.configure, { url = url })
      end
      page.editing = nil
      set_status(tr("settings.saved"))
      show_page("network")
      return true
    end

    if type(character) == "string" and character ~= "" then
      if #editing.buffer < 160 then
        editing.buffer = editing.buffer .. character
        set_status(tr("settings.editing", { value = editing.buffer }))
      end
      return true
    end
    return false
  end

  window:setVisible(false)
  return page
end

return settings_screen
