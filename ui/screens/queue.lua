-- ui/screens/queue.lua
--
-- THE PLAY QUEUE -- the reference's right-hand drawer.
--
-- The reference slides a half-width panel in from the right edge with a dismiss
-- layer behind it, so a tap outside closes it.  This reproduces that: the drawer
-- is half the width, anchored right, and a transparent full-page layer sits
-- behind it to catch the dismiss.
--
-- ===========================================================================
-- THE QUEUE IS THE TRANSPORT'S PLAN, NOT A COPY OF IT
-- ===========================================================================
-- Copying the event list into the drawer would let the two drift: playing the
-- next track while the drawer still shows the old order is exactly the bug that
-- produces "I clicked the third song and it played the first".  So the drawer
-- renders from whatever plan the shell hands it at open time, and the shell
-- rebuilds it on open.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, bitwise operators,
-- math.maxinteger, collectgarbage, string.dump, os.exit, utf8.*.

local queue = {}

-- How many rows one screenful of the drawer shows before it scrolls.
queue.VISIBLE_ROWS = 10

-- queue.row_for(events, index) -> { t_ms, kind, label } | nil.
-- PURE.  The drawer shows one row per PLAYABLE item rather than one per event,
-- because a chord is several events at the same instant and listing each would
-- make the queue unreadable.
function queue.row_for(events, index)
  if type(events) ~= "table" then
    return nil
  end
  local event = events[index]
  if type(event) ~= "table" then
    return nil
  end
  local label = "?"
  if type(event.kind) == "string" then
    label = event.kind
  end
  return {
    t_ms = tonumber(event.t_ms) or 0,
    kind = event.kind,
    label = label,
    event = event,
  }
end

