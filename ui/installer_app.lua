-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSPlayer. Licensed under GPL-2.0; see LICENSE.
--
-- ui/installer_app.lua
--
-- THE INSTALLER'S BASALT VIEW -- the GUI the bootstrap in installer.lua hands
-- control to once Basalt and utf8display are on the machine.
--
-- ===========================================================================
-- WHY THERE IS NO SPEC FOR THIS FILE (on purpose)
-- ===========================================================================
-- Basalt has NO headless mode, no mock terminal and no test helpers: basalt.run()
-- blocks in its own os.pullEventRaw loop and cannot be driven from a unit test.
-- So, exactly as ui/basalt_app.lua does, the VIEW IS KEPT THIN and every
-- DECISION it makes is delegated:
--
--   * the file list and the download task list come from            installer
--   * the per-file space check and the write come from    installer.write_one
--   * URL/target/directory mapping comes from      installer.download_tasks
--   * the source menu text, its parser and the "should we prompt at all"
--     decision live in installer.source_menu_lines / parse_source_choice /
--     should_prompt, where tests/installer_spec.lua DOES cover them
--
-- If you are about to format a URL, compute a target path or decide how much
-- space a file needs HERE, call the installer instead.  This file wires widgets
-- to those helpers; it does not think.
--
-- ===========================================================================
-- FROZEN INTERFACE
-- ===========================================================================
--   local app = require("ui.installer_app")   -- but it is normally load()ed
--   app.run(deps) -> { exit_code = <integer> }
--
-- `deps` -- every dependency is injected so the view never reaches for a project
-- module (it is fetched as a bare file during bootstrap, with no package.path):
--   deps.basalt       the Basalt table          (required)
--   deps.utf8display  the CJK bimg renderer      (optional; nil = ASCII only)
--   deps.installer    installer.lua's table      (required)
--   deps.sources      array of { name, base }    (the switchable sources)
--   deps.base         the ACTIVE source's base   (defaults to sources[1].base)
--   deps.files        the manifest file list     (defaults to RUNTIME_FILES)
--   deps.log          function(text) for the console fallback / diagnostics
--
-- ===========================================================================
-- THE DOWNLOAD IS ASYNCHRONOUS (http.request + Basalt event handlers)
-- ===========================================================================
-- http.get BLOCKS, so it would freeze the progress bar.  This view therefore
-- uses the ASYNCHRONOUS http.request and registers global basalt.onEvent
-- handlers for "http_success" / "http_failure".  A request is identified by a
-- token appended to the URL and looked up in a pending table.  A
-- basalt.schedule watchdog fires the SAME retry path if a transport never
-- dispatches http_failure (a real CC:Tweaked quirk), so a stalled request can
-- never wedge the UI.  The whole install still comes from ONE base: every task
-- URL is built by installer.download_tasks(base, files) from the ACTIVE source.
--
-- ===========================================================================
-- CHINESE RENDERING
-- ===========================================================================
-- The official Basalt cannot draw CJK in a text element; the vendored fork adds
-- setImage to labels and buttons.  Chinese is therefore converted to a `bimg`
-- with utf8display.strToBimg and drawn through setImage; PURE ASCII text takes
-- the plain setText path.  The ASCII path deliberately never calls strToBimg --
-- the renderer would auto-fetch its ~1.68 MB font on first use, and an English
-- UI on a default server must not pay that.  If Chinese cannot be produced (no
-- font / no renderer), setText still shows the bytes, so the UI never dies.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no math.maxinteger, no collectgarbage, no string.dump and no os.exit.

local app = {}

app.NAME = "CCNBSPlayer"

-- ---------------------------------------------------------------------------
-- Language: the local, keyed string table (en + zh), mirroring installer.lua
-- ---------------------------------------------------------------------------
-- The ACTIVE code is read from installer.get_language(), so the installer and
-- its GUI always speak with one voice.  {named} placeholders are substituted; a
-- missing key returns the key itself so a gap is visible.

