-- ui/screens/nowplaying.lua
--
-- THE FULL-SCREEN NOW-PLAYING CARD -- the reference's max-play page.
--
-- The reference's version fills the monitor with album art, lyrics and a large
-- transport.  Note Block World songs have no artwork and no lyrics, so the space
-- that held lyrics holds what a song DOES have and what its licence requires to
-- be shown:
--
--   * the title, the author, and the licence in words;
--   * the attribution, which is the credit the licence asks for;
--   * a large seekable progress bar and the transport;
--   * the speaker situation (found vs required), which replaces the volume
--     slider the reference has -- our transport has no gain stage, so a slider
--     would be a control that does nothing.
--
-- ===========================================================================
-- SEEKING GOES THROUGH THE TRANSPORT, NOT THROUGH A CLOCK
-- ===========================================================================
-- The transport already implements a seek as "cancel, rebase, replay", so this
-- page only converts a click column into a 0..1 fraction -- the same arithmetic
-- the reference uses on its own progress strip.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local nowplaying = {}

-- nowplaying.seek_fraction(column, width) -> 0..1.  PURE, and clamped at both
-- ends so a click on the first or last cell cannot overshoot.
function nowplaying.seek_fraction(column, width)
  local cells = tonumber(width) or 0
  local x = tonumber(column) or 1
  if cells <= 1 then
    return 0
  end
  local frac = (x - 1) / (cells - 1)
  if frac < 0 then
    return 0
  end
  if frac > 1 then
    return 1
  end
  return frac
end

-- nowplaying.format_clock(ms) -> "M:SS" | "?".
function nowplaying.format_clock(ms)
  local value = tonumber(ms)
  if value == nil or value < 0 then
    return "?"
  end
  local total_seconds = math.floor(value / 1000)
  local minutes = math.floor(total_seconds / 60)
  local seconds = total_seconds - minutes * 60
  return string.format("%d:%02d", minutes, seconds)
end