-- queue.collapse(events) -> array of rows, one per distinct timestamp.
-- PURE.  A plan's events are ordered, so a single pass suffices.
function queue.collapse(events)
  local rows = {}
  if type(events) ~= "table" then
    return rows
  end
  local last_time = nil
  for index = 1, #events do
    local row = queue.row_for(events, index)
    if row ~= nil then
      if row.t_ms ~= last_time then
        rows[#rows + 1] = row
        last_time = row.t_ms
      end
    end
  end
  return rows
end

-- queue.clamp_page(page, total) -> integer.
function queue.clamp_page(page, total)
  local per = queue.VISIBLE_ROWS
  local last = math.max(1, math.floor((math.max(0, total) - 1) / per) + 1)
  local wanted = math.floor(tonumber(page) or 1)
  if wanted < 1 then
    wanted = 1
  end
  if wanted > last then
    wanted = last
  end
  return wanted
end

-- build(ctx) -> page
--   page.open(events)   show the drawer for a plan
--   page.close()        hide it
function queue.build(ctx)
  local palette = ctx.palette or {}
  local tr = ctx.tr or function(key) return tostring(key) end
  local draw = ctx.draw or function() end
  local transport = ctx.transport
  local schedule = ctx.schedule or function(fn) fn() end

  -- The dismiss layer spans the whole page and sits UNDER the drawer, so a click
  -- anywhere outside closes it.  It is `enabled` only while the drawer is open,
  -- because an always-enabled full-page button would swallow every other click.
  local dismiss = ctx.parent:addFrame({
    x = 1, y = 6, width = "{parent.width-19}",
    height = "{parent.height-10}",
    background = palette.bg, z = 24,
  })
  local dismiss_button = dismiss:addButton({
    x = 1, y = 1, width = "{parent.width}", height = "{parent.height}",
    text = "", backgroundEnabled = false, z = 25,
  })

  local drawer = ctx.parent:addFrame({
    x = "{floor(parent.width/2+1)}", y = 6,
    width = "{floor(parent.width/2-1)}", height = "{parent.height-10}",
    background = palette.panel, z = 26,
  })

  local heading = drawer:addLabel({
    x = 2, y = 1, width = "{parent.width-4}", height = 3,
    foreground = palette.accent, background = palette.panel,
  })
  draw(heading, tr("queue.title"), "accent", "panel")

  local counter = drawer:addLabel({
    x = 2, y = 4, width = "{parent.width-4}", height = 1,
    foreground = palette.muted, background = palette.panel,
  })

  local list = drawer:addFrame({
    x = 1, y = 5, width = "{parent.width}", height = "{parent.height-10}",
    background = palette.panel,
  })

  local previous_button = drawer:addButton({
    x = 2, y = "{parent.height-4}", width = 10, height = 3,
    foreground = palette.fg, background = palette.inset,
  })
  draw(previous_button, tr("list.previous"), "fg", "inset")

  local next_button = drawer:addButton({
    x = 13, y = "{parent.height-4}", width = 10, height = 3,
    foreground = palette.fg, background = palette.inset,
  })
  draw(next_button, tr("list.next"), "fg", "inset")

  local close_button = drawer:addButton({
    x = "{parent.width-12}", y = "{parent.height-4}", width = 10, height = 3,
    foreground = palette.fg, background = palette.active,
  })
  draw(close_button, tr("queue.close"), "fg", "active")

  local state = {
    rows = {},
    page = 1,
  }

  local row_frames = {}

  local function clear_rows()
    for _, frame in ipairs(row_frames) do
      pcall(function()
        frame:setVisible(false)
      end)
    end
    row_frames = {}
  end

  local function paint()
    clear_rows()

    local total = #state.rows
    state.page = queue.clamp_page(state.page, total)
    local per = queue.VISIBLE_ROWS
    local first = (state.page - 1) * per + 1
    local pages = math.max(1, math.floor((total - 1) / per) + 1)

    draw(counter, tr("queue.count",
      { total = total, page = state.page, pages = pages }), "muted", "panel")

    for offset = 0, per - 1 do
      local row = state.rows[first + offset]
      if row == nil then
        break
      end
      local y = 1 + offset * 2
      local holder = list:addFrame({
        x = 1, y = y, width = "{parent.width-1}", height = 2,
        background = palette.inset,
      })
      local label = holder:addLabel({
        x = 2, y = 1, width = "{parent.width-3}", height = 1,
        foreground = palette.fg, background = palette.inset,
      })
      -- A timestamp and the KIND, which is the only label a note-block event
      -- has; there is no per-event title in the format.
      draw(label, string.format("%d ms  %s", row.t_ms, tostring(row.label)),
        "fg", "inset")

      local activate = holder:addButton({
        x = 1, y = 1, width = "{parent.width-1}", height = 2,
        text = "", backgroundEnabled = false, z = 27,
      })
      local target_ms = row.t_ms
      activate:onClick(function()
        if type(transport) ~= "table" or type(transport.seek) ~= "function" then
          return
        end
        local duration = 0
        if type(transport.duration_ms) == "function" then
          local ok, value = pcall(transport.duration_ms)
          if ok and type(value) == "number" then
            duration = value
          end
        end
        if duration > 0 then
          pcall(transport.seek, target_ms / duration)
        end
        page.close()
      end)

      row_frames[#row_frames + 1] = holder
    end

    pcall(function()
      previous_button:setEnabled(state.page > 1)
      next_button:setEnabled(state.page < pages)
    end)
  end

  local page = {
    frame = drawer,
    state = state,
  }

  function page.open(events)
    state.rows = queue.collapse(events)
    state.page = 1
    dismiss:setVisible(true)
    pcall(function()
      dismiss_button:setEnabled(true)
    end)
    drawer:setVisible(true)
    paint()
  end

  function page.close()
    drawer:setVisible(false)
    dismiss:setVisible(false)
    pcall(function()
      dismiss_button:setEnabled(false)
    end)
  end

  dismiss_button:onClick(function()
    page.close()
  end)
  close_button:onClick(function()
    page.close()
  end)

  previous_button:onClick(function()
    if state.page > 1 then
      state.page = state.page - 1
      paint()
    end
  end)
  next_button:onClick(function()
    local pages = math.max(1,
      math.floor((#state.rows - 1) / queue.VISIBLE_ROWS) + 1)
    if state.page < pages then
      state.page = state.page + 1
      paint()
    end
  end)

  page.close()
  return page
end

return queue
