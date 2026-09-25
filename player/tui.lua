-- player/tui.lua
--
-- THE INTERACTIVE TERMINAL PLAYER.
--
-- This module owns the user-facing layer on top of the ccnbs library: it lists
-- the songs on disk, reads a selection, prints the load-time analysis and its
-- warnings, and then drives transport (播放 / 暂停 / 停止) while the notes fire.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local tui = require("player.tui")
--   tui.run(opts) -> { exit_code = <integer>, played = <string|nil>,
--                      stopped = <boolean> }
--
-- `opts` -- every seam is injectable so the UI is testable without a terminal
-- and without a computer:
--   opts.files       array of .nbs paths/names        (default: scan cwd)
--   opts.read_file   function(path) -> bytes          (default: filesystem)
--   opts.speakers    speaker records                  (default: discover)
--   opts.clock       a clock                           (default: new_os)
--   opts.pull        function() -> event...           (default: pullEventRaw)
--   opts.write       function(text)                   (default: term/print)
--   opts.redraw      function(state)                  (optional refresh hook)
--   opts.quiet       suppress warning output
--   opts.max_events  safety bound for the event loop (tests set this)
--
-- ===========================================================================
-- WHY THE EVENT SOURCE IS ALWAYS INJECTED (never os.pullEvent here)
-- ===========================================================================
-- This module never calls os.pullEvent or os.pullEventRaw itself.  It receives
-- its event source from player/runtime.lua, which resolves opts.pull when the
-- caller supplied one and otherwise reads the global os.pullEventRaw LAZILY.
-- os.pullEvent AUTO-TERMINATES the program on Ctrl+T, so it is never used; the
-- whole run also executes inside runtime.run, which stops every owned speaker
-- and cancels the session before unwinding.
--
-- ===========================================================================
-- WHY THE UI AND THE PLAYBACK RUN IN PARALLEL
-- ===========================================================================
-- Playback is scheduled on a clock (player/tempo.lua).  Waiting for that clock
-- must not block the key loop, and reading keys must not stall note firing, so
-- the two run together under parallel.waitForAny -- exactly as the plan
-- requires.  CC:T ships `parallel`; plain desktop Lua does not, so this module
-- resolves it defensively and falls back to a small cooperative scheduler with
-- identical "return when any function returns" semantics.  Neither path
-- busy-waits: every loop yields after doing work.
--
-- TRANSPORT KEYS
--   space / p          pause / resume
--   s / q              stop
--   left / right a / d deliberately do NOTHING -- this version has no
--                      position jumping; see the project's non-goals.
--
-- ===========================================================================
-- PAUSE / RESUME IS IMPLEMENTED THROUGH THE CLOCK SEAM
-- ===========================================================================
-- Pausing must freeze musical time, not block the UI.  ccnbs schedules through
-- the clock it is given, so this module wraps the injected clock in a GATED
-- clock: while paused its now_ms() is frozen and its pending callbacks are
-- cancelled; on resume the remaining delays are re-armed against the same
-- frozen timeline.  Note timings therefore pick up EXACTLY where they left off,
-- the session is never restarted, and no event fires while paused.
--
-- ===========================================================================
-- SOFT DEPENDENCY ON player/warnings.lua
-- ===========================================================================
-- The renderer that turns a bare warning code into a stable `WARN[code]` line
-- is loaded with pcall(require, "player.warnings").  When it is present the
-- warnings are rendered through it; when it is absent this module falls back to
-- emitting the bare `WARN[code]` marker itself (deduplicated by code).  It is
-- NEVER required at load time, so this module works whether or not that lane
-- has landed.
--
-- ===========================================================================
-- THE WARNING CONTRACT (who prints what)
-- ===========================================================================
-- nbs.analyze already knows the extended-range property at load time, so this
-- module prints that warning BEFORE playback begins.  ccnbs.play forwards every
-- other bare code through opts.on_warning; the same sink renders them, so each
-- code is emitted at most once.
--
-- Song and layer names are NBS CP1252 bytes and are shown through
-- nbs/cp1252.lua's to_display so the terminal never renders mojibake.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.