local L10N = {
  en = {
    ["app.title"] = "CCNBSPlayer Installer",
    ["app.source_active"] = "source: {name}  ({base})",
    ["app.source_hint"] = "Pick a source from the list above, then click Install.",
    ["app.ready"] = "Ready. Pick a source, then click Install.",
    ["app.preparing"] = "Preparing the download list ...",
    ["app.downloading"] = "Downloading",
    ["app.download_done"] = "Download complete. Click Write to install.",
    ["app.writing"] = "Writing files",
    ["app.done"] = "Installation complete.",
    ["app.failed"] = "Installation failed",
    ["app.cancelled"] = "Cancelled",
    ["app.file_progress"] = "{index}/{total}  {name}",
    ["app.retrying"] = "retrying {attempt}/{max}: {name}",
    ["app.detail_ready"] =
      "Every file is downloaded to memory before anything is written.",
    ["app.detail_download_done"] = "All {count} files are in memory.",
    ["app.detail_done"] = "Wrote {count} files under /lib. Reboot to finish.",
    ["app.detail_cancelled"] = "Nothing was written.",
    ["app.detail_later"] = "Run /lib/ccnbsplayer after rebooting whenever you like.",
    ["app.autostart.yes"] = "Start at boot: YES",
    ["app.autostart.no"] = "Start at boot: NO",
    ["app.autostart.pending_on"] = "Autostart will be ENABLED when you click Write.",
    ["app.autostart.pending_off"] = "Autostart will be DISABLED when you click Write.",
    ["app.autostart.unchanged"] = "Autostart left unchanged (nothing chosen).",
    ["app.btn.start"] = "Install",
    ["app.btn.cancel"] = "Cancel",
    ["app.btn.write"] = "Write",
    ["app.btn.reboot"] = "Reboot",
    ["app.btn.later"] = "Later",
    ["app.err_no_http"] = "Cannot download: HTTP is disabled on this computer.",
    ["app.err_no_fs"] = "Cannot write: the filesystem is unavailable.",
    ["app.err_no_files"] = "The file list is empty; there is nothing to download.",
    ["app.err_timeout"] = "network timed out",
    ["app.err_unreadable"] = "the response could not be read",
    ["app.err_status"] = "HTTP {code}",
    ["app.download_failed"] = "Download failed: {name} ({detail})",
    ["app.mkdir_failed"] = "Cannot create directory: {dir}",
  },
  zh = {
    ["app.title"] = "CCNBSPlayer 安装程序",
    ["app.source_active"] = "当前来源：{name}（{base}）",
    ["app.source_hint"] = "可在上方列表切换来源，然后点击“开始安装”。",
    ["app.ready"] = "准备就绪。请选择来源，然后点击“开始安装”。",
    ["app.preparing"] = "正在准备下载列表……",
    ["app.downloading"] = "正在下载",
    ["app.download_done"] = "下载完成，点击“写入”开始安装。",
    ["app.writing"] = "正在写入文件",
    ["app.done"] = "安装完成。",
    ["app.failed"] = "安装失败",
    ["app.cancelled"] = "已取消",
    ["app.file_progress"] = "{index}/{total}　{name}",
    ["app.retrying"] = "重试 {attempt}/{max}：{name}",
    ["app.detail_ready"] = "所有文件会先完整下载到内存，再统一写入，避免装到一半。",
    ["app.detail_download_done"] = "已把 {count} 个文件下载到内存。",
    ["app.detail_done"] = "已写入 {count} 个文件到 /lib，重启后生效。",
    ["app.detail_cancelled"] = "没有写入任何文件。",
    ["app.detail_later"] = "稍后重启，再运行 /lib/ccnbsplayer 即可。",
    ["app.autostart.yes"] = "开机自启动：是",
    ["app.autostart.no"] = "开机自启动：否",
    ["app.autostart.pending_on"] = "点击“写入”后将启用开机自启动。",
    ["app.autostart.pending_off"] = "点击“写入”后将关闭开机自启动。",
    ["app.btn.start"] = "开始安装",
    ["app.btn.cancel"] = "取消",
    ["app.btn.write"] = "写入",
    ["app.btn.reboot"] = "重启",
    ["app.btn.later"] = "稍后",
    ["app.err_no_http"] = "无法下载：本机未启用 HTTP。",
    ["app.err_no_fs"] = "无法写入：文件系统不可用。",
    ["app.err_no_files"] = "文件列表为空，没有可下载的内容。",
    ["app.err_timeout"] = "网络超时",
    ["app.err_unreadable"] = "响应无法读取",
    ["app.err_status"] = "HTTP {code}",
    ["app.download_failed"] = "下载失败：{name}（{detail}）",
    ["app.mkdir_failed"] = "无法创建目录：{dir}",
  },
}

app.DEFAULT_LANGUAGE = "en"

-- ---------------------------------------------------------------------------
-- Small lazy/total helpers.  Every global is read through pcall so a hostile or
-- incomplete host yields nil instead of a traceback at load time.
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

