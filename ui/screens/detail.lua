-- ui/screens/detail.lua
--
-- THE SONG DETAIL PAGE -- what replaces the reference's playlist / album /
-- artist pages.
--
-- Note Block World exposes one collection, so three of the reference's pages
-- collapse into this one.  What it must carry is NOT negotiable:
--
--   * the song's LICENCE, in words, from `nbw.license_label`.  A song's licence
--     is an obligation, not decoration: `standard` means personal listening only
--     and `cc_by_sa` means reuse is allowed with attribution.  Showing the title
--     without the licence would let a user redistribute something they may not.
--   * the ATTRIBUTION, from `nbw.attribution`, which names the uploader and
--     links the song page.  This is the credit the licence requires.
--
-- So both are drawn unconditionally, and a missing licence renders a NEUTRAL
-- label ("unknown -- treat as all rights reserved") rather than being hidden.
-- Hiding it would read as "no restrictions", which is the opposite of true.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local detail = {}

-- ---------------------------------------------------------------------------
-- Pure helpers -- what the page will say, decided before anything is drawn
-- ---------------------------------------------------------------------------

-- detail.summary(song, nbw, tr) -> { title, author, licence, attribution, url }
-- Every field is a non-empty string, because a UI that renders nil shows the
-- user a crash.  `nbw` is the client whose licence/attribution wording is used;
-- when it is unavailable the page says so rather than inventing its own text.
function detail.summary(song, nbw, tr)
  local function fallback(key)
    return tostring(key)
  end
  local translate = type(tr) == "function" and tr or fallback

  if type(song) ~= "table" then
    return {
      title = translate("song.unknown_title"),
      author = translate("song.unknown_author"),
      licence = translate("song.no_licence"),
      attribution = translate("song.no_attribution"),
      url = "",
      id = nil,
    }
  end

  local title = type(song.title) == "string" and song.title ~= ""
    and song.title or translate("song.unknown_title")
  local author = type(song.author) == "string" and song.author ~= ""
    and song.author or translate("song.unknown_author")

  local licence
  if type(nbw) == "table" and type(nbw.license_label) == "function" then
    local raw = song.extra and song.extra.license or song.license
    local ok, text = pcall(nbw.license_label, raw)
    if ok and type(text) == "string" and text ~= "" then
      licence = text
    end
  end
  if licence == nil then
    -- Deliberately NOT blank: an unstated licence must read as restrictive.
    licence = type(song.license) == "string" and song.license
      or translate("song.no_licence")
  end

  local attribution
  if type(nbw) == "table" and type(nbw.attribution) == "function" then
    local source = type(song.extra) == "table" and song.extra or song
    local ok, text = pcall(nbw.attribution, source)
    if ok and type(text) == "string" and text ~= "" then
      attribution = text
    end
  end
  if attribution == nil then
    attribution = author
  end

  local url = ""
  local id = song.ref
  if type(id) == "string" and id ~= ""
    and type(nbw) == "table" and type(nbw.song_page_url) == "function" then
    local ok, text = pcall(nbw.song_page_url, id)
    if ok and type(text) == "string" then
      url = text
    end
  end

  return {
    title = title,
    author = author,
    licence = licence,
    attribution = attribution,
    url = url,
    id = type(id) == "string" and id or nil,
  }
end

-- ---------------------------------------------------------------------------
-- The page
-- ---------------------------------------------------------------------------

