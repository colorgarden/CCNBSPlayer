-- ui/screens/collection.lua
--
-- THE SHARED COLLECTION PAGE -- title, info line, a scrollable list of rows, and
-- paging controls.
--
-- This reproduces the reference implementation's collection-page pattern, which
-- it uses for every list it shows (search results, playlists, history, ...).
-- Having ONE builder means the pages cannot drift apart: a change to how a row
-- is drawn, or to the paging maths, lands everywhere at once.
--
-- ===========================================================================
-- WHY ROWS ARE FRAMES RATHER THAN A LIST ELEMENT
-- ===========================================================================
-- A Basalt `List` renders its own text and cannot show an icon, a second line,
-- or per-row colour.  The reference therefore builds each row as a small FRAME
-- containing labels and a button, which is what this does too -- so a row can
-- carry a title, an author line, and a licence badge.
--
-- ===========================================================================
-- EMPTY AND ERROR ARE DIFFERENT, AND BOTH ARE SHOWN
-- ===========================================================================
-- A search that returned nothing and a search that FAILED look identical if both
-- render as a blank page, and the user cannot tell whether to retry.  So the
-- builder takes `state` ("ready" | "loading" | "empty" | "error") and always
-- draws a line saying which it is.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local collection = {}

-- How many rows one page shows.  Matches the reference's own page sizes closely
-- enough that the paging buttons land in the same place.
collection.PAGE_SIZE = 12

-- ---------------------------------------------------------------------------
-- Paging maths -- PURE, so it can be reasoned about without a terminal
-- ---------------------------------------------------------------------------

-- collection.page_count(total, size) -> integer >= 1.
-- A zero-length list still has ONE page (the one showing "nothing here"), which
-- is why this never returns 0.
function collection.page_count(total, size)
  local count = tonumber(total) or 0
  local per = tonumber(size) or collection.PAGE_SIZE
  if per < 1 then
    per = 1
  end
  if count <= 0 then
    return 1
  end
  return math.floor((count - 1) / per) + 1
end

-- collection.clamp_page(page, total, size) -> integer in 1..page_count.
function collection.clamp_page(page, total, size)
  local wanted = math.floor(tonumber(page) or 1)
  if wanted < 1 then
    wanted = 1
  end
  local last = collection.page_count(total, size)
  if wanted > last then
    wanted = last
  end
  return wanted
end

