-- ui/screens/frame.lua
--
-- SHARED SCREEN HELPERS -- the small toolkit every screen builds on.
--
-- These are lifted from the reference implementation's `src/startup.lua`, where
-- the same handful of helpers are used by every page: a bimg builder, a bimg
-- concatenator, the standard inner frame, the popup and confirm dialogs, and
-- the display-selection page.  Reproducing them here means the screens can be
-- written the same way the reference writes its own, instead of each inventing
-- its own plumbing.
--
-- ===========================================================================
-- THE bimg SHAPES, because getting this wrong is silent
-- ===========================================================================
-- Two shapes circulate and they are NOT interchangeable:
--
--   * A bare ROW LIST, which is what an icon file returns:
--         return { {"\135...", "BQBB", "QQBB"}, {...}, {...} }
--     each element is one row: { pixelText, foregroundBlit, backgroundBlit }.
--
--   * A FRAME-WRAPPED bimg, which is what Basalt's `setImage` consumes and what
--     `utf8display.strToBimg` returns (`return {{unpack(rows)}}`):
--         { { row1, row2, ... } }
--     one outer level naming the animation frame.
--
-- So an icon must be WRAPPED before use -- the reference writes
-- `setImage({ require("icons.Home") })` -- and `ConcatBimg` must accept either
-- shape and normalise.  Basalt renders nothing (or garbage) if handed the wrong
-- one, with no error, which is why this is spelled out here.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no math.maxinteger, no collectgarbage, no string.dump, no os.exit, no utf8.*.

local frame = {}

-- ---------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------

-- frame.blit_of(colors_table, colour) -> a single blit character ("0".."f").
-- Basalt's colour strings are blit-encoded, one character per cell.  A missing
-- or unknown colour degrades to white rather than raising.
function frame.blit_of(colors_table, colour)
  if type(colors_table) ~= "table" then
    return "f"
  end
  if type(colors_table.toBlit) == "function" then
    local ok, value = pcall(colors_table.toBlit, colour)
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return "f"
end

-- frame.repeat_blit(blit, count) -> a colour string of exactly `count` cells.
local function repeat_blit(blit, count)
  local character = tostring(blit or "f")
  if #character == 0 then
    character = "f"
  end
  character = character:sub(1, 1)
  if count < 1 then
    return ""
  end
  return string.rep(character, count)
end

-- ---------------------------------------------------------------------------
-- Text -> bimg
-- ---------------------------------------------------------------------------

-- frame.text_length(text) -> the CHARACTER count, not the byte count.
-- `utf8.len` is a Cobalt builtin but absent from the desktop interpreter, so it
-- is read through rawget and guarded; `#text` is the fallback.  The count
-- matters because `strToBimg` wants one colour character per CHARACTER, so a
-- byte count would mis-size the colour strings for CJK text.
function frame.text_length(text)
  local value = tostring(text or "")
  -- `rawget` on a global that may not exist is itself safe, but `utf8.len` may
  -- reject invalid input, so the call is guarded too.
  local utf8 = rawget(_G, "utf8")
  if type(utf8) == "table" and type(utf8.len) == "function" then
    local ok, count = pcall(utf8.len, value)
    if ok and type(count) == "number" then
      return count
    end
  end
  return #value
end

