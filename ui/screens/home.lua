-- ui/screens/home.lua
--
-- THE HOME PAGE -- a scrolling column of sections, as the reference has.
--
-- The reference's home shows a greeting, a daily-recommendation card, a
-- private-FM card, then several public sections.  Ours keeps the LAYOUT and
-- swaps the sources, because there are no accounts or editorial lists here:
--
--   reference                 ours
--   ----------------------    ------------------------------------------
--   greeting + subtitle       greeting + a subtitle naming what this is
--   daily / like cards        local .nbs files on this computer
--   public playlists          Note Block World picks (a sorted search)
--   artist radar              recently played, from ui/history
--
-- Sections are built the same way at the same x/width, so the page reads like
-- the original even though the content is ours.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local home = {}

home.TITLE = "nav.home"

-- The greeting is time-based, exactly as the reference does it.  A host with no
-- clock yields the neutral greeting rather than an error.
function home.greeting(hour, tr)
  local value = tonumber(hour)
  if value == nil then
    return tr("home.greeting")
  end
  if value < 5 then
    return tr("home.greeting_night")
  elseif value < 12 then
    return tr("home.greeting_morning")
  elseif value < 18 then
    return tr("home.greeting_afternoon")
  end
  return tr("home.greeting_evening")
end

-- home.current_hour() -> integer | nil, read lazily so the module stays
-- require-able without a clock.
local function current_hour()
  local oslib = rawget(_G, "os")
  if type(oslib) ~= "table" then
    return nil
  end
  -- `os.date` is present on Cobalt and gives the local hour directly.
  if type(oslib.date) == "function" then
    local ok, hour = pcall(oslib.date, "*t")
    if ok and type(hour) == "table" and type(hour.hour) == "number" then
      return hour.hour
    end
  end
  return nil
end