-- build(ctx) -> page
--   page.show(song)   display a song and open the page
--   page.refresh()    redraw the progress from the transport
function nowplaying.build(ctx)
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end
  local transport = ctx.transport

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local title = page_frame:addLabel({
    x = 1, y = 2, width = "{parent.width-2}", height = 3,
    foreground = palette.accent, background = palette.bg,
  })
  local author = page_frame:addLabel({
    x = 1, y = 5, width = "{parent.width-2}", height = 1,
    foreground = palette.fg, background = palette.bg,
  })

  -- The licence block, given a fixed place on the card so it cannot scroll out
  -- of view while a song plays.
  local licence_caption = page_frame:addLabel({
    x = 1, y = 7, width = 12, height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  local licence = page_frame:addLabel({
    x = 13, y = 7, width = "{parent.width-14}", height = 4,
    foreground = palette.fg, background = palette.bg,
  })
  local credit_caption = page_frame:addLabel({
    x = 1, y = 12, width = 12, height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  local credit = page_frame:addLabel({
    x = 13, y = 12, width = "{parent.width-14}", height = 3,
    foreground = palette.fg, background = palette.bg,
  })

  local elapsed = page_frame:addLabel({
    x = 1, y = "{parent.height-8}", width = 12, height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  local remaining = page_frame:addLabel({
    x = "{parent.width-13}", y = "{parent.height-8}", width = 12, height = 1,
    foreground = palette.muted, background = palette.bg,
  })

  local track = page_frame:addLabel({
    x = 1, y = "{parent.height-7}", width = "{parent.width-2}", height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  local ahead = page_frame:addLabel({
    x = 1, y = "{parent.height-7}", width = "{parent.width-2}", height = 1,
    foreground = palette.accent, background = palette.bg,
  })

  local seek_area = page_frame:addButton({
    x = 1, y = "{parent.height-7}", width = "{parent.width-2}", height = 1,
    text = "", backgroundEnabled = false, z = 22,
  })
  seek_area:onClick(function(self, button, x)
    if type(transport) ~= "table" or type(transport.seek) ~= "function" then
      return
    end
    local cells = 1
    if type(self.getWidth) == "function" then
      local ok, value = pcall(self.getWidth, self)
      if ok and type(value) == "number" then
        cells = value
      end
    end
    pcall(transport.seek, nowplaying.seek_fraction(x, cells))
    page.refresh()
  end)

  -- Speaker situation instead of a volume slider: the transport has no gain.
  local speakers = page_frame:addLabel({
    x = 1, y = "{parent.height-5}", width = 24, height = 1,
    foreground = palette.muted, background = palette.bg,
  })

  local play_button = page_frame:addButton({
    x = "{floor(parent.width/2-10)}", y = "{parent.height-4}",
    width = 8, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  local close_button = page_frame:addButton({
    x = "{floor(parent.width/2+1)}", y = "{parent.height-4}",
    width = 8, height = 3,
    foreground = palette.fg, background = palette.panel,
  })
  draw(close_button, tr("player.close"), "fg", "panel")

  local page = {
    frame = page_frame,
    song = nil,
  }

  function page.refresh()
    local info = nil
    if type(transport) == "table"
      and type(transport.progress) == "function" then
      local ok, value = pcall(transport.progress)
      if ok and type(value) == "table" then
        info = value
      end
    end

    local frac = type(info) == "table" and tonumber(info.frac) or 0
    if frac == nil then
      frac = 0
    end
    if frac < 0 then frac = 0 end
    if frac > 1 then frac = 1 end

    local position = type(info) == "table" and tonumber(info.t_ms) or 0
    local total = 0
    if type(transport) == "table"
      and type(transport.duration_ms) == "function" then
      local ok, value = pcall(transport.duration_ms)
      if ok and type(value) == "number" then
        total = value
      end
    end

    draw(elapsed, nowplaying.format_clock(position), "muted", "bg")
    local left = total > 0 and math.max(0, total - (position or 0)) or nil
    draw(remaining, left ~= nil and ("-" .. nowplaying.format_clock(left))
      or nowplaying.format_clock(total), "muted", "bg")

    local cells = 0
    if type(track.getWidth) == "function" then
      local ok, value = pcall(track.getWidth, track)
      if ok and type(value) == "number" then
        cells = value
      end
    end
    local filled = math.floor(cells * frac + 0.5)
    pcall(function()
      track.setText(string.rep("\131", cells))
      ahead:setText(string.rep("\131", filled)
        .. string.rep(" ", math.max(0, cells - filled)))
    end)

    local state = "stopped"
    if type(transport) == "table" and type(transport.state) == "function" then
      local ok, value = pcall(transport.state)
      if ok and type(value) == "string" then
        state = value
      end
    end
    draw(play_button, tr(state == "playing" and "player.pause" or "player.play"),
      "fg", "active")
  end

  function page.show(song)
    page.song = song
    -- The licence and the credit are drawn from the SAME summary the detail
    -- page uses, so the two pages cannot state a licence differently.
    local detail_screen = ctx.detail_screen
    local summary = nil
    if type(detail_screen) == "table"
      and type(detail_screen.summary) == "function" then
      summary = detail_screen.summary(song, ctx.nbw, tr)
    elseif type(song) == "table" then
      summary = {
        title = type(song.title) == "string" and song.title or tr("song.unknown_title"),
        author = type(song.author) == "string" and song.author or tr("song.unknown_author"),
        licence = type(song.license) == "string" and song.license or tr("song.no_licence"),
        attribution = type(song.attribution) == "string" and song.attribution or "",
        url = "",
      }
    end

    if summary ~= nil then
      draw(title, summary.title, "accent", "bg")
      draw(author, summary.author, "fg", "bg")
      draw(licence_caption, tr("song.licence"), "muted", "bg")
      draw(licence, summary.licence, "fg", "bg")
      draw(credit_caption, tr("song.credit"), "muted", "bg")
      draw(credit, summary.attribution, "fg", "bg")
    end

    page.refresh()
  end

  play_button:onClick(function()
    if type(transport) == "table" and type(transport.toggle) == "function" then
      pcall(transport.toggle)
    end
    page.refresh()
  end)

  close_button:onClick(function()
    if type(ctx.on_close) == "function" then
      ctx.on_close()
    end
  end)

  return page
end

return nowplaying