-- chinese_renderable(utf8display) -> boolean.
--
-- The installer bootstraps utf8display for ONE reason: so its own interface can
-- speak Chinese.  But a freshly installed machine has no ui/i18n.lua yet, so
-- installer.get_language() still reports "en" and the UI came up in English with
-- a CJK renderer sitting unused beside it.
--
-- It PROBES rather than assumes, because the renderer fetches a ~1.7 MB font on
-- first use and that can fail (host unreachable, no disk space).  Making it draw
-- one glyph settles the question.  A UI that cannot render Chinese must then
-- speak English -- NEVER emit raw non-ASCII, which a CC terminal draws as
-- garbage.
local function chinese_renderable(utf8display)
  if type(utf8display) ~= "table" or type(utf8display.strToBimg) ~= "function" then
    return false
  end
  local ok, image = pcall(utf8display.strToBimg, "中", "Q", "B")
  return ok and type(image) == "table"
end

-- active_language(installer, prefer_chinese) -> a code present in L10N.
-- `prefer_chinese` wins when the renderer can actually draw it; otherwise the
-- installer's own language decides, and that defaults to English.
local function active_language(installer, prefer_chinese)
  if prefer_chinese == true and L10N.zh ~= nil then
    return "zh"
  end
  local code = app.DEFAULT_LANGUAGE
  if type(installer) == "table" and type(installer.get_language) == "function" then
    local ok, value = pcall(installer.get_language)
    if ok and type(value) == "string" and L10N[value] ~= nil then
      code = value
    end
  end
  return code
end

-- make_tr(installer, prefer_chinese) -> function(key, args) -> sentence.  Never
-- raises, never returns nil: an unknown key returns the key (a visible,
-- greppable gap).
local function make_tr(installer, prefer_chinese)
  return function(key, args)
    local table_for = L10N[active_language(installer, prefer_chinese)] or L10N.en
    local text = table_for[key]
    if type(text) ~= "string" then
      text = L10N.en[key]
    end
    if type(text) ~= "string" then
      return tostring(key)
    end
    if type(args) == "table" then
      text = text:gsub("{([%w_]+)}", function(name)
        local value = args[name]
        if value == nil then
          return "{" .. name .. "}"
        end
        return tostring(value)
      end)
    end
    return text
  end
end

-- sleep_seconds(seconds): CC's cooperative sleep.  A missing global means the
-- yield must not happen; the surrounding scheduled coroutine then just continues.
local function sleep_seconds(seconds)
  local sleeper = rawget(_G, "sleep")
  if type(sleeper) == "function" then
    sleeper(seconds)
    return
  end
  local oslib = read_global("os")
  if type(oslib) == "table" and type(oslib.sleep) == "function" then
    pcall(oslib.sleep, seconds)
  end
end

-- is_ascii(text) -> true when every byte is < 128.  Pure ASCII takes the plain
-- setText path and never wakes the CJK renderer (see the header).
local function is_ascii(text)
  for index = 1, #text do
    if text:byte(index) >= 128 then
      return false
    end
  end
  return true
end

-- short_base(base) -> the host of a base URL, so the active-source line stays a
-- single short line even though a raw.githubusercontent base is ~70 characters.
local function short_base(base)
  local host = tostring(base or ""):match("^%a[%w+.-]*://([^/]+)")
  if type(host) == "string" and host ~= "" then
    return host
  end
  return tostring(base or "")
end

-- text_length(text) -> the number of CHARACTERS (not bytes) for colour padding.
-- CC:Tweaked's Cobalt provides utf8.len; this project's desktop interpreter does
-- NOT, but this whole module is only ever load()ed on a computer -- never from a
-- unit test -- and the call is pcall-guarded so a host without utf8 degrades to
-- the byte length instead of raising.
local function text_length(text)
  local ok, value = pcall(function()
    return utf8.len(text)
  end)
  if ok and type(value) == "number" and value >= 0 then
    return value
  end
  return #text
end

-- blit_of(colors_table, color) -> the single blit character for a colour, used
-- to build the per-character colour strings strToBimg expects.
local function blit_of(colors_table, color)
  if type(colors_table) == "table" and type(colors_table.toBlit) == "function" then
    local ok, value = pcall(colors_table.toBlit, color)
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return "f"
end

