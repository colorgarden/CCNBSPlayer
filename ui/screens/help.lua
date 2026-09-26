-- ui/screens/help.lua
--
-- THE HELP PAGE -- hotkeys, the monitor requirement, and the risk disclosure.
--
-- The reference's counterpart slot in the sidebar is a podcast page, which has
-- no meaning here.  Rather than leave a dead button, the slot carries what a
-- user of THIS program actually needs:
--
--   * the keys, because several are global and none are discoverable;
--   * the monitor requirement, because without one the program shows nothing;
--   * the REMOTE KEYBOARD RISK.  This one is not optional.  The wireless
--     keyboard installs unconditionally and starts at boot, and its server
--     injects any rednet message whose protocol matches straight into the local
--     event queue -- so anyone on the same rednet can type into this computer.
--     The user accepted that trade deliberately, but a user who did not make
--     that choice deserves to be told, in the program, not only in a README.
--   * the Note Block World attribution, which is part of using its API.
--
-- ===========================================================================
-- WHY THE RISK IS STATED HERE RATHER THAN BURIED IN DOCS
-- ===========================================================================
-- A README is read once, before installation.  The condition that makes the risk
-- matter -- this computer is on a rednet with other people -- happens long after
-- and is not something the user will remember to go looking for.  The disclosure
-- therefore lives in the program, where the user is when the question occurs.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local help = {}

-- The keys, in the order a user is likely to need them.  Kept as data so the
-- reference in the README and the list drawn here can be checked against one
-- another rather than drifting.
help.KEYS = {
  { key = "help.key_up_down",   action = "help.act_select" },
  { key = "help.key_enter",     action = "help.act_play" },
  { key = "help.key_space",     action = "help.act_pause" },
  { key = "help.key_s",         action = "help.act_stop" },
  { key = "help.key_arrows",    action = "help.act_seek" },
  { key = "help.key_escape",    action = "help.act_quit" },
}

-- Which keys are GLOBAL, i.e. work no matter what has focus.  Spelled out
-- because a user pressing space in a search box and seeing playback pause is the
-- kind of surprise that reads as a bug.
help.GLOBAL_KEYS = "help.global_note"

-- build(ctx) -> page
function help.build(ctx)
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
  draw(heading, tr("help.title"), "accent", "bg")

  local scroll = page_frame:addScrollFrame({
    x = 1, y = 4, width = "{parent.width-2}", height = "{parent.height-5}",
    background = palette.bg,
    scrollBarColor = palette.accent,
    scrollBarBackgroundColor = palette.panel,
    scrollBarBackgroundColor2 = palette.panel,
  })

  local y = 1

  -- A section heading helper, so every block is spaced identically.
  local function section(key, colour)
    local label = scroll:addLabel({
      x = 1, y = y, width = "{parent.width-2}", height = 2,
      foreground = colour or palette.accent, background = palette.bg,
    })
    draw(label, tr(key), colour and "fg" or "accent", "bg")
    y = y + 2
  end

  -- A wrapped paragraph.  Two rows tall and full width, which is what the text
  -- below needs; Basalt does not wrap for us.
  local function paragraph(key, colour)
    local label = scroll:addLabel({
      x = 1, y = y, width = "{parent.width-2}", height = 3,
      foreground = colour or palette.fg, background = palette.bg,
    })
    draw(label, tr(key), colour and "muted" or "fg", "bg")
    y = y + 3
  end

  section("help.section_keys")
  for _, entry in ipairs(help.KEYS) do
    local label = scroll:addLabel({
      x = 2, y = y, width = "{parent.width-3}", height = 1,
      foreground = palette.fg, background = palette.bg,
    })
    local line = tr(entry.key) .. "  -  " .. tr(entry.action)
    draw(label, line, "fg", "bg")
    y = y + 1
  end
  y = y + 1
  paragraph(help.GLOBAL_KEYS, "muted")

  section("help.section_monitor")
  paragraph("help.monitor_body")

  section("help.section_keyboard", palette.active)
  paragraph("help.keyboard_body")
  paragraph("help.keyboard_advice", "muted")

  section("help.section_nbw")
  paragraph("help.nbw_body")
  paragraph("help.nbw_licence", "muted")

  section("help.section_font")
  paragraph("help.font_body")

  return {
    frame = page_frame,
  }
end

return help