-- collection.slice(items, page, size) -> the items on that page, plus the
-- 1-based index of the first one so a row can show its absolute position.
function collection.slice(items, page, size)
  local out = {}
  if type(items) ~= "table" then
    return out, 0
  end
  local per = tonumber(size) or collection.PAGE_SIZE
  if per < 1 then
    per = 1
  end
  local current = collection.clamp_page(page, #items, per)
  local first = (current - 1) * per + 1
  for offset = 0, per - 1 do
    local item = items[first + offset]
    if item == nil then
      break
    end
    out[#out + 1] = item
  end
  return out, first
end

-- ---------------------------------------------------------------------------
-- Status lines -- one place decides what "nothing" and "broken" say
-- ---------------------------------------------------------------------------

-- collection.status_text(state, tr, details) -> a string, or "" for "ready".
function collection.status_text(state, tr, details)
  details = type(details) == "table" and details or {}
  if state == "loading" then
    return tr("list.loading")
  end
  if state == "empty" then
    return tr("list.empty")
  end
  if state == "error" then
    local message = details.error
    if type(message) ~= "string" or message == "" then
      message = tr("list.error")
    end
    return message
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

-- collection.row_text(item, tr) -> title, subtitle.
-- The subtitle carries the AUTHOR and, for an NBW song, its licence, because a
-- song's licence is an obligation rather than decoration: the user has to be
-- able to see it before playing.
function collection.row_text(item, tr)
  if type(item) ~= "table" then
    return "?", ""
  end
  local title = type(item.title) == "string" and item.title or "?"
  local author = type(item.author) == "string" and item.author or tr("song.unknown_author")
  local subtitle = author
  if type(item.kind) == "string" and item.kind == "nbw" then
    -- A short badge rather than the whole licence sentence: the sentence is
    -- shown on the detail page, where there is room for it.
    if type(item.license) == "string" and item.license ~= "" then
      local badge = item.license:match("^(%S+)")
      if badge ~= nil then
        subtitle = subtitle .. "  [" .. badge .. "]"
      end
    end
  end
  return title, subtitle
end

-- ---------------------------------------------------------------------------
-- The page
-- ---------------------------------------------------------------------------

-- collection.build(ctx, opts) -> page
--   page.frame    the container, already added to `ctx.parent`
--   page.refresh  re-renders from page.state.items
--   page.set_items(items, state, details)  replaces the contents
--   page.state    { items, state, details, page }
--
-- `opts` = { title, on_activate(item), on_download(item), page_size,
--            rows_visible, empty_hint }
function collection.build(ctx, opts)
  opts = type(opts) == "table" and opts or {}
  local frame_helpers = ctx.frame
  local colors_table = ctx.colors or {}
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end
  local utf8display = ctx.utf8display

  local title_height = 3
  local info_height = 1
  local pager_height = 3
  local row_height = 3
  local page_size = tonumber(opts.page_size) or collection.PAGE_SIZE

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local title_label = page_frame:addLabel({
    x = 1, y = 1, width = "{parent.width-2}", height = title_height,
    foreground = palette.fg, background = palette.bg,
  })
  draw(title_label, opts.title or "", "fg", "bg")

  local info_label = page_frame:addLabel({
    x = 1, y = 1 + title_height, width = "{parent.width-2}",
    height = info_height,
    foreground = palette.muted, background = palette.bg,
  })

  local list_top = 1 + title_height + info_height
  local list_height = "{parent.height-"
    .. (title_height + info_height + pager_height) .. "}"
  local list_frame = page_frame:addFrame({
    x = 1, y = list_top, width = "{parent.width-2}", height = list_height,
    background = palette.bg,
  })

  local pager = page_frame:addFrame({
    x = 1, y = "{parent.height-" .. (pager_height - 1) .. "}",
    width = "{parent.width-2}", height = pager_height,
    background = palette.bg,
  })

  local previous_button = pager:addButton({
    x = 1, y = 1, width = 12, height = pager_height,
    foreground = palette.fg, background = palette.panel,
  })
  draw(previous_button, tr("list.previous"), "fg", "panel")

  local page_label = pager:addLabel({
    x = 14, y = 1, width = "{parent.width-28}", height = pager_height,
    foreground = palette.fg, background = palette.bg,
  })

  local next_button = pager:addButton({
    x = "{parent.width-11}", y = 1, width = 12, height = pager_height,
    foreground = palette.fg, background = palette.panel,
  })
  draw(next_button, tr("list.next"), "fg", "panel")

  local state = {
    items = {},
    state = "ready",
    details = {},
    page = 1,
  }

  -- Rows are rebuilt in place rather than layered, so a page change cannot leave
  -- a stale row visible underneath a new one.
  local rows = {}

  local function clear_rows()
    for _, row in ipairs(rows) do
      pcall(function()
        row.frame:setVisible(false)
      end)
    end
    rows = {}
  end

  local function build_row(item, index, y)
    local row = list_frame:addFrame({
      x = 1, y = y, width = "{parent.width}", height = row_height,
      background = palette.panel,
    })

    local number = row:addLabel({
      x = 1, y = 1, width = 4, height = row_height,
      foreground = palette.muted, background = palette.panel,
    })
    pcall(function()
      number.setText(tostring(index))
    end)

    local title, subtitle = collection.row_text(item, tr)
    local title_row = row:addLabel({
      x = 5, y = 1, width = "{parent.width-7}", height = 1,
      foreground = palette.fg, background = palette.panel,
    })
    draw(title_row, title, "fg", "panel")

    local subtitle_row = row:addLabel({
      x = 5, y = 2, width = "{parent.width-7}", height = 1,
      foreground = palette.muted, background = palette.panel,
    })
    draw(subtitle_row, subtitle, "muted", "panel")

    local activate = row:addButton({
      x = 1, y = 1, width = "{parent.width-6}", height = row_height,
      text = "", backgroundEnabled = false, z = 5,
    })
    activate:onClick(function()
      if type(opts.on_activate) == "function" then
        opts.on_activate(item, index)
      end
    end)

    -- A download control is only offered where the caller asked for one, which
    -- is how a local file row avoids showing a meaningless button.
    if type(opts.on_download) == "function" and item.kind == "nbw" then
      local download = row:addButton({
        x = "{parent.width-4}", y = 1, width = 4, height = row_height,
        foreground = palette.fg, background = palette.accent, z = 6,
      })
      draw(download, tr("song.download"), "fg", "accent")
      download:onClick(function()
        opts.on_download(item)
      end)
    end

    return { frame = row, item = item, index = index }
  end

  local refresh  -- forward declared: referenced before its definition below

  refresh = function()
    clear_rows()

    local status = collection.status_text(state.state, tr, state.details)
    local total = #state.items
    local pages = collection.page_count(total, page_size)
    state.page = collection.clamp_page(state.page, total, page_size)

    -- Info line: which page, and how many, or the reason there are none.
    local info
    if status ~= "" then
      info = status
    else
      info = tr("list.page_of", { page = state.page, pages = pages, total = total })
    end
    draw(info_label, info, "muted", "bg")

    local slice, first = collection.slice(state.items, state.page, page_size)
    for offset, item in ipairs(slice) do
      local y = 1 + (offset - 1) * (row_height + 1)
      rows[#rows + 1] = build_row(item, first + offset - 1, y)
    end

    draw(page_label, tr("list.page_label",
      { page = state.page, pages = pages }), "fg", "bg")

    local has_previous = state.page > 1
    local has_next = state.page < pages
    pcall(function()
      previous_button:setEnabled(has_previous)
      next_button:setEnabled(has_next)
    end)
  end

  previous_button:onClick(function()
    if state.page > 1 then
      state.page = state.page - 1
      refresh()
    end
  end)
  next_button:onClick(function()
    if state.page < collection.page_count(#state.items, page_size) then
      state.page = state.page + 1
      refresh()
    end
  end)

  local page = {
    frame = page_frame,
    state = state,
    refresh = refresh,
  }

  -- set_items replaces the contents wholesale.  `state_name` distinguishes an
  -- empty result from a failure, and `details.error` carries a failure message
  -- through to the info line.
  function page.set_items(items, state_name, details)
    state.items = type(items) == "table" and items or {}
    state.state = state_name or (#state.items > 0 and "ready" or "empty")
    state.details = type(details) == "table" and details or {}
    state.page = 1
    refresh()
  end

  -- Apply whatever the caller put in `state` before building, so a screen can
  -- restore its last contents instead of flashing empty on every visit.
  if type(opts.initial_items) == "table" then
    state.items = opts.initial_items
    state.state = opts.initial_state or "ready"
  end
  refresh()

  return page
end

return collection