-- build(ctx) -> page
function home.build(ctx)
  local frame_helpers = ctx.frame
  local colors_table = ctx.colors or {}
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end
  local songs = ctx.songs
  local history = ctx.history
  local icons = ctx.icons
  local navigate = ctx.navigate or function() end
  local page_size = 8
  local row_height = 3

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  -- A heading, then everything scrolls -- the reference's own arrangement.
  local heading = page_frame:addLabel({
    x = 1, y = 1, width = "{parent.width-2}", height = 3,
    foreground = palette.accent, background = palette.bg,
  })

  local subtitle = page_frame:addLabel({
    x = 1, y = 4, width = "{parent.width-2}", height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  draw(subtitle, tr("home.subtitle"), "muted", "bg")

  local scroll = page_frame:addScrollFrame({
    x = 1, y = 5, width = "{parent.width-2}", height = "{parent.height-6}",
    background = palette.bg,
    scrollBarColor = palette.accent,
    scrollBarBackgroundColor = palette.panel,
    scrollBarBackgroundColor2 = palette.panel,
  })

  local sections = {}

  -- section(key, title) -> { frame, body, add(item), finish() }
  -- Each section owns a frame, a title label, and a growing list of rows.  The
  -- frame's height is fixed at build time by finish(), because Basalt resolves
  -- layout strings once rather than reflowing.
  local function section(key, title, icon_name)
    local holder = scroll:addFrame({
      x = 1, y = 1, width = "{parent.width-1}", height = 3,
      background = palette.bg,
    })

    local title_label = holder:addLabel({
      x = 1, y = 1, width = "{parent.width-1}", height = 3,
      foreground = palette.fg, background = palette.bg,
    })
    local icon = type(icons) == "table" and icons.get(icon_name) or nil
    local combined = frame_helpers.concat_bimg(icon,
      frame_helpers.process_str_to_bimg(ctx.utf8display, title,
        frame_helpers.blit_of(colors_table, palette.fg),
        frame_helpers.blit_of(colors_table, palette.bg)))
    if combined ~= nil and type(title_label.setImage) == "function" then
      pcall(title_label.setImage, title_label, combined)
    else
      draw(title_label, title, "fg", "bg")
    end

    local rows = {}
    local entry = {
      holder = holder,
      key = key,
      rows = rows,
      height = 3,
    }

    function entry.add(item, index, on_activate)
      local y = 1 + #rows * (row_height + 1)
      local row = holder:addFrame({
        x = 1, y = y, width = "{parent.width-1}", height = row_height,
        background = palette.panel,
      })
      local title_row, subtitle_row = nil, nil
      if type(item) == "table" then
        local heading_text = type(item.title) == "string" and item.title or "?"
        local sub = type(item.author) == "string" and item.author or ""
        title_row = row:addLabel({
          x = 3, y = 1, width = "{parent.width-4}", height = 1,
          foreground = palette.fg, background = palette.panel,
        })
        draw(title_row, heading_text, "fg", "panel")
        subtitle_row = row:addLabel({
          x = 3, y = 2, width = "{parent.width-4}", height = 1,
          foreground = palette.muted, background = palette.panel,
        })
        draw(subtitle_row, sub, "muted", "panel")
      else
        -- A plain string, used for the "nothing here" placeholder.
        title_row = row:addLabel({
          x = 3, y = 1, width = "{parent.width-4}", height = 3,
          foreground = palette.muted, background = palette.panel,
        })
        draw(title_row, tostring(item or ""), "muted", "panel")
      end

      local button = row:addButton({
        x = 1, y = 1, width = "{parent.width-2}", height = row_height,
        text = "", backgroundEnabled = false, z = 5,
      })
      button:onClick(function()
        if type(on_activate) == "function" and type(item) == "table" then
          on_activate(item, index)
        end
      end)

      rows[#rows + 1] = row
      entry.height = entry.height + row_height + 1
      return row
    end

    function entry.finish()
      pcall(function()
        holder:setHeight(entry.height)
      end)
    end

    sections[key] = entry
    return entry
  end

  -- Lay the sections out one below another, in the reference's order.
  local function layout()
    local y = 1
    for _, entry in ipairs({ sections.local_files, sections.featured, sections.recent }) do
      if entry ~= nil then
        pcall(function()
          entry.holder:setPosition(1, y)
        end)
        y = y + entry.height + 1
      end
    end
  end

  -- ---------------------------------------------------------------- refresh --
  local function refresh()
    -- Greeting, once per refresh so a long-running session stays correct.
    draw(heading, home.greeting(current_hour(), tr), "accent", "bg")

    -- Rebuild the sections from scratch: the alternative is diffing, which is
    -- more code than it saves for a handful of rows.
    for _, entry in ipairs({ sections.local_files, sections.featured, sections.recent }) do
      if entry ~= nil then
        for _, row in ipairs(entry.rows) do
          pcall(function()
            row:setVisible(false)
          end)
        end
        entry.rows = {}
        entry.height = 3
      end
    end

    -- 1. Local .nbs files.  Always present, because a user with songs on disk
    --    must be able to reach them with no network at all.
    local local_items = {}
    if type(songs) == "table" then
      local ok, value = pcall(songs.local_songs)
      if ok and type(value) == "table" then
        local_items = value
      end
    end
    if #local_items == 0 then
      sections.local_files.add(tr("home.no_local"))
    else
      for index = 1, math.min(#local_items, page_size) do
        local item = local_items[index]
        sections.local_files.add(item, index, function(song)
          if type(ctx.on_play) == "function" then
            ctx.on_play(song)
          end
        end)
      end
    end
    sections.local_files.finish()

    -- 2. Note Block World picks.  A sorted search rather than a curated list,
    --    because NBW has no editorial endpoint -- and a failure here must show
    --    as a failure, not as "there are no songs".
    sections.featured.add(tr("home.loading"))
    sections.featured.finish()

    if type(songs) == "table" and type(songs.search) == "function" then
      ctx.schedule(function()
        local ok, result = pcall(songs.search, {
          page = 1, limit = page_size, sort = "views", order = "desc",
        })
        -- Rebuilt fresh: the placeholder row above must not survive.
        for _, row in ipairs(sections.featured.rows) do
          pcall(function()
            row:setVisible(false)
          end)
        end
        sections.featured.rows = {}
        sections.featured.height = 3

        if not ok or type(result) ~= "table" then
          sections.featured.add(tr("home.offline"))
        elseif result.ok ~= true then
          sections.featured.add(tr("home.offline"))
        elseif type(result.songs) ~= "table" or #result.songs == 0 then
          sections.featured.add(tr("list.empty"))
        else
          for index = 1, math.min(#result.songs, page_size) do
            local item = result.songs[index]
            sections.featured.add(item, index, function(song)
              if type(ctx.on_play) == "function" then
                ctx.on_play(song)
              end
            end)
          end
        end
        sections.featured.finish()
        layout()
      end)
    else
      sections.featured.rows = {}
      sections.featured.add(tr("home.offline"))
      sections.featured.finish()
    end

    -- 3. Recently played, from the local store.
    local recent_items = {}
    if type(history) == "table" and type(history.list) == "function" then
      local ok, value = pcall(history.list)
      if ok and type(value) == "table" then
        recent_items = value
      end
    end
    if #recent_items == 0 then
      sections.recent.add(tr("home.no_recent"))
    else
      for index = 1, math.min(#recent_items, page_size) do
        local item = recent_items[index]
        sections.recent.add(item, index, function(song)
          if type(ctx.on_play) == "function" then
            ctx.on_play(song)
          end
        end)
      end
    end
    sections.recent.finish()

    layout()
  end

  section("local_files", tr("home.section_local"), "Album")
  section("featured", tr("home.section_featured"), "Discover")
  section("recent", tr("home.section_recent"), "Recently")

  refresh()

  return {
    frame = page_frame,
    refresh = refresh,
  }
end

return home