-- process_str_to_bimg(utf8display, text, fg, bg) -> bimg | nil.  PURE.  The
-- colour strings must be as long as the CHARACTER count, so they are padded with
-- their own last character before the call.  Returns nil -- never raises -- when
-- the renderer is missing, has no font, or rejects the text.
local function process_str_to_bimg(utf8display, text, fg, bg)
  text = tostring(text or "")
  if type(utf8display) ~= "table" or type(utf8display.strToBimg) ~= "function" then
    return nil
  end
  local count = text_length(text)
  fg = tostring(fg or "f")
  bg = tostring(bg or "0")
  if count > #fg then
    fg = fg .. string.rep(fg:sub(-1), count - #fg)
  end
  if count > #bg then
    bg = bg .. string.rep(bg:sub(-1), count - #bg)
  end
  local ok, image = pcall(utf8display.strToBimg, text, fg, bg)
  if ok and type(image) == "table" then
    return image
  end
  return nil
end

-- render_text(element, text, fg, bg, utf8display): draw Chinese as an image and
-- everything else as plain text.  A failed bimg build is NOT fatal -- the label
-- falls back to the raw characters.
local function render_text(element, text, fg, bg, utf8display)
  text = tostring(text or "")
  if not is_ascii(text) then
    local image = process_str_to_bimg(utf8display, text, fg, bg)
    if image ~= nil then
      element:setImage(image)
      return
    end
  end
  element:setText(text)
end

-- apply_palette(): a deliberately DARK theme, set through term.setPaletteColor.
-- Best-effort: a host with no palette simply keeps its defaults.
local function apply_palette()
  local term_api = read_global("term")
  local colors_table = read_global("colors")
  if type(term_api) ~= "table" or type(term_api.setPaletteColor) ~= "function" then
    return
  end
  if type(colors_table) ~= "table" then
    return
  end
  local entries = {
    { colors_table.black,     0x0B0B0F },
    { colors_table.gray,      0x16161C },
    { colors_table.lightGray, 0x2A2A32 },
    { colors_table.white,     0xE8E8F0 },
    { colors_table.blue,      0x2E4A7D },
    { colors_table.purple,    0xF2B8C6 },
    { colors_table.magenta,   0x6B5A62 },
    { colors_table.red,       0x8C3B3B },
    { colors_table.green,     0x3B7D4A },
    { colors_table.yellow,    0xC9A227 },
  }
  for index = 1, #entries do
    pcall(term_api.setPaletteColor, entries[index][1], entries[index][2])
  end
end

-- ---------------------------------------------------------------------------
-- run_view(): the whole view.  Defined separately so app.run can pcall it and
-- guarantee a typed result and a stopped event loop even on an internal error.
-- ---------------------------------------------------------------------------

local function run_view(deps, basalt, installer, utf8display, log)
  -- Speak Chinese when the renderer can actually draw it: the installer ships a
  -- CJK renderer for exactly this purpose, and a Chinese interface is what this
  -- project's audience expects (the reference implementation's installer is
  -- Chinese too).  When it cannot, the UI stays English rather than printing
  -- glyphs the terminal cannot draw.
  local prefer_chinese = chinese_renderable(utf8display)
  local tr = make_tr(installer, prefer_chinese)
  local colors_table = read_global("colors") or {}
  local FG = colors_table.white or 1
  local BG = colors_table.black or 32768
  local PANEL = colors_table.gray or BG
  local ACCENT = colors_table.purple or colors_table.magenta or FG
  local MUTED = colors_table.lightGray or FG
  local FG_BLIT = blit_of(colors_table, FG)
  local BG_BLIT = blit_of(colors_table, BG)
  local PANEL_BLIT = blit_of(colors_table, PANEL)
  local ACCENT_BLIT = blit_of(colors_table, ACCENT)

  apply_palette()

  -- ------------------------------------------------------------ inputs -----
  local sources = deps.sources
  if type(sources) ~= "table" or #sources == 0 then
    sources = { { name = "github", base = deps.base or installer.DEFAULT_BASE_URL } }
  end
  local base = deps.base or sources[1].base
  local files = deps.files
  if type(files) ~= "table" or #files == 0 then
    files = installer.RUNTIME_FILES
  end

  -- ------------------------------------------------------------- frame -----
  local frame = basalt.getMainFrame()
  frame:setBackground(BG)

  local header = frame:addFrame({
    x = 1, y = 1, width = "{parent.width}", height = 3, background = PANEL,
  })
  local title = header:addLabel({
    x = 2, y = 1, width = "{parent.width-3}", height = 3,
    foreground = ACCENT, background = PANEL,
  })
  render_text(title, tr("app.title"), ACCENT_BLIT, PANEL_BLIT, utf8display)

  local content = frame:addFrame({
    x = 1, y = 4, width = "{parent.width}", height = 10, background = BG,
  })
  local status = content:addLabel({
    x = 2, y = 1, width = "{parent.width-3}", height = 2,
    foreground = FG, background = BG,
  })
  local source_title = content:addLabel({
    x = 2, y = 3, width = "{parent.width-3}", height = 1,
    foreground = FG, background = BG,
  })
  local source_list = content:addList({
    x = 2, y = 4, width = "{parent.width-4}", height = 4,
    background = BG, foreground = FG,
    selectedBackground = ACCENT, selectedForeground = BG,
  })
  local progress = content:addProgressBar({
    x = 2, y = 9, width = "{parent.width-4}", height = 1,
    background = PANEL, foreground = FG, progressColor = ACCENT,
    showPercentage = true,
  })
  local detail = content:addLabel({
    x = 2, y = 10, width = "{parent.width-3}", height = 1,
    foreground = MUTED, background = BG,
  })

  -- The source picker.  Native Basalt lists are ASCII-only, which is exactly
  -- right: source names (github, ghproxy, jsdelivr, ...) are ASCII.
  local items = {}
  for index = 1, #sources do
    items[index] = { text = tostring(sources[index].name) }
  end
  source_list:setItems(items)

  local active_index = 1
  for index = 1, #sources do
    if sources[index].base == base then
      active_index = index
      break
    end
  end
  source_list:selectItem(active_index)

  -- ----------------------------------------------------------- buttons -----
  local button_width = "{floor(parent.width/2-3)}"
  local left_x = 2
  local right_x = "{floor(parent.width/2+1)}"
  local buttons_y = 14
  local buttons_h = 3

  local function make_button(x, label_key)
    local button = frame:addButton({
      x = x, y = buttons_y, width = button_width, height = buttons_h,
      foreground = FG, background = PANEL,
    })
    render_text(button, tr(label_key), FG_BLIT, PANEL_BLIT, utf8display)
    return button
  end

  local start_button = make_button(left_x, "app.btn.start")
  local write_button = make_button(left_x, "app.btn.write")
  local reboot_button = make_button(left_x, "app.btn.reboot")
  local cancel_button = make_button(right_x, "app.btn.cancel")
  local later_button = make_button(right_x, "app.btn.later")

  write_button:setVisible(false)
  write_button:setEnabled(false)
  reboot_button:setVisible(false)
  reboot_button:setEnabled(false)
  later_button:setVisible(false)
  later_button:setEnabled(false)

  -- THE AUTOSTART QUESTION, asked as two explicit answers.
  --
  -- It writes or removes a ROOT /startup.lua, which CC runs at boot.  A single
  -- quiet toggle along the bottom did not read as a question: the requirement is
  -- "whether to start at boot", a yes/no the user is meant to ANSWER, not a
  -- setting they are meant to notice.  Two buttons put the question and the
  -- current answer on screen at once, and the chosen answer is highlighted.
  --
  -- Neither is highlighted while the preference is unknown (state.autostart ==
  -- nil), and in that state clicking Write changes NOTHING on disk.
  local autostart_yes = frame:addButton({
    x = left_x, y = 17, width = button_width, height = 3,
    foreground = FG, background = PANEL,
  })
  local autostart_no = frame:addButton({
    x = right_x, y = 17, width = button_width, height = 3,
    foreground = FG, background = PANEL,
  })

  -- ------------------------------------------------------- autostart init ---
  -- The toggle must START FROM WHAT IS ON DISK, not from a hard default. With a
  -- default of OFF, a user who enabled autostart last time would see OFF, press
  -- Write without touching it, and silently lose the setting -- the same
  -- deleted-autostart bug that the installer's tri-state fix removed from the
  -- non-interactive path. Reading the disk makes the label honest AND makes an
  -- untouched toggle a no-op.
  --
  -- An EXPLICIT deps.autostart (--autostart / --no-autostart) still wins: the user
  -- said so on the command line.
  local function detect_autostart()
    local probe = installer.wrap_fs(read_global("fs"))
    if type(probe) ~= "table" or type(probe.read) ~= "function" then
      return nil
    end
    local ok_exists, exists = pcall(probe.exists, installer.AUTOSTART_PATH)
    if not ok_exists or exists ~= true then
      return false
    end
    local ok_read, content = pcall(probe.read, installer.AUTOSTART_PATH)
    if not ok_read or type(content) ~= "string" then
      return nil
    end
    return installer.is_our_autostart(content)
  end

  local initial_autostart
  if deps.autostart == true then
    initial_autostart = true
  elseif deps.autostart == false then
    initial_autostart = false
  else
    -- TRI-STATE: nil (could not read the disk) must stay nil, so an untouched
    -- question changes nothing rather than deleting a startup file we failed to
    -- recognise.
    local detected = detect_autostart()
    if detected == nil then
      initial_autostart = nil
    else
      initial_autostart = detected
    end
  end

  -- ------------------------------------------------------------- state -----
  local state = {
    started = false,
    finished = false,
    progress = 0,
    tasks = nil,
    bodies = nil,
    -- Reflects the disk (or an explicit flag), so an untouched toggle changes nothing.
    autostart = initial_autostart,
  }

  local pending = {}
  local serial = 0
  local REQUEST_TIMEOUT = 8

  -- ---------------------------------------------------------- rendering ----
  local function set_status(text)
    render_text(status, text, FG_BLIT, BG_BLIT, utf8display)
  end

  local function set_detail(text)
    render_text(detail, text, blit_of(colors_table, MUTED), BG_BLIT, utf8display)
  end

  local function set_source_title()
    local active = sources[active_index]
    if active == nil then
      render_text(source_title, "", FG_BLIT, BG_BLIT, utf8display)
      return
    end
    render_text(source_title,
      tr("app.source_active", { name = active.name, base = short_base(active.base) }),
      FG_BLIT, BG_BLIT, utf8display)
  end

  local function set_progress(percent)
    if type(percent) ~= "number" then
      percent = 0
    end
    if percent < 0 then
      percent = 0 end
    if percent > 100 then
      percent = 100 end
    state.progress = percent
    progress:setProgress(math.floor(percent + 0.5))
  end

  -- Paint the two answers, highlighting the chosen one.  The button's own
  -- background and the text's background are set TOGETHER, so a selected answer
  -- is highlighted across the whole button rather than only behind the glyphs.
  local function render_autostart()
    local function paint(button, key, selected)
      local bg_color = selected and ACCENT or PANEL
      local bg_blit = selected and ACCENT_BLIT or PANEL_BLIT
      pcall(function()
        button:setBackground(bg_color)
      end)
      render_text(button, tr(key), FG_BLIT, bg_blit, utf8display)
    end
    paint(autostart_yes, "app.autostart.yes", state.autostart == true)
    paint(autostart_no, "app.autostart.no", state.autostart == false)
  end

  -- ------------------------------------------------------------- http ------
  local http_api = read_global("http")

  local function start_request(task, callback)
    if type(http_api) ~= "table" or type(http_api.request) ~= "function" then
      callback(nil, tr("app.err_no_http"))
      return
    end

    serial = serial + 1
    local token = tostring(serial)
    local separator = "?"
    if task.url:find("?", 1, true) ~= nil then
      separator = "&"
    end
    local url = task.url .. separator .. "CCNBSInstaller=" .. token

    local request = { token = token, callback = callback }
    pending[token] = request

    local ok, accepted, request_error = pcall(http_api.request, {
      url = url,
      method = "GET",
      headers = { ["User-Agent"] = "CCNBSPlayer-Installer/1.0" },
      timeout = REQUEST_TIMEOUT,
    })
    -- accepted == false is an explicit rejection (bad/blocked URL); a nil/true
    -- return is accepted and resolved by the event handlers or the watchdog.
    if not ok or accepted == false then
      pending[token] = nil
      callback(nil, tostring(request_error or "http request rejected"))
      return
    end

    -- Watchdog: some transports never dispatch http_failure, so the SAME retry
    -- path is driven from here and a stalled request cannot wedge the UI.
    basalt.schedule(function()
      sleep_seconds(REQUEST_TIMEOUT)
      if pending[token] == request then
        pending[token] = nil
        callback(nil, tr("app.err_timeout"))
      end
    end)
  end

  -- request_task: one task, up to installer.MAX_ATTEMPTS bounded attempts.
  local function request_task(task, callback)
    local failures = 0
    local function attempt()
      start_request(task, function(body, err)
        if body ~= nil then
          callback(body, nil)
          return
        end
        failures = failures + 1
        if failures < installer.MAX_ATTEMPTS then
          set_detail(tr("app.retrying", {
            name = task.repo_path,
            attempt = failures,
            max = installer.MAX_ATTEMPTS - 1,
          }))
          attempt()
        else
          callback(nil, err)
        end
      end)
    end
    attempt()
  end

  -- Global response routing (see the header).
  basalt.onEvent("http_success", function(url, response)
    local token = tostring(url):match("[?&]CCNBSInstaller=([^&#]+)")
    local request = token and pending[token]
    if request == nil then
      if type(response) == "table" and type(response.close) == "function" then
        pcall(response.close, response)
      end
      return
    end
    pending[token] = nil
    local code_ok, code = pcall(function()
      return response.getResponseCode()
    end)
    local read_ok, body = pcall(function()
      return response.readAll()
    end)
    pcall(function()
      response.close()
    end)
    if not read_ok or type(body) ~= "string" then
      request.callback(nil, tr("app.err_unreadable"))
    elseif code_ok and (code < 200 or code >= 300) then
      request.callback(nil, tr("app.err_status", { code = tostring(code) }))
    else
      request.callback(body, nil)
    end
  end)

  basalt.onEvent("http_failure", function(url, message)
    local token = tostring(url):match("[?&]CCNBSInstaller=([^&#]+)")
    local request = token and pending[token]
    if request == nil then
      return
    end
    pending[token] = nil
    request.callback(nil, tostring(message or "network failure"))
  end)

  -- ------------------------------------------------------- install flow ----
  local function fail(message)
    state.started = false
    pending = {}
    set_status(tr("app.failed"))
    set_detail(tostring(message))
    start_button:setVisible(true)
    start_button:setEnabled(true)
    cancel_button:setVisible(true)
    cancel_button:setEnabled(true)
    write_button:setVisible(false)
    write_button:setEnabled(false)
    pcall(function()
      source_list:setEnabled(true)
    end)
  end

  local function download_from(index)
    local tasks = state.tasks
    if index > #tasks then
      set_status(tr("app.download_done"))
      set_detail(tr("app.detail_download_done", { count = #tasks }))
      set_progress(100)
      write_button:setVisible(true)
      write_button:setEnabled(true)
      cancel_button:setVisible(true)
      cancel_button:setEnabled(true)
      return
    end

    local task = tasks[index]
    set_detail(tr("app.file_progress", {
      index = index, total = #tasks, name = task.repo_path,
    }))
    set_progress((index - 1) / #tasks * 100)

    request_task(task, function(body, err)
      if body == nil then
        fail(tr("app.download_failed", {
          name = task.repo_path, detail = tostring(err),
        }))
        return
      end
      state.bodies[index] = body
      set_progress(index / #tasks * 100)
      download_from(index + 1)
    end)
  end

  local function begin_download()
    if type(http_api) ~= "table" or type(http_api.request) ~= "function" then
      fail(tr("app.err_no_http"))
      return
    end
    state.tasks = installer.download_tasks(base, files)
    state.bodies = {}
    if #state.tasks == 0 then
      fail(tr("app.err_no_files"))
      return
    end
    set_status(tr("app.downloading"))
    set_detail("")
    set_progress(0)
    download_from(1)
  end

  start_button:onClick(function()
    if state.started then
      return
    end
    state.started = true
    start_button:setVisible(false)
    start_button:setEnabled(false)
    write_button:setVisible(false)
    write_button:setEnabled(false)
    pcall(function()
      source_list:setEnabled(false)
    end)
    -- Once the install starts the answer is fixed, so both answers stop taking
    -- input (the click handlers guard on state.started as well).
    autostart_yes:setEnabled(false)
    autostart_no:setEnabled(false)
    set_status(tr("app.preparing"))
    set_detail("")
    set_progress(0)
    basalt.schedule(function()
      begin_download()
    end)
  end)

  local function do_write()
    local tasks = state.tasks
    local bodies = state.bodies
    if type(tasks) ~= "table" or type(bodies) ~= "table" then
      fail(tr("app.err_no_files"))
      return
    end

    local fs = installer.wrap_fs(read_global("fs"))
    if type(fs) ~= "table" then
      fail(tr("app.err_no_fs"))
      return
    end

    set_status(tr("app.writing"))

    local dirs = installer.install_dirs(files)
    for index = 1, #dirs do
      local dir = dirs[index]
      if not fs.exists(dir) then
        if not fs.make_dir(dir) then
          fail(tr("app.mkdir_failed", { dir = dir }))
          return
        end
      end
    end

    for index = 1, #tasks do
      set_detail(tr("app.file_progress", {
        index = index, total = #tasks, name = tasks[index].repo_path,
      }))
      local result = installer.write_one(fs, tasks[index], bodies[index], {
        installed = index - 1,
        total = #tasks,
      })
      if not result.ok then
        fail(result.message)
        return
      end
      set_progress(index / #tasks * 100)
      sleep_seconds(0)
    end

    -- Autostart runs AFTER the player files are on disk (the file it writes
    -- references /lib/ccnbsplayer).  autostart_apply NEVER touches a foreign
    -- /startup.lua; a "skip-foreign" result is surfaced below so the user learns
    -- WHY autostart could not be enabled and how to do it themselves.
    local auto = installer.autostart_apply(fs, state.autostart)

    state.finished = true
    set_status(tr("app.done"))
    if auto ~= nil and type(auto.message) == "string" then
      set_detail(auto.message)
    else
      set_detail(tr("app.detail_done", { count = #tasks }))
    end
    set_progress(100)
    write_button:setVisible(false)
    write_button:setEnabled(false)
    cancel_button:setVisible(false)
    cancel_button:setEnabled(false)
    reboot_button:setVisible(true)
    reboot_button:setEnabled(true)
    later_button:setVisible(true)
    later_button:setEnabled(true)
  end

  write_button:onClick(function()
    if type(state.tasks) ~= "table" or type(state.bodies) ~= "table" then
      return
    end
    write_button:setEnabled(false)
    cancel_button:setEnabled(false)
    basalt.schedule(function()
      do_write()
    end)
  end)

  cancel_button:onClick(function()
    pending = {}
    set_status(tr("app.cancelled"))
    set_detail(tr("app.detail_cancelled"))
    start_button:setVisible(false)
    start_button:setEnabled(false)
    write_button:setVisible(false)
    write_button:setEnabled(false)
    reboot_button:setVisible(false)
    reboot_button:setEnabled(false)
    later_button:setVisible(false)
    later_button:setEnabled(false)
    cancel_button:setVisible(false)
    cancel_button:setEnabled(false)
    basalt.schedule(function()
      sleep_seconds(0.4)
      basalt.stop()
    end)
  end)

  reboot_button:onClick(function()
    local oslib = read_global("os")
    if type(oslib) == "table" and type(oslib.reboot) == "function" then
      pcall(oslib.reboot)
    end
  end)

  later_button:onClick(function()
    set_status(tr("app.done"))
    set_detail(tr("app.detail_later"))
    reboot_button:setVisible(false)
    reboot_button:setEnabled(false)
    later_button:setVisible(false)
    later_button:setEnabled(false)
    basalt.schedule(function()
      sleep_seconds(0.4)
      basalt.stop()
    end)
  end)

  source_list:onSelect(function(_, index)
    if state.started then
      return
    end
    if type(index) == "number" and sources[index] ~= nil then
      active_index = index
      base = sources[index].base
      set_status(tr("app.ready"))
      set_source_title()
    end
  end)

  -- --------------------------------------------------------- first paint ---
  autostart_yes:onClick(function()
    if state.started then
      return
    end
    state.autostart = true
    render_autostart()
    set_detail(tr("app.autostart.pending_on"))
  end)

  autostart_no:onClick(function()
    if state.started then
      return
    end
    state.autostart = false
    render_autostart()
    set_detail(tr("app.autostart.pending_off"))
  end)

  render_autostart()
  set_source_title()
  set_status(tr("app.ready"))
  set_detail(tr("app.detail_ready"))
  set_progress(0)
  basalt.run()

  return { exit_code = 0 }
end

-- ---------------------------------------------------------------------------
-- app.run(deps)
-- ---------------------------------------------------------------------------

function app.run(deps)
  if type(deps) ~= "table" then
    deps = {}
  end
  local basalt = deps.basalt
  local installer = deps.installer
  local utf8display = deps.utf8display
  local log = type(deps.log) == "function" and deps.log or function() end

  if type(basalt) ~= "table" or type(installer) ~= "table" then
    log("installer_app: basalt and installer dependencies are required")
    return { exit_code = 1 }
  end

  local ok, result = pcall(run_view, deps, basalt, installer, utf8display, log)
  if ok and type(result) == "table" then
    return result
  end

  -- run_view raised: report it, make sure the event loop is stopped, and hand
  -- the caller a non-zero code so the bootstrap can fall back to plain text.
  log("installer_app: " .. tostring(result))
  pcall(basalt.stop)
  return { exit_code = 1 }
end

return app
