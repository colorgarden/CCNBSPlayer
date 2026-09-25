-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSPlayer. Licensed under GPL-2.0; see LICENSE.
--
-- ui/basalt_app.lua
--
-- THE BASALT 2 VIEW -- the framework screen that REPLACED player/tui.lua.
--
-- ===========================================================================
-- WHY THIS FILE CONTAINS (almost) NO DISPLAY LOGIC
-- ===========================================================================
-- Basalt 2 has NO headless mode, no mock terminal and no test helpers: run()
-- blocks in its own os.pullEventRaw loop and is unusable in a unit test.  The
-- displayed behaviour was therefore moved into ui/presenter.lua (pure, already
-- tested) and THIS module is the thin integration view that renders what the
-- presenter returns.  If you are about to format a string, compute a
-- percentage or pick a label here, call the presenter instead.  This file
-- wires; it does not think.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local app = require("ui.basalt_app")
--   app.run(opts) -> { exit_code = <integer> }
--
-- `opts` -- every dependency is injectable so the wiring is inspectable:
--   opts.basalt     the basalt table   (default require("vendor.basalt"))
--   opts.cjk        the cjk module     (default require("ui.cjk"))
--   opts.presenter  the presenter      (default require("ui.presenter"))
--   opts.i18n       the i18n module    (default require("ui.i18n"))
--   opts.ccnbs      the library        (default require("ccnbs"))
--   opts.files      array of .nbs paths (default: scan the working directory)
--   opts.read_file  function(path) -> bytes | nil
--   opts.speakers   speaker records    (default ccnbs.discover_speakers())
--
-- ===========================================================================
-- THE FIVE HARD BASALT CONSTRAINTS THIS FILE OBEYS
-- ===========================================================================
-- 1. The full bundle is VENDORED at vendor/basalt.lua and is loaded with the
--    literal require("vendor.basalt").  It touches `fs` at load time, so the
--    require happens INSIDE app.run, never at module load: this module must
--    stay require-able (and loadable by `loadfile`) in plain desktop Lua so
--    lint/installer tooling can read it.
-- 2. basalt.run() BLOCKS until basalt.stop().  Playback therefore lives in ONE
--    basalt.schedule(function() ... end) coroutine, which Basalt resumes from
--    its own event loop; that coroutine is the only place that may sleep().
-- 3. Transport hotkeys use the GLOBAL hook basalt.onEvent("key", ...), never an
--    element :onKey, because :onKey only fires for the focused child.
-- 4. Basalt cannot render Chinese (its text goes through term.blit with CC's
--    font).  Chinese is routed through an Image element via cjk.to_bimg, which
--    is PURE and returns nil (never raises) when no font is loaded; a nil falls
--    back to a plain ASCII Label.  NEVER pass nil to setBimg.
-- 5. basalt.update(event, ...) is the one-event seam (used by tests of Basalt
--    itself); production calls run().
--
-- ===========================================================================
-- PLAYBACK: A COOPERATIVE CLOCK DRIVEN BY THE SCHEDULED COROUTINE
-- ===========================================================================
-- ccnbs.play() schedules notes on an injected CLOCK SEAM (player/clock.lua's
-- protocol: now_ms() / after(delay_sec, fn) / cancel(handle)).  player/clock's
-- os adapter expects a caller to drain os timers with os.pullEvent, which does
-- not compose with Basalt's own raw event loop.  So this module supplies a
-- small COOPERATIVE adapter instead: after() only records the deadline, and the
-- scheduled coroutine repeatedly steps it, sleeping() until the deadline of the
-- single pending note, then firing it.  tempo.lua keeps exactly one pending
-- handle and re-schedules itself from the ideal timeline, so this is enough.
--
-- Pausing freezes MUSICAL time, not the wall clock: the clock's now_ms() stops
-- advancing and step() refuses to fire while paused, so no note sounds and the
-- timeline resumes exactly where it stopped.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no utf8.*, no math.maxinteger, no collectgarbage, no string.dump, no os.exit.

local app = {}

-- The application name shown in the header.  A stable literal, not prose that
-- could belong to a language table (it is a product name, not a sentence).
app.NAME = "CCNBSPlayer"

-- Fallback pixel-font height when the live probe cannot report one.  The font
-- is 8px tall; the probe below measures the real value after a successful
-- cjk.setup and overrides this.
local FALLBACK_LINE_H = 8

-- ---------------------------------------------------------------------------
-- Lazy global access (never at module load: this file must load in plain Lua)
-- ---------------------------------------------------------------------------

