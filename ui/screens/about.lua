-- ui/screens/about.lua
--
-- THE ABOUT PAGE -- version, what this program is, and where its licences stand.
--
-- It exists because the reference has a user page in the top bar and we have no
-- accounts, so that slot becomes something true instead of a login that cannot
-- happen.  It also carries the third-party attribution a user can read without
-- leaving the program, which matters because NBW hands us loadable font code at
-- run time and we ship a MIT-licensed UI framework.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local about = {}

-- The attribution lines, as data, so the About page and the README cannot
-- disagree about who is credited.
about.CREDITS = {
  { key = "about.credit_basalt" },
  { key = "about.credit_utf8" },
  { key = "about.credit_font" },
  { key = "about.credit_nbw" },
  { key = "about.credit_keyboard" },
  { key = "about.credit_icons" },
}

-- about.version_text(version) -> a string, tolerating a nil version so a broken
-- build still renders something rather than "nil".
function about.version_text(version)
  if type(version) ~= "string" or version == "" then
    return "?"
  end
  return version
end

-- build(ctx) -> page
function about.build(ctx)
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end

  local page_frame = ctx.parent:addFrame({
    x = 19, y = 6, width = "{parent.width-19}", height = "{parent.height-10}",
    background = palette.bg,
  })

  local heading = page_frame:addLabel({
    x = 1, y = 1, width = "{parent.width-2}", height = 3,
    foreground = palette.accent, background = palette.bg,
  })
  draw(heading, tr("about.title"), "accent", "bg")

  local version = page_frame:addLabel({
    x = 1, y = 4, width = "{parent.width-2}", height = 1,
    foreground = palette.fg, background = palette.bg,
  })
  draw(version, tr("about.version", { version = about.version_text(ctx.version) }),
    "fg", "bg")

  local scroll = page_frame:addScrollFrame({
    x = 1, y = 6, width = "{parent.width-2}", height = "{parent.height-7}",
    background = palette.bg,
    scrollBarColor = palette.accent,
    scrollBarBackgroundColor = palette.panel,
    scrollBarBackgroundColor2 = palette.panel,
  })

  local y = 1
  local function paragraph(key, colour, height)
    local label = scroll:addLabel({
      x = 1, y = y, width = "{parent.width-2}", height = height or 3,
      foreground = colour or palette.fg, background = palette.bg,
    })
    draw(label, tr(key), colour and "muted" or "fg", "bg")
    y = y + (height or 3)
  end

  paragraph("about.purpose")
  paragraph("about.not_official", "muted")
  paragraph("about.licence")

  local credits_heading = scroll:addLabel({
    x = 1, y = y, width = "{parent.width-2}", height = 2,
    foreground = palette.accent, background = palette.bg,
  })
  draw(credits_heading, tr("about.credits"), "accent", "bg")
  y = y + 2

  for _, credit in ipairs(about.CREDITS) do
    paragraph(credit.key, "muted", 2)
  end

  return {
    frame = page_frame,
  }
end

return about