-- frame.process_str_to_bimg(utf8display, text, fg, bg) -> bimg | nil.
-- PURE.  Pads the two colour strings to the character count (the renderer
-- requires that), then asks the CJK renderer for the bitmap.
-- Returns nil -- never raises -- when there is no renderer, no font, or the
-- renderer rejects the text, so the caller can fall back to plain ASCII.
function frame.process_str_to_bimg(utf8display, text, fg, bg)
  local value = tostring(text or "")
  if value == "" then
    return nil
  end
  if type(utf8display) ~= "table"
    or type(utf8display.strToBimg) ~= "function" then
    return nil
  end

  local count = frame.text_length(value)
  local foreground = tostring(fg or "f")
  local background = tostring(bg or "0")
  if count > #foreground then
    foreground = foreground
      .. repeat_blit(foreground:sub(-1), count - #foreground)
  end
  if count > #background then
    background = background
      .. repeat_blit(background:sub(-1), count - #background)
  end

  local ok, image = pcall(utf8display.strToBimg, value, foreground, background)
  if ok and type(image) == "table" then
    return image
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- bimg manipulation
-- ---------------------------------------------------------------------------

-- frame.normalise_bimg(value) -> frame-wrapped bimg | nil.
-- Accepts EITHER shape (see the header) and returns the frame-wrapped form.
-- The two are distinguished structurally: a frame-wrapped bimg's first element
-- is a table whose first element is itself a table (a row), whereas a bare row
-- list's first element IS a row.  A row is `{string, string, string}`.
local function looks_like_row(value)
  return type(value) == "table"
    and type(value[1]) == "string"
    and type(value[2]) == "string"
    and type(value[3]) == "string"
end

function frame.normalise_bimg(value)
  if type(value) ~= "table" then
    return nil
  end
  local first = value[1]
  if first == nil then
    return nil
  end
  -- Already frame-wrapped: value[1][1] is a row.
  if type(first) == "table" and looks_like_row(first[1]) then
    return value
  end
  -- A bare row list.
  if looks_like_row(first) then
    return { value }
  end
  return nil
end

-- frame.concat_bimg(left, right, ...) -> frame-wrapped bimg | nil.
-- Glues bimg blocks side by side, row by row -- which is how the reference puts
-- an icon next to its label.  Rows are padded to the tallest block so a 3-row
-- icon beside a 3-row label lines up.  Arguments may be given in either shape.
function frame.concat_bimg(...)
  local blocks = {}
  for index = 1, select("#", ...) do
    local normalised = frame.normalise_bimg((select(index, ...)))
    if normalised ~= nil then
      blocks[#blocks + 1] = normalised[1]
    end
  end
  if #blocks == 0 then
    return nil
  end

  local height = 0
  for _, rows in ipairs(blocks) do
    if #rows > height then
      height = #rows
    end
  end

  local out_rows = {}
  for row = 1, height do
    local text, fg, bg = "", "", ""
    for _, rows in ipairs(blocks) do
      local entry = rows[row]
      if entry ~= nil then
        text = text .. tostring(entry[1] or "")
        fg = fg .. tostring(entry[2] or "")
        bg = bg .. tostring(entry[3] or "")
      else
        -- A shorter block contributes blank cells of the previous block's
        -- width, so columns stay aligned instead of shearing.
        local width = 0
        local previous = rows[#rows]
        if previous ~= nil then
          width = #tostring(previous[1] or "")
        end
        text = text .. string.rep(" ", width)
        fg = fg .. string.rep("f", width)
        bg = bg .. string.rep("0", width)
      end
    end
    out_rows[row] = { text, fg, bg }
  end
  return { out_rows }
end

-- frame.set_image_or_text(element, text, fg, bg, utf8display) -> boolean.
-- Draws `text` as a bitmap when the renderer can, and as plain text when it
-- cannot.  Returns true when the bitmap path was used.
--
-- This is the ONLY place that decides, so a machine with no CJK font degrades
-- to ASCII everywhere at once instead of in some places and not others -- and a
-- CC terminal draws non-ASCII as garbage, so degrading matters.
function frame.set_image_or_text(element, text, fg, bg, utf8display)
  if type(element) ~= "table" then
    return false
  end
  local image = frame.process_str_to_bimg(utf8display, text, fg, bg)
  if image ~= nil and type(element.setImage) == "function" then
    local ok = pcall(element.setImage, element, image)
    if ok then
      return true
    end
  end
  if type(element.setText) == "function" then
    pcall(element.setText, element, tostring(text or ""))
  end
  return false
end

-- ---------------------------------------------------------------------------
-- The standard content frame
-- ---------------------------------------------------------------------------

-- frame.content_geometry() -> x, y, width, height expressions.
-- Measured from the reference's `CreateNavigationPage`: the content area sits to
-- the right of the 17-wide sidebar and below the 4-tall top bar, leaving 4 rows
-- for the playback bar.  Returned as fragments so a caller can override one
-- without restating the rest.
function frame.content_geometry()
  return 19, 6, "{parent.width-19}", "{parent.height-6-4}"
end

-- frame.create_content_page(parent, title, opts) -> the page frame.
-- `parent` is the main frame; `title` is drawn in the page's own title label.
-- `opts` may carry `utf8display`, `fg`, `bg` and a `title_height` override.
function frame.create_content_page(parent, title, opts)
  opts = type(opts) == "table" and opts or {}
  local x, y, width, height = frame.content_geometry()
  if type(opts.x) == "number" then x = opts.x end
  if type(opts.y) == "number" then y = opts.y end
  if type(opts.width) ~= nil then width = opts.width end
  if type(opts.height) ~= nil then height = opts.height end

  local page = parent:addFrame({
    x = x, y = y, width = width, height = height,
    background = opts.bg,
  })
  if title ~= nil then
    local label = page:addLabel({
      x = 1, y = 1, width = "{parent.width-2}", height = 3,
      foreground = opts.fg, background = opts.bg,
    })
    frame.set_image_or_text(label, title, opts.fg_blit, opts.bg_blit,
      opts.utf8display)
  end
  return page
end

-- ---------------------------------------------------------------------------
-- Popups and confirmations
-- ---------------------------------------------------------------------------

-- frame.show_popup(parent, bimg_or_text, seconds, opts) -> the popup frame.
-- A transient message centred near the top, as the reference shows for warnings
-- and for actions that need no decision.
function frame.show_popup(parent, message, seconds, opts)
  opts = type(opts) == "table" and opts or {}
  local width = tonumber(opts.width) or 30
  local height = tonumber(opts.height) or 3
  local holder = opts.frame or parent

  local popup = holder:addFrame({
    x = "{floor((parent.width-" .. width .. ")/2)}",
    y = tonumber(opts.y) or 2,
    width = width, height = height,
    background = opts.bg,
    z = tonumber(opts.z) or 30,
  })
  local label = popup:addLabel({
    x = 1, y = 1, width = width, height = height,
    foreground = opts.fg, background = opts.bg,
  })
  frame.set_image_or_text(label, message, opts.fg_blit, opts.bg_blit,
    opts.utf8display)

  if type(opts.schedule) == "function" then
    local lifetime = tonumber(seconds) or 2
    opts.schedule(function()
      -- A sleep inside a scheduled coroutine, which is the only place it is
      -- legal: handlers must not yield.
      local sleeper = opts.sleep
      if type(sleeper) == "function" then
        sleeper(lifetime)
      end
      pcall(function()
        popup:setVisible(false)
      end)
    end)
  end
  return popup
end

-- frame.create_confirm_dialog(parent, opts) -> dialog frame, on_confirm, on_cancel.
-- `opts` = { title, message, confirm, cancel, utf8display, fg, bg, accent,
--            on_confirm, on_cancel }.
-- The dialog is deliberately NOT auto-removed on cancel: the caller owns its
-- lifetime, because only the caller knows whether it is reusable.
function frame.create_confirm_dialog(parent, opts)
  opts = type(opts) == "table" and opts or {}
  local width = tonumber(opts.width) or 40
  local height = tonumber(opts.height) or 12

  local dialog = parent:addFrame({
    x = "{floor((parent.width-" .. width .. ")/2)}",
    y = "{floor((parent.height-" .. height .. ")/2)}",
    width = width, height = height,
    background = opts.bg,
    z = tonumber(opts.z) or 40,
  })

  local title = dialog:addLabel({
    x = 2, y = 1, width = width - 4, height = 3,
    foreground = opts.accent, background = opts.bg,
  })
  frame.set_image_or_text(title, opts.title or "", opts.accent_blit,
    opts.bg_blit, opts.utf8display)

  local body = dialog:addLabel({
    x = 2, y = 4, width = width - 4, height = height - 8,
    foreground = opts.fg, background = opts.bg,
  })
  frame.set_image_or_text(body, opts.message or "", opts.fg_blit,
    opts.bg_blit, opts.utf8display)

  local half = "{floor(parent.width/2-2)}"
  local confirm = dialog:addButton({
    x = 2, y = height - 3, width = half, height = 3,
    foreground = opts.fg, background = opts.accent,
  })
  frame.set_image_or_text(confirm, opts.confirm or "OK", opts.fg_blit,
    opts.accent_blit, opts.utf8display)

  local cancel = dialog:addButton({
    x = "{floor(parent.width/2+1)}", y = height - 3,
    width = half, height = 3,
    foreground = opts.fg, background = opts.bg,
  })
  frame.set_image_or_text(cancel, opts.cancel or "Cancel", opts.fg_blit,
    opts.bg_blit, opts.utf8display)

  local function close()
    pcall(function()
      dialog:setVisible(false)
    end)
  end

  confirm:onClick(function()
    close()
    if type(opts.on_confirm) == "function" then
      opts.on_confirm()
    end
  end)
  cancel:onClick(function()
    close()
    if type(opts.on_cancel) == "function" then
      opts.on_cancel()
    end
  end)

  return dialog
end

-- ---------------------------------------------------------------------------
-- The display-selection page
-- ---------------------------------------------------------------------------

-- frame.available_monitors() -> array of { name, peripheral }.
-- A monitor is any peripheral whose type is "monitor".  Returned sorted by name
-- so the list is stable between runs.
function frame.available_monitors()
  local peripheral = (pcall(rawget, _G, "peripheral"))
      and rawget(_G, "peripheral") or nil
  if type(peripheral) ~= "table"
    or type(peripheral.getNames) ~= "function" then
    return {}
  end
  local ok, names = pcall(peripheral.getNames)
  if not ok or type(names) ~= "table" then
    return {}
  end

  local monitors = {}
  for _, side in ipairs(names) do
    local type_ok, kind = pcall(peripheral.getType, side)
    if type_ok and kind == "monitor" then
      local object_ok, object = pcall(peripheral.wrap, side)
      if object_ok and object ~= nil then
        monitors[#monitors + 1] = { name = side, peripheral = object }
      end
    end
  end
  table.sort(monitors, function(left, right)
    return left.name < right.name
  end)
  return monitors
end

-- frame.create_display_selection_page(parent, monitors, opts) -> page frame.
-- Shown when the remembered monitor is gone or was never chosen: the program
-- cannot lay itself out without a target, so this must come first.  `opts.on_pick`
-- is called with the chosen `{ name, peripheral }`.
function frame.create_display_selection_page(parent, monitors, opts)
  opts = type(opts) == "table" and opts or {}
  monitors = type(monitors) == "table" and monitors or {}

  local page = parent:addFrame({
    x = 1, y = 1, width = "{parent.width}", height = "{parent.height}",
    background = opts.bg,
  })

  local heading = page:addLabel({
    x = 1, y = 1, width = "{parent.width}", height = 3,
    foreground = opts.fg, background = opts.bg,
  })
  frame.set_image_or_text(heading, opts.title or "Select a display",
    opts.fg_blit, opts.bg_blit, opts.utf8display)

  local scroll = page:addScrollFrame({
    x = 1, y = 4, width = "{parent.width}", height = "{parent.height-3}",
    background = opts.bg,
    scrollBarColor = opts.accent,
    scrollBarBackgroundColor = opts.fg,
    scrollBarBackgroundColor2 = opts.fg,
  })

  if #monitors == 0 then
    local empty = scroll:addLabel({
      x = 2, y = 2, width = "{parent.width-4}", height = 3,
      foreground = opts.fg, background = opts.bg,
    })
    frame.set_image_or_text(empty, opts.empty or "No monitors found",
      opts.fg_blit, opts.bg_blit, opts.utf8display)
    return page
  end

  local y = 2
  for _, monitor in ipairs(monitors) do
    local button = scroll:addButton({
      x = 2, y = y, width = "{parent.width-4}", height = 3,
      foreground = opts.fg, background = opts.bg,
    })
    frame.set_image_or_text(button, monitor.name, opts.fg_blit, opts.bg_blit,
      opts.utf8display)
    local picked = monitor
    button:onClick(function()
      if type(opts.on_pick) == "function" then
        opts.on_pick(picked)
      end
    end)
    y = y + 4
  end

  return page
end

-- ---------------------------------------------------------------------------
-- Palette
-- ---------------------------------------------------------------------------

-- frame.apply_palette(term, colors_table, appearance) -> count applied.
-- The reference redefines seven of the sixteen palette entries for its dark
-- theme; `appearance` is a `{ colourName = 0xRRGGBB }` table.  Best effort: a
-- host with no palette support keeps its defaults.
function frame.apply_palette(term, colors_table, appearance)
  if type(term) ~= "table" or type(term.setPaletteColor) ~= "function" then
    return 0
  end
  if type(colors_table) ~= "table" or type(appearance) ~= "table" then
    return 0
  end

  -- Fixed order so the result is deterministic and a test can count it.
  local order = { "black", "gray", "lightGray", "orange", "magenta", "pink",
                  "purple" }
  local applied = 0
  for _, name in ipairs(order) do
    local slot = colors_table[name]
    local colour = appearance[name]
    if slot ~= nil and type(colour) == "number" then
      local ok = pcall(term.setPaletteColor, slot, colour)
      if ok then
        applied = applied + 1
      end
    end
  end
  return applied
end

return frame