local ccnbs = require("ccnbs")
local clock_module = require("player.clock")
local runtime = require("player.runtime")
local cp1252 = require("nbs.cp1252")

local tui = {}

-- The bare code for the load-time extended-range property.
local CODE_EXTENDED_RANGE = "extended-range"

-- The bare code for "the song contains custom instruments that are refused".
-- Emitted load-time when a custom-only song has NO speaker to route them to;
-- ccnbs emits the same code at the end of playback when speakers DO exist.
local CODE_CUSTOM_INSTRUMENT = "custom-instrument"

-- ---------------------------------------------------------------------------
-- Defensive resolution of the (concurrently written) warning renderer
-- ---------------------------------------------------------------------------

-- load_warnings() -> module | nil.  Probed at CALL time, never at load time, so
-- this module is usable while player/warnings.lua does not exist yet.
local function load_warnings()
  local ok, mod = pcall(require, "player.warnings")
  if ok and type(mod) == "table" and type(mod.new) == "function" then
    return mod
  end
  return nil
end

-- make_warning_sink(write_line, quiet) -> { present, report(code, args),
--                                           callback(code, args) }
--
-- Prefers the real renderer; otherwise falls back to a once-per-code bare
-- marker.  Every call into the renderer is pcall-guarded so a half-written
-- foreign module can never take this lane down.
local function make_warning_sink(write_line, quiet)
  local warnings = load_warnings()
  if warnings ~= nil then
    local ok, instance = pcall(warnings.new, {
      emit = write_line,
      quiet = quiet,
    })
    if ok and type(instance) == "table" and type(instance.report) == "function" then
      local function report(code, args)
        pcall(instance.report, instance, code, args)
      end
      return { present = true, report = report, callback = report }
    end
  end

  local seen = {}
  local function bare_report(code, args)
    if code == nil or seen[code] then
      return nil
    end
    seen[code] = true
    if quiet then
      return nil
    end
    local line = "WARN[" .. tostring(code) .. "]"
    write_line(line)
    return line
  end

  return { present = false, report = bare_report, callback = bare_report }
end

-- ---------------------------------------------------------------------------
-- Default seams
-- ---------------------------------------------------------------------------

local function default_write(text)
  local term = rawget(_G, "term")
  if type(term) == "table" and type(term.write) == "function" then
    term.write(text)
  else
    io.write(text)
  end
end

local function default_read_file(path)
  local handle = io.open(path, "rb")
  if handle ~= nil then
    local data = handle:read("*a") or ""
    handle:close()
    return data
  end

  local fs = rawget(_G, "fs")
  if type(fs) == "table" and type(fs.open) == "function" then
    local ok, opened = pcall(fs.open, path, "rb")
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

-- default_scan(): every *.nbs in the working directory, sorted.  Uses the CC:T
-- `fs` module when present, else a shell listing on desktop Lua.
local function default_scan()
  local names = {}

  local fs = rawget(_G, "fs")
  if type(fs) == "table" and type(fs.list) == "function" then
    local ok, listing = pcall(fs.list, "")
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
    local command = (separator == "\\") and "dir /b *.nbs 2>nul" or "ls -1 *.nbs 2>/dev/null"
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

-- normalize_key(raw) -> lower-case key name | nil.  Accepts the string names the
-- test harness uses and, on CC:T, the numeric codes from the `keys` table.
local function normalize_key(raw)
  if type(raw) == "string" then
    return raw:lower()
  end
  if type(raw) == "number" then
    local keys = rawget(_G, "keys")
    if type(keys) == "table" then
      -- `pairs` is SAFE here: the matched name is only ever compared for
      -- equality against a fixed key set by the caller (up/down/enter/space/
      -- s/q/...).  Nothing is emitted or accumulated from this walk, so its
      -- iteration order cannot affect any output.
      for name, code in pairs(keys) do
        if code == raw then
          return tostring(name):lower()
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Cooperative scheduler fallback
-- ---------------------------------------------------------------------------