local function read_global(name)
  local ok, value = pcall(function()
    return _G[name]
  end)
  if ok then
    return value
  end
  return nil
end

-- default_now_ms(): the game clock in integer milliseconds.  Read lazily so the
-- module still loads where os.epoch does not exist.
local function default_now_ms()
  local oslib = read_global("os")
  if type(oslib) == "table" and type(oslib.epoch) == "function" then
    local ok, value = pcall(oslib.epoch, "ingame")
    if ok and type(value) == "number" then
      return value
    end
  end
  return 0
end

-- default_sleep(seconds): CC's cooperative sleep.  NOT wrapped in pcall: sleep
-- yields, and the yield must reach Basalt's scheduler unchanged.  A missing
-- global simply means "do not wait", which keeps the loop alive.
local function default_sleep(seconds)
  local sleeper = rawget(_G, "sleep")
  if type(sleeper) == "function" then
    sleeper(seconds)
  end
end

-- default_scan(): every *.nbs in the working directory, sorted.  The CC `fs`
-- module is preferred; a desktop shell listing is the fallback.
local function default_scan()
  local names = {}

  local fsmod = read_global("fs")
  if type(fsmod) == "table" and type(fsmod.list) == "function" then
    local ok, listing = pcall(fsmod.list, "")
    if ok and type(listing) == "table" then
      for index = 1, #listing do
        local name = listing[index]
        if type(name) == "string" and name:sub(-4):lower() == ".nbs" then
          names[#names + 1] = name
        end
      end
    end
  else
    local separator = "\\"
    if type(package) == "table" and type(package.config) == "string" then
      separator = package.config:sub(1, 1)
    end
    local command = (separator == "\\")
      and "dir /b *.nbs 2>nul"
      or "ls -1 *.nbs 2>/dev/null"
    local pipe = io.popen(command)
    if pipe ~= nil then
      for listed in pipe:lines() do
        names[#names + 1] = listed
      end
      pipe:close()
    end
  end

  table.sort(names)
  return names
end

-- default_read_file(path) -> bytes | nil.  io.open first (desktop), then the
-- CC `fs` handle API.
local function default_read_file(path)
  local handle = io.open(path, "rb")
  if handle ~= nil then
    local data = handle:read("*a") or ""
    handle:close()
    return data
  end

  local fsmod = read_global("fs")
  if type(fsmod) == "table" and type(fsmod.open) == "function" then
    local ok, opened = pcall(fsmod.open, path, "rb")
    if ok and opened ~= nil then
      local data = ""
      if type(opened.readAll) == "function" then
        data = opened.readAll() or ""
      end
      if type(opened.close) == "function" then
        opened.close()
      end
      return data
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- The cooperative clock (the injected ccnbs/player.clock seam)
-- ---------------------------------------------------------------------------
-- now_ms() is musical time: wall time minus every paused span, frozen while
-- paused.  after() records one deadline; step() is called by the scheduled
-- coroutine, sleeps until that deadline and fires it.  cancel() retires it.
local function make_clock()
  local clock = { errors = {} }

  local pending = nil
  local paused = false
  local paused_total = 0
  local frozen_now = 0

  function clock.now_ms()
    if paused then
      return frozen_now
    end
    return default_now_ms() - paused_total
  end

  function clock.after(delay_sec, fn)
    local item = {
      deadline = clock.now_ms() + delay_sec * 1000,
      fn = fn,
      cancelled = false,
      fired = false,
    }
    pending = item
    return item
  end

  function clock.cancel(item)
    if item == nil or item.cancelled == true or item.fired == true then
      return false
    end
    item.cancelled = true
    if pending == item then
      pending = nil
    end
    return true
  end

  function clock.pause()
    if paused then
      return false
    end
    paused = true
    frozen_now = default_now_ms() - paused_total
    return true
  end

  function clock.resume()
    if not paused then
      return false
    end
    paused_total = default_now_ms() - frozen_now
    paused = false
    return true
  end

  function clock.is_paused()
    return paused
  end

  -- step() -> true when there is still work (a pending or a paused note),
  -- false when the plan is exhausted.  It never raises: a note callback's
  -- error is captured in clock.errors so one bad event cannot wedge the loop.
  function clock.step()
    local item = pending
    if item == nil then
      return false
    end
    if paused then
      return true
    end

    -- Sleep until the deadline, RE-COMPUTING after every wake-up: a pause that
    -- arrives mid-sleep froze now_ms(), and a resume moved it forward again, so
    -- the remaining wait must be measured against the current musical clock.
    while paused == false and item.cancelled == false do
      local remaining = (item.deadline - clock.now_ms()) / 1000
      if remaining <= 0 then
        break
      end
      default_sleep(remaining)
    end

    -- Re-check AFTER the wait: a pause may have arrived while we slept.
    if paused then
      return true
    end
    if item.cancelled == true then
      return true
    end

    if pending == item then
      pending = nil
    end
    item.fired = true
    if type(item.fn) == "function" then
      local ok, err = pcall(item.fn)
      if not ok then
        clock.errors[#clock.errors + 1] = tostring(err)
      end
    end
    return true
  end

  return clock
end

-- ---------------------------------------------------------------------------
-- Small total helpers (no presentation decisions live here)
-- ---------------------------------------------------------------------------

-- max_t_ms(plan) -> the last event's time, i.e. the song duration estimate.
local function max_t_ms(plan)
  local maximum = 0
  if type(plan) ~= "table" then
    return maximum
  end
  for index = 1, #plan do
    local event = plan[index]
    if type(event) == "table" and type(event.t_ms) == "number"
      and event.t_ms > maximum then
      maximum = event.t_ms
    end
  end
  return maximum
end

-- wrap_index(index, count) -> index within 1..count (1 when there are none).
local function wrap_index(index, count)
  if count <= 0 then
    return 1
  end
  while index < 1 do
    index = index + count
  end
  while index > count do
    index = index - count
  end
  return index
end

-- ---------------------------------------------------------------------------
-- The CJK-aware text slot
-- ---------------------------------------------------------------------------
-- One rectangle on screen that shows either a Basalt Image (a bimg built by
-- cjk.to_bimg) or a plain Label.  When no font is available -- or to_bimg
-- returns nil -- the Label shows the text as-is, so Chinese simply degrades to
-- the stock terminal's bytes instead of taking the program down.
local function make_slot(parent, x, y, width, height, fg, bg, cjk, cjk_ok)
  local slot = { x = x, y = y, width = width, height = height }

  slot.label = parent:addLabel({
    x = x,
    y = y,
    width = width,
    height = height,
    autoSize = false,
    text = "",
    foreground = fg,
    background = bg,
    backgroundEnabled = false,
    visible = false,
  })

  slot.image = parent:addImage({
    x = x,
    y = y,
    width = width,
    height = height,
    background = bg,
    visible = false,
  })

  slot.set = function(text)
    local value = text
    if value == nil then
      value = ""
    end

    if not cjk_ok then
      slot.label:setText(value)
      slot.label:setVisible(true)
      slot.image:setVisible(false)
      return
    end

    local bimg = cjk.to_bimg(value, fg, bg)
    if type(bimg) == "table" then
      slot.image:setBimg(bimg)
      slot.image:setPosition(x, y)
      slot.image:setSize(width, height)
      slot.image:setVisible(true)
      slot.label:setVisible(false)
    else
      slot.label:setText(value)
      slot.label:setVisible(true)
      slot.image:setVisible(false)
    end
  end

  return slot
end

-- set_lines(slots, lines): distribute an array of presenter lines over the
-- pre-created line slots.  Extra lines are dropped (the panel is full).
local function set_lines(slots, lines)
  local source = lines
  if type(source) ~= "table" then
    source = {}
  end
  for index = 1, #slots do
    local text = source[index]
    if text == nil then
      text = ""
    end
    slots[index].set(text)
  end
end

-- ---------------------------------------------------------------------------
-- app.run(opts)
-- ---------------------------------------------------------------------------

function app.run(opts)
  if type(opts) ~= "table" then
    opts = {}
  end

  -- Literal requires on purpose: the installer's manifest drift guard scans the
  -- source for `require("...")` to prove a fresh install ships every module the
  -- runtime needs.  Hiding a default behind a variable would hide a dependency.
  local basalt = opts.basalt
  if basalt == nil then
    basalt = require("vendor.basalt")
  end
  local cjk = opts.cjk
  if cjk == nil then
    cjk = require("ui.cjk")
  end
  local presenter = opts.presenter
  if presenter == nil then
    presenter = require("ui.presenter")
  end
  local i18n = opts.i18n
  if i18n == nil then
    i18n = require("ui.i18n")
  end
  local ccnbs = opts.ccnbs
  if ccnbs == nil then
    ccnbs = require("ccnbs")
  end

  -- The stopped-speaker helper is a SOFT dependency: the runtime module exists
  -- in the checkout, but a lean install must still start.  The literal
  -- pcall(require, ...) is visible to the installer scanner.
  local stop_speakers = nil
  local runtime_ok, runtime_module = pcall(require, "player.runtime")
  if runtime_ok and type(runtime_module) == "table"
    and type(runtime_module.stop_speakers) == "function" then
    stop_speakers = runtime_module.stop_speakers
  end

  local colors_table = read_global("colors") or {}
  local FG = colors_table.white or 1
  local BG = colors_table.black or 32768

  -- ---------------------------------------------------------------- inputs --
  local files = opts.files
  if files == nil then
    files = default_scan()
  end
  if type(files) ~= "table" then
    files = {}
  end

  local read_file = opts.read_file
  if type(read_file) ~= "function" then
    read_file = default_read_file
  end

  local speakers = opts.speakers
  if speakers == nil then
    speakers = ccnbs.discover_speakers()
  end
  if type(speakers) ~= "table" then
    speakers = {}
  end
  local speakers_found = #speakers

  -- --------------------------------------------------------- CJK, one probe --
  -- Attempt the pixel font ONCE.  Chinese is an upgrade, never a requirement:
  -- a failed setup leaves cjk_ok false and every slot renders as a Label.
  local cjk_ok = false
  local line_h = 1
  if type(cjk.setup) == "function" then
    local setup_result = cjk.setup({ size = cjk.DEFAULT_SIZE })
    if type(setup_result) == "table" and setup_result.ok == true then
      local probe = cjk.to_bimg("中", FG, BG)
      if type(probe) == "table" and type(probe[1]) == "table"
        and #probe[1] > 0 then
        cjk_ok = true
        line_h = #probe[1]
      end
    end
  end
  if type(line_h) ~= "number" or line_h < 1 then
    line_h = FALLBACK_LINE_H
  end

  -- ------------------------------------------------------------- geometry --
  -- A 51x19 CC:T terminal.  Each text slot is line_h rows tall, so the SAME
  -- layout fits eight ASCII lines or one Chinese line per panel.
  local HEADER_Y = 1
  local MAIN_Y = 2
  local MAIN_H = 8
  local LIST_X = 1
  local LIST_W = 24
  local DETAIL_X = 25
  local DETAIL_W = 27
  local MSG_Y = 10
  local MSG_H = 8
  local MSG_W = 51
  local PROGRESS_Y = 18
  local PROGRESS_W = 51
  local BUTTONS_Y = 19

  local detail_count = math.floor(MAIN_H / line_h)
  if detail_count < 1 then
    detail_count = 1
  end
  local msg_count = math.floor(MSG_H / line_h)
  if msg_count < 1 then
    msg_count = 1
  end

  -- -------------------------------------------------------------- the frame --
  local frame = basalt.createFrame()
  frame:setBackground(BG)
  frame:setForeground(FG)

  local header_name = frame:addLabel({
    x = 1,
    y = HEADER_Y,
    width = 30,
    height = 1,
    autoSize = false,
    text = app.NAME,
    foreground = FG,
    background = BG,
    backgroundEnabled = false,
  })

  local header_lang = frame:addLabel({
    x = 40,
    y = HEADER_Y,
    width = 11,
    height = 1,
    autoSize = false,
    text = "",
    foreground = colors_table.lightGray or FG,
    background = BG,
    backgroundEnabled = false,
  })

  -- The song list.  A native Basalt List is ASCII-only: it cannot render
  -- Chinese, so its rows stay as the presenter's item text.
  local list = frame:addList({
    x = LIST_X,
    y = MAIN_Y,
    width = LIST_W,
    height = MAIN_H,
    emptyText = "No .nbs files here",
    background = BG,
    foreground = FG,
    selectedBackground = colors_table.blue or FG,
    selectedForeground = colors_table.white or FG,
  })

  -- The licence obligation lives in the FIRST detail slot so it stays visible
  -- even when the CJK layout shows only one line.
  local detail_slots = {}
  for index = 1, detail_count do
    detail_slots[index] = make_slot(frame, DETAIL_X,
      MAIN_Y + (index - 1) * line_h, DETAIL_W, line_h, FG, BG, cjk, cjk_ok)
  end

  local msg_slots = {}
  for index = 1, msg_count do
    msg_slots[index] = make_slot(frame, 1,
      MSG_Y + (index - 1) * line_h, MSG_W, line_h, FG, BG, cjk, cjk_ok)
  end

  local progress = frame:addProgressBar({
    x = 1,
    y = PROGRESS_Y,
    width = PROGRESS_W,
    height = 1,
    background = BG,
    foreground = FG,
    direction = "right",
  })

  local button_fg = colors_table.white or FG
  local button_bg = colors_table.gray or BG
  local function make_button(x, width, text)
    return frame:addButton({
      x = x,
      y = BUTTONS_Y,
      width = width,
      height = 1,
      text = text,
      foreground = button_fg,
      background = button_bg,
    })
  end

  local play_button = make_button(1, 8, "Play")
  local stop_button = make_button(10, 7, "Stop")
  local previous_button = make_button(18, 6, "Prev")
  local next_button = make_button(25, 6, "Next")
  local quit_button = make_button(32, 6, "Quit")

  -- --------------------------------------------------------------- state ----
  local state = {
    status = "stopped",
    position = 0,
    duration = 0,
    song = nil,
    analysis = nil,
    plan = nil,
    session = nil,
    clock = nil,
    cursor = 1,
    detail_lines = {},
    gen = 0,
  }

  local items = presenter.local_song_items(files)
  list:setItems(items)
  if #items > 0 then
    list:selectItem(1)
  end

  -- ------------------------------------------------------------ rendering ---
  local function build_detail(song)
    local lines = {}
    -- The attribution line is a LICENCE OBLIGATION, so it is displayed first
    -- and always -- independent of how many lines the panel can show.
    lines[#lines + 1] = presenter.attribution_line(song)
    local detail = presenter.song_detail(song)
    for index = 1, #detail do
      lines[#lines + 1] = detail[index]
    end
    return lines
  end

  -- `refresh`, `load_path` and `select_index` are forward-declared because the
  -- transport toggle defined between them may call them.
  local refresh
  local load_path
  local select_index

  -- ------------------------------------------------------------ playback ----
  local function stop_playback()
    state.gen = state.gen + 1
    if state.session ~= nil then
      pcall(function()
        state.session.cancel()
      end)
    end
    state.session = nil
    if stop_speakers ~= nil then
      pcall(stop_speakers, speakers)
    end
    state.status = "stopped"
    state.position = 0
    refresh()
  end

  local function start_playback()
    if state.song == nil or state.analysis == nil or state.plan == nil then
      return
    end

    stop_playback()

    local gen = state.gen
    local clock = make_clock()
    state.clock = clock
    state.position = 0
    state.status = "playing"

    -- Pass the already-computed PLAN (and its analysis) so the library is not
    -- asked to re-analyze or re-plan; ccnbs.play uses a plan VERBATIM.
    state.session = ccnbs.play(state.plan, {
      analysis = state.analysis,
      speakers = speakers,
      clock = clock,
      on_warning = function()
        refresh()
      end,
      on_progress = function(info)
        if type(info) == "table" then
          if type(info.t_ms) == "number" then
            state.position = info.t_ms
          end
        end
        refresh()
      end,
    })

    refresh()

    -- The ONLY place playback may block: Basalt resumes this coroutine from
    -- its own event loop, and step() sleeps between notes here.
    basalt.schedule(function()
      while state.gen == gen do
        if state.status == "paused" then
          default_sleep(0.05)
        else
          local more = clock.step()
          local session = state.session
          if not more or session == nil or not session.is_playing() then
            if state.gen == gen then
              state.status = "stopped"
              state.position = state.duration
              refresh()
            end
            break
          end
        end
      end
    end)
  end

  local function toggle_transport()
    if state.song == nil then
      -- Nothing loaded yet: load the highlighted row, then fall through so a
      -- single press both selects and starts the song.
      select_index(state.cursor or 1)
    end
    if state.song == nil then
      return
    end

    if state.status == "playing" then
      state.status = "paused"
      if state.clock ~= nil then
        state.clock.pause()
      end
      refresh()
    elseif state.status == "paused" then
      state.status = "playing"
      if state.clock ~= nil then
        state.clock.resume()
      end
      refresh()
    else
      start_playback()
    end
  end

  -- --------------------------------------------------------------- loading --
  load_path = function(path)
    local bytes = read_file(path)
    if bytes == nil then
      bytes = ""
    end

    local decoded = ccnbs.decode(bytes)

    state.song = nil
    state.analysis = nil
    state.plan = nil
    state.duration = 0
    state.position = 0
    state.status = "stopped"

    if type(decoded) == "table" and decoded.ok == true
      and type(decoded.song) == "table" then
      local song = decoded.song
      state.song = song
      state.analysis = ccnbs.analyze(song)
      state.plan = ccnbs.plan(song, state.analysis)
      state.duration = max_t_ms(state.plan)
      state.detail_lines = build_detail(song)
    else
      local code = "unknown"
      if type(decoded) == "table" and type(decoded.error) == "table"
        and decoded.error.code ~= nil then
        code = tostring(decoded.error.code)
      end
      state.detail_lines = { "Decode failed: " .. code }
    end

    refresh()
  end

  select_index = function(index)
    if #items == 0 then
      return
    end
    state.cursor = wrap_index(index, #items)
    list:clearItemSelection()
    list:selectItem(state.cursor)
    local item = items[state.cursor]
    if item ~= nil and type(item.ref) == "string" then
      load_path(item.ref)
    end
  end

  local function move_selection(delta)
    select_index((state.cursor or 1) + delta)
  end

  -- ------------------------------------------------------------- language ---
  local function toggle_language()
    local codes = i18n.languages()
    if type(codes) == "table" and #codes > 0 then
      local active = i18n.get_language()
      for index = 1, #codes do
        if codes[index] ~= active then
          i18n.set_language(codes[index])
          break
        end
      end
    end

    items = presenter.local_song_items(files)
    list:setItems(items)
    if #items > 0 then
      list:clearItemSelection()
      state.cursor = wrap_index(state.cursor or 1, #items)
      list:selectItem(state.cursor)
    end
    if state.song ~= nil then
      state.detail_lines = build_detail(state.song)
    end
    refresh()
  end

  -- ------------------------------------------------------------- refresh ----
  refresh = function()
    local view = {
      status = state.status,
      position = state.position,
      duration = state.duration,
      song = state.song,
    }

    header_lang:setText("[" .. i18n.get_language() .. "]")

    if state.status == "playing" then
      play_button:setText("Pause")
    else
      play_button:setText("Play")
    end

    local message = {}
    message[#message + 1] = presenter.transport_status(view)

    if state.analysis ~= nil then
      if state.status == "playing" or state.status == "paused" then
        -- The single "what the user needs to know" call, warnings included.
        local playback = presenter.playback_lines(view, state.analysis,
          speakers_found)
        for index = 1, #playback do
          message[#message + 1] = playback[index]
        end
      else
        -- Load-time preview: the analysis-derived warning set.
        local warnings = presenter.warning_lines(state.analysis, speakers_found)
        for index = 1, #warnings do
          message[#message + 1] = warnings[index]
        end
      end
    end

    message[#message + 1] = presenter.language_toggle_label()
    message[#message + 1] = presenter.transport_help()

    set_lines(msg_slots, message)
    set_lines(detail_slots, state.detail_lines)
    progress:setProgress(presenter.progress_percent(state.position,
      state.duration))
  end

  -- ---------------------------------------------------------------- quit ----
  local function quit()
    state.gen = state.gen + 1
    if state.session ~= nil then
      pcall(function()
        state.session.cancel()
      end)
    end
    if stop_speakers ~= nil then
      pcall(stop_speakers, speakers)
    end
    basalt.stop()
  end

  -- --------------------------------------------------------- interactions ---
  list:onSelect(function(_, index, item)
    if type(index) == "number" then
      state.cursor = index
    end
    if type(item) == "table" and type(item.ref) == "string" then
      load_path(item.ref)
    end
  end)

  play_button:onClick(function()
    toggle_transport()
  end)
  stop_button:onClick(function()
    stop_playback()
  end)
  previous_button:onClick(function()
    move_selection(-1)
  end)
  next_button:onClick(function()
    move_selection(1)
  end)
  quit_button:onClick(function()
    quit()
  end)

  -- One global key hook for every shortcut (see constraint 3).
  basalt.setFocus(list)
  basalt.onEvent("key", function(key)
    local keymap = read_global("keys")
    if type(keymap) ~= "table" then
      return
    end

    if key == keymap.escape then
      quit()
    elseif key == keymap.up or key == keymap.left then
      move_selection(-1)
    elseif key == keymap.down or key == keymap.right then
      move_selection(1)
    elseif key == keymap.enter then
      select_index(state.cursor or 1)
    elseif key == keymap.space or key == keymap.p then
      toggle_transport()
    elseif key == keymap.s or key == keymap.q then
      stop_playback()
    elseif key == keymap.l then
      toggle_language()
    end
  end)

  -- ----------------------------------------------------------- first paint --
  refresh()

  basalt.run()

  return { exit_code = 0 }
end

return app