-- detail.build(ctx) -> page
--   page.show(song)   display a song (a normalised record from ui.songs)
function detail.build(ctx)
  local frame_helpers = ctx.frame
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end
  local songs = ctx.songs
  local nbw = ctx.nbw
  local navigate = ctx.navigate or function() end

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local title_label = page_frame:addLabel({
    x = 1, y = 1, width = "{parent.width-2}", height = 3,
    foreground = palette.accent, background = palette.bg,
  })
  local author_label = page_frame:addLabel({
    x = 1, y = 4, width = "{parent.width-2}", height = 1,
    foreground = palette.fg, background = palette.bg,
  })

  -- The two obligation blocks, given their own rows so they cannot be dropped
  -- by a later layout change without the labels disappearing entirely.
  local licence_caption = page_frame:addLabel({
    x = 1, y = 6, width = 12, height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  local licence_label = page_frame:addLabel({
    x = 13, y = 6, width = "{parent.width-14}", height = 4,
    foreground = palette.fg, background = palette.bg,
  })
  local credit_caption = page_frame:addLabel({
    x = 1, y = 11, width = 12, height = 1,
    foreground = palette.muted, background = palette.bg,
  })
  local credit_label = page_frame:addLabel({
    x = 13, y = 11, width = "{parent.width-14}", height = 4,
    foreground = palette.fg, background = palette.bg,
  })

  local url_label = page_frame:addLabel({
    x = 1, y = 16, width = "{parent.width-2}", height = 1,
    foreground = palette.muted, background = palette.bg,
  })

  local status_label = page_frame:addLabel({
    x = 1, y = "{parent.height-1}", width = "{parent.width-2}", height = 1,
    foreground = palette.muted, background = palette.bg,
  })

  local play_button = page_frame:addButton({
    x = 1, y = "{parent.height-4}", width = 18, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  draw(play_button, tr("song.play"), "fg", "active")

  local download_button = page_frame:addButton({
    x = 20, y = "{parent.height-4}", width = 18, height = 3,
    foreground = palette.fg, background = palette.accent,
  })
  draw(download_button, tr("song.download"), "fg", "accent")

  local page = {
    frame = page_frame,
    song = nil,
  }

  local function paint()
    local summary = detail.summary(page.song, nbw, tr)
    draw(title_label, summary.title, "accent", "bg")
    draw(author_label, summary.author, "fg", "bg")
    draw(licence_caption, tr("song.licence"), "muted", "bg")
    draw(licence_label, summary.licence, "fg", "bg")
    draw(credit_caption, tr("song.credit"), "muted", "bg")
    draw(credit_label, summary.attribution, "fg", "bg")
    draw(url_label, summary.url, "muted", "bg")

    -- Download is offered only where it can work: a local file is already on
    -- disk, and a song with no id has nothing to fetch.
    local can_download = type(page.song) == "table"
      and page.song.kind == "nbw"
      and type(summary.id) == "string"
    pcall(function()
      download_button:setEnabled(can_download)
      download_button:setVisible(can_download)
    end)
  end

  -- page.show(song) -- set the song and draw it.
  function page.show(song)
    page.song = song
    paint()
    draw(status_label, "", "muted", "bg")

    -- A local record has everything it needs already; only an NBW record has a
    -- detail endpoint worth calling, and only to enrich what is displayed.
    if type(song) == "table" and song.kind == "nbw"
      and type(song.ref) == "string" and type(songs) == "table"
      and type(songs.detail) == "function" then
      local id = song.ref
      ctx.schedule(function()
        local ok, result = pcall(songs.detail, id)
        if ok and type(result) == "table" and result.ok == true
          and type(result.song) == "table" then
          -- Only replace if the user has not navigated on to another song.
          if page.song == song then
            local merged = {}
            for key, value in pairs(song) do
              merged[key] = value
            end
            local fresh = result.song
            if type(fresh.title) == "string" and fresh.title ~= "" then
              merged.title = fresh.title
            end
            if type(fresh.uploader) == "table"
              and type(fresh.uploader.username) == "string" then
              merged.author = fresh.uploader.username
            end
            merged.extra = fresh
            page.song = merged
            paint()
          end
        end
      end)
    end
  end

  play_button:onClick(function()
    if type(page.song) == "table" and type(ctx.on_play) == "function" then
      ctx.on_play(page.song)
    end
  end)

  download_button:onClick(function()
    if type(page.song) ~= "table" then
      return
    end
    if type(ctx.on_download) == "function" then
      ctx.on_download(page.song, function(message)
        draw(status_label, tostring(message or ""), "muted", "bg")
      end)
    end
  end)

  -- Nothing is drawn until show() is called, so the empty page cannot flash a
  -- placeholder title on the way in.
  return page
end

return detail