local function cooperative_yield()
  if coroutine.running() ~= nil then
    coroutine.yield()
  end
end

-- A minimal parallel.waitForAny with CC:T's contract: run every function as a
-- coroutine and return as soon as ANY of them returns.  An error in a function
-- propagates (so a terminate raised through the injected pull is not swallowed).
local function fallback_wait_for_any(...)
  local count = select("#", ...)
  if count < 1 then
    return 0
  end

  local threads = {}
  for index = 1, count do
    threads[index] = coroutine.create((select(index, ...)))
  end

  local guard = 0
  while true do
    guard = guard + 1
    if guard > 5000000 then
      return 0
    end
    for index = 1, count do
      if coroutine.status(threads[index]) ~= "dead" then
        local ok, err = coroutine.resume(threads[index])
        if not ok then
          error(err, 0)
        end
        if coroutine.status(threads[index]) == "dead" then
          return index
        end
      end
    end
  end
end

-- resolve_parallel() -> a module with waitForAny.  Prefers CC:T's global
-- `parallel`, then `require("parallel")`, then the fallback above.
local function resolve_parallel()
  local par = rawget(_G, "parallel")
  if type(par) == "table" and type(par.waitForAny) == "function" then
    return par
  end

  local ok, mod = pcall(require, "parallel")
  if ok and type(mod) == "table" and type(mod.waitForAny) == "function" then
    return mod
  end

  return { waitForAny = fallback_wait_for_any }
end

local parallel_mod = resolve_parallel()

-- ---------------------------------------------------------------------------
-- The gated clock (pause / resume through the clock seam)
-- ---------------------------------------------------------------------------

-- gated_clock(base) -> clock.
--
-- Wraps an injected clock so that pausing freezes musical time:
--   * now_ms() stops advancing while paused (and resumes continuously, with the
--     paused span subtracted, so the timeline never jumps);
--   * after(delay, fn) schedules on the base clock, but every callback is
--     routed through a gate that simply defers while paused;
--   * pause() cancels the armed base callbacks; resume() re-arms them with the
--     remaining delay measured from the frozen now_ms().
-- The base clock is the ONLY timer source; nothing here sleeps or polls.
local function gated_clock(base)
  local gate = {}
  gate._paused = false
  gate._paused_total = 0
  gate._pause_started = 0
  gate._items = {}

  function gate.now_ms()
    if gate._paused then
      return gate._pause_started - gate._paused_total
    end
    return base.now_ms() - gate._paused_total
  end

  local arm
  local function fire(item)
    item._armed = false
    if item._cancelled or item._fired then
      return
    end
    if gate._paused then
      return
    end
    local remaining = item._deadline - gate.now_ms()
    if remaining > 0.000001 then
      arm(item)
      return
    end
    item._fired = true
    item._fn()
  end

  arm = function(item)
    if item._cancelled or item._fired then
      return
    end
    if gate._paused then
      item._armed = false
      return
    end
    local remaining = item._deadline - gate.now_ms()
    if remaining < 0 then
      remaining = 0
    end
    item._armed = true
    item._handle = base.after(remaining / 1000, function()
      fire(item)
    end)
  end

  function gate.after(delay_sec, fn)
    local item = {
      _deadline = gate.now_ms() + delay_sec * 1000,
      _fn = fn,
    }
    gate._items[#gate._items + 1] = item
    arm(item)
    return item
  end

  function gate.cancel(item)
    if item == nil or item._cancelled or item._fired then
      return false
    end
    item._cancelled = true
    if item._armed and item._handle ~= nil and type(base.cancel) == "function" then
      base.cancel(item._handle)
    end
    item._armed = false
    return true
  end

  function gate.pause()
    if gate._paused then
      return false
    end
    gate._paused = true
    gate._pause_started = base.now_ms()
    for index = 1, #gate._items do
      local item = gate._items[index]
      if item._armed and item._handle ~= nil and type(base.cancel) == "function" then
        base.cancel(item._handle)
      end
      item._armed = false
    end
    return true
  end

  function gate.resume()
    if not gate._paused then
      return false
    end
    gate._paused_total = gate._paused_total + (base.now_ms() - gate._pause_started)
    gate._paused = false
    for index = 1, #gate._items do
      local item = gate._items[index]
      if not item._fired and not item._cancelled then
        arm(item)
      end
    end
    return true
  end

  function gate.is_paused()
    return gate._paused
  end

  function gate.run_due()
    if type(base.run_due) == "function" then
      return base.run_due()
    end
    return 0
  end

  return gate
end

-- ---------------------------------------------------------------------------
-- tui.run(opts) -> { exit_code, played, stopped }
-- ---------------------------------------------------------------------------

function tui.run(opts)
  opts = opts or {}

  local quiet = opts.quiet == true

  local write = opts.write
  if type(write) ~= "function" then
    write = default_write
  end
  local function line(text)
    write(text .. "\n")
  end

  local read_file = opts.read_file
  if type(read_file) ~= "function" then
    read_file = default_read_file
  end

  local files = opts.files
  if files == nil then
    files = default_scan()
  end
  if type(files) ~= "table" then
    files = {}
  end

  local speakers = opts.speakers
  if speakers == nil then
    speakers = ccnbs.discover_speakers()
  end
  if type(speakers) ~= "table" then
    speakers = {}
  end

  local base_clock = opts.clock
  if base_clock == nil then
    base_clock = clock_module.new_os()
  end
  local gate = gated_clock(base_clock)

  local max_events = opts.max_events
  local redraw = opts.redraw

  local sink = make_warning_sink(function(text)
    line(text)
  end, quiet)

  local state = {
    played = nil,
    stopped = false,
    paused = false,
    finished = false,
    session = nil,
  }

  local function cancel_session()
    if state.session ~= nil then
      pcall(function()
        state.session.cancel()
      end)
    end
  end

  local function stop_playback()
    if state.stopped then
      return
    end
    state.stopped = true
    cancel_session()
    pcall(runtime.stop_speakers, speakers)
  end

  local function refresh()
    if type(redraw) == "function" then
      pcall(redraw, state)
    end
  end

  local function handle_transport_key(key)
    if key == nil or state.finished then
      return
    end
    if key == "space" or key == "p" then
      if state.paused then
        state.paused = false
        gate.resume()
        line("继续播放。")
      else
        state.paused = true
        gate.pause()
        line("已暂停。")
      end
    elseif key == "s" or key == "q" then
      stop_playback()
      line("已停止。")
    end
    -- Any other key -- including left/right/a/d -- is intentionally inert.
    refresh()
  end

  local outcome = runtime.run(function(pull)
    if #files == 0 then
      line("未找到 .nbs 文件。")
      return { exit_code = 1, played = nil, stopped = false }
    end

    line("可用歌曲：")
    for index = 1, #files do
      line(tostring(index) .. ". " .. cp1252.to_display(tostring(files[index])))
    end
    refresh()

    -- ---- selection ------------------------------------------------------
    local chosen = nil
    local cursor = 1
    local guard = 0
    while chosen == nil do
      guard = guard + 1
      if guard > 100000 then
        break
      end
      local event = { pull() }
      local name = event[1]
      if name ~= "key" then
        break
      end
      local key = normalize_key(event[2])
      if key == "up" then
        cursor = cursor - 1
        if cursor < 1 then
          cursor = #files
        end
      elseif key == "down" then
        cursor = cursor + 1
        if cursor > #files then
          cursor = 1
        end
      elseif key == "enter" or key == "space" then
        chosen = cursor
      elseif key == "q" or key == "escape" then
        break
      end
    end

    if chosen == nil then
      line("已取消选择。")
      return { exit_code = 0, played = nil, stopped = false }
    end

    local path = files[chosen]
    state.played = path

    -- ---- decode + analyze ----------------------------------------------
    local bytes = read_file(path)
    if bytes == nil then
      bytes = ""
    end
    local decoded = ccnbs.decode(bytes)
    if not decoded.ok then
      line("解码失败：" .. cp1252.to_display(tostring(path))
        .. "（错误码 " .. tostring(decoded.error.code) .. "）")
      return { exit_code = 2, played = path, stopped = false }
    end

    local song = decoded.song
    local analysis = ccnbs.analyze(song)

    local title = song.header.name
    if title == nil or title == "" then
      title = tostring(path)
    end
    line("曲目 " .. cp1252.to_display(title)
      .. "：音符 " .. tostring(analysis.total_notes)
      .. "，峰值并发 " .. tostring(analysis.peak_concurrent)
      .. "，tick_ms " .. tostring(analysis.tick_ms))

    -- ---- load-time warnings, BEFORE playback ----------------------------
    if analysis.has_extended_range then
      sink.report(CODE_EXTENDED_RANGE, {
        min_key = analysis.min_key,
        max_key = analysis.max_key,
      })
    end

    -- A song made ONLY of custom-instrument notes is silent by construction:
    -- those notes are refused at playback, so none ever reaches a speaker.
    -- With speakers attached, ccnbs reports that refusal at the end; with NO
    -- speaker attached the custom events are never routed, so the summary never
    -- fires.  Surface the reason here so the user is not left with unexplained
    -- silence.
    if analysis.all_notes_custom and #speakers == 0 then
      sink.report(CODE_CUSTOM_INSTRUMENT, { count = analysis.total_notes })
    end

    -- ---- start playback through ccnbs.play ------------------------------
    state.session = ccnbs.play(song, {
      speakers = speakers,
      clock = gate,
      on_warning = function(code, args)
        sink.callback(code, args)
      end,
      on_progress = function(info)
        line("进度 " .. tostring(info.index) .. "/" .. tostring(info.total))
        refresh()
      end,
    })
    refresh()

    local function session_done()
      return state.session == nil or not state.session.is_playing()
    end

    -- The transport/UI loop: read events, act on transport keys, stay alive.
    local function ui_loop()
      local count = 0
      while true do
        if state.stopped or state.finished then
          return
        end
        if max_events ~= nil and count >= max_events then
          stop_playback()
          return
        end
        local event = { pull() }
        count = count + 1
        if event[1] == "key" then
          handle_transport_key(normalize_key(event[2]))
        end
        cooperative_yield()
      end
    end

    -- The playback loop: drain the clock so scheduled notes fire.  It owns no
    -- keys and never reads them.
    local function dispatch_loop()
      while not state.stopped do
        if session_done() then
          state.finished = true
          return
        end
        if state.paused then
          cooperative_yield()
        else
          gate.run_due()
          cooperative_yield()
        end
      end
    end

    parallel_mod.waitForAny(ui_loop, dispatch_loop)

    -- A normal finish or a bounded loop leaves the speakers silent; a deliberate
    -- stop already stopped them.
    if not state.stopped then
      pcall(runtime.stop_speakers, speakers)
    end

    return { exit_code = 0, played = state.played, stopped = state.stopped }
  end, {
    speakers = speakers,
    session = { cancel = cancel_session },
    pull = opts.pull,
    on_terminate = function()
      state.stopped = true
    end,
  })

  if outcome.terminated then
    return { exit_code = 0, played = state.played, stopped = true }
  end

  if outcome.error ~= nil then
    line("运行出错：" .. tostring(outcome.error))
    return { exit_code = 3, played = state.played, stopped = state.stopped }
  end

  if type(outcome.result) == "table" then
    return outcome.result
  end

  return { exit_code = 0, played = state.played, stopped = state.stopped }
end

return tui
