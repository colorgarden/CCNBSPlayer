-- installer.lua
--
-- THE ONE-CLICK INSTALLER.
--
-- Entry shape on a CC:Tweaked / CraftOS-PC computer:
--
--     wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua
--
-- It downloads the runtime files (the `nbs/`, `player/`, `net/`, `ui/` and
-- `vendor/` modules plus the root `ccnbs.lua` / `ccnbsplayer.lua` entry
-- programs) from the repository and places them so `require` resolves them
-- afterwards.
--
-- ===========================================================================
-- TWO MODES: INTERACTIVE (default) AND NON-INTERACTIVE (pinned)
-- ===========================================================================
-- On a real computer with HTTP enabled, running this file shows a plain-text
-- SOURCE MENU (so the user PICKS the download source), downloads the Basalt +
-- utf8display + ui/installer_app.lua bootstrap set, and then hands control to
-- that Basalt view, which shows the GUI, a progress bar and the install
-- buttons.  The whole install comes from the ONE chosen source.
--
-- When a source is pinned (`--mirror`, `--no-mirror`, an explicit base URL) or a
-- headless result file is requested (`result=`), the installer NEVER prompts:
-- that is the CI / acceptance-harness contract, and it keeps the original
-- install(ioenv) path exactly as it was.  installer.should_prompt() is the
-- single, tested decision point for this.
--
-- ===========================================================================
-- THE INSTALL ROOT: /lib/ -- AND WHY IT IS THE RIGHT CHOICE
-- ===========================================================================
-- `require` has NO fixed `/lib/` search root.  On the target, package.path is
--
--     ?;?.lua;?/init.lua;/rom/modules/main/?;...
--
-- and every `?` pattern resolves RELATIVE TO THE DIRECTORY OF THE RUNNING
-- PROGRAM -- `fs.getDir(<program path>)` (see the ROM's cc/require.lua:
-- `make_package(env, dir)` gives `searchpath` that base).  That is why a
-- root-level `ccnbs.lua` works: a program at `/` finds `/ccnbs.lua`.
--
-- `/lib/` is therefore not a magic search directory; it works because we put
-- EVERYTHING -- the modules AND the entry program -- under one root, and the
-- entry program is itself run from that root:
--
--     /lib/ccnbs.lua            require("ccnbs")
--     /lib/ccnbsplayer.lua      the program the user runs
--     /lib/nbs/*.lua            require("nbs.decode")     ...
--     /lib/player/*.lua         require("player.runtime") ...
--     /lib/net/*.lua            require("net.http")       ...
--     /lib/ui/*.lua             require("ui.basalt_app")  ...
--     /lib/vendor/*.lua         vendored Basalt / CJK bundles (loaded by the UI)
--
-- A program run as `/lib/ccnbsplayer` has dir == "/lib", so every nested
-- require resolves inside `/lib`.  A user's own script elsewhere can opt in
-- with:  package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
--
-- ===========================================================================
-- THE MANIFEST (installer.manifest) -- the file list is DATA, not code
-- ===========================================================================
-- A hand-maintained list of files to copy DRIFTS away from what the code
-- actually `require`s.  So the primary source of truth is a tiny text file in
-- the repository, `installer.manifest`, fetched FIRST from the same base and
-- parsed by installer.parse_manifest:
--
--   * one repository-relative path per line;
--   * blank lines are ignored;
--   * a line whose first non-space character is `#` is a comment;
--   * surrounding whitespace is trimmed and duplicates are dropped (order is
--     preserved);
--   * plain UTF-8/ASCII text -- NO JSON, NO quoting, no dependency.
--
-- A hard-coded FALLBACK list (installer.RUNTIME_FILES) is kept for a host where
-- the manifest cannot be fetched.  BOTH lists are held to the same drift guard
-- (tests/installer_manifest_spec.lua): the guard DERIVES what the runtime
-- requires by reading the runtime sources at test time and fails if either
-- list stops covering it.
--
-- ===========================================================================
-- LANGUAGE (a seam, not a renderer)
-- ===========================================================================
-- Every user-facing line lives in the local L10N table below, keyed by language
-- and selected from `pcall(require, "ui.i18n")` when that module is available --
-- exactly the pattern qa/ingame.lua already uses.  ENGLISH IS THE DEFAULT,
-- because a stock CC:Tweaked terminal ships no CJK font.  Nothing at a call
-- site hard-codes prose, so wiring the runtime-fetched CJK pixel-font renderer
-- later is a small change.  This file does NOT reference ui/cjk.lua or fetch
-- any font.
--
-- ===========================================================================
-- PURITY (verified by the test suite)
-- ===========================================================================
-- All decision logic is PURE and lives on the returned table: the file lists,
-- URL construction, target mapping, the install plan, the manifest parser, the
-- directory planner and the overwrite rules.  The only I/O routine,
-- install(ioenv), talks EXCLUSIVELY to the injected `ioenv.http` and `ioenv.fs`
-- -- never to the real globals -- so a unit test drives it with a fake
-- http/filesystem and NO real network.
--
-- ===========================================================================
-- IDEMPOTENCY / PROGRESS / SPACE / HONEST FAILURE
-- ===========================================================================
-- Re-running overwrites every managed file cleanly (fs.open(...,"wb") truncates)
-- and recreates missing directories.  The one thing it refuses to do is
-- overwrite a DIRECTORY that sits where a file must go -- that is reported
-- instead of silently destroying unrelated data.
--
--   * Progress: each file prints `N/M <name>` so a slow link is visibly alive.
--   * Space: fs.getFreeSpace is consulted before writing; a low-space install
--     fails with a clear message instead of leaving a half-written tree.
--   * Honest partial failure: if file K of M fails after retries, the message
--     names WHICH file, says the install is incomplete, and the process exits
--     non-zero.  Success is NEVER reported over a partial tree.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  The installer is the ONLY part
-- of the project that touches the network; the runtime never does.  No integer
-- division, no bitwise operators, no utf8.*, no os.exit, no os.execute.

local installer = {}

-- ===========================================================================
-- BOOTSTRAP SHIM: make `package` and `shell` reachable from chunks we load
-- ===========================================================================
-- WHY THIS EXISTS -- it is the difference between a working GUI and a silent
-- fall back to text.
--
-- A program started with `wget run` (or by the shell) receives `package` and
-- `shell` through its ENVIRONMENT, not as direct keys of the global table:
-- inside such a program `type(shell)` is "table" but `rawget(_G, "shell")` is
-- nil.  The vendored Basalt bundle is compiled with `_G` as its environment, so
-- it cannot see either one and dies on its first `package.path` access
-- ("attempt to index global 'package'").
--
-- Measured on CraftOS-PC, loading the real vendored bundle:
--     raw run     -> fail: basalt:58: attempt to index ...
--     shimmed run -> ok, returns the basalt table
--
-- This is exactly why the reference implementation (MPlayer) opens with the
-- same shim.  The difference here is that we COPY the real tables when they are
-- reachable, instead of substituting empty ones, so Basalt gets functioning
-- `shell.resolveProgram` etc. rather than stubs.
--
-- It must run at file scope, before anything is `load`ed.
do
  local real_package = package
  if type(rawget(_G, "package")) ~= "table" then
    _G.package = type(real_package) == "table" and real_package
      or { path = "rom/?.lua;rom/?/init.lua;", loaded = {} }
  end
  if type(_G.package.loaded) ~= "table" then
    _G.package.loaded = {}
  end
  if type(_G.package.path) ~= "string" then
    _G.package.path = "rom/?.lua;rom/?/init.lua;"
  end

  local real_shell = shell
  if type(rawget(_G, "shell")) ~= "table" then
    _G.shell = type(real_shell) == "table" and real_shell or {}
  end
  if type(_G.shell.getRunningProgram) ~= "function" then
    _G.shell.getRunningProgram = function()
      return "installer.lua"
    end
  end
  if type(_G.shell.resolveProgram) ~= "function" then
    _G.shell.resolveProgram = function(path)
      return path
    end
  end
end

-- The installed version.  Kept in lockstep with ccnbs.version.
installer.VERSION = "1.0.0"

-- Everything is installed under this root (see the header).
installer.INSTALL_ROOT = "/lib"

-- The repository-relative name of the manifest fetched before anything else.
installer.MANIFEST_NAME = "installer.manifest"

-- The default repository base.  `wget run <url>/installer.lua` fetches this
-- file from the same base, and the installer then fetches its siblings from
-- here.  Override it by passing a base URL argument (the dry-run test does).
installer.DEFAULT_BASE_URL =
  "https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main"

-- MIRROR SOURCES, tried IN ORDER.  `raw.githubusercontent.com` is frequently
-- unreachable from mainland China, so the installer can obtain the repository
-- through a mirror instead.
--
-- Every entry is a COMPLETE base URL, because file_url(base, path) simply
-- appends "/" .. path.  That one shape covers both kinds of mirror: pass-through
-- proxies that prefix the GitHub URL, and jsDelivr, which has its own
-- /gh/<owner>/<repo>@<branch> layout.
--
-- The FIRST entry is canonical GitHub and is always tried first, so a host that
-- can reach GitHub behaves EXACTLY as before and never touches a mirror.  The
-- rest are tried only when the ones before them fail.  The whole install comes
-- from whichever source answers first, never from a mixture.
--
-- jsDelivr is deliberately LAST because it is the only one that CACHES: it
-- serves a branch's content from a CDN cache for hours, so a commit made minutes
-- ago may not be visible through it.  A stale manifest would install an
-- out-of-date file list, which is why it is a last resort and not a first choice.
installer.MIRRORS = {
  { name = "github",   base = installer.DEFAULT_BASE_URL },
  { name = "ghproxy",  base = "https://ghproxy.net/" .. installer.DEFAULT_BASE_URL },
  { name = "ghfast",   base = "https://ghfast.top/" .. installer.DEFAULT_BASE_URL },
  { name = "gh-proxy", base = "https://gh-proxy.com/" .. installer.DEFAULT_BASE_URL },
  { name = "hkproxy",  base = "https://hk.gh-proxy.com/" .. installer.DEFAULT_BASE_URL },
  { name = "llkk",     base = "https://gh.llkk.cc/" .. installer.DEFAULT_BASE_URL },
  { name = "jsdelivr", base = "https://cdn.jsdelivr.net/gh/colorgarden/CCNBSPlayer@main" },
}

-- How many times a single fetch is attempted before it is declared failed.
installer.MAX_ATTEMPTS = 3

-- Seconds a BOOTSTRAP request may wait before it is abandoned.  The bootstrap
-- runs before Basalt exists, so it pumps events itself; this bound is what keeps
-- selecting a source against a dead host from hanging.
installer.BOOTSTRAP_TIMEOUT = 8

-- Refuse to start when the install root has less than this many bytes free.
-- The whole runtime is a few hundred KiB, so this is a coarse floor; the
-- per-file check below is the precise guard.
installer.MIN_FREE_BYTES = 65536

-- Keep this much headroom when checking a single file against free space.
installer.SPACE_MARGIN = 2048

-- ---------------------------------------------------------------------------
-- Autostart at boot (a ROOT /startup.lua, which CC runs at boot)
-- ---------------------------------------------------------------------------
-- `rom/startup.lua` (the shell) runs `findStartups("/")` after the MOTD when the
-- `shell.allow_startup` setting is on, and that resolves `/startup.lua` (or a
-- `/startup/` directory) via shell.resolveProgram.  So the file MUST live at the
-- root, exactly here.
--
-- The overriding rule is the SAFETY one: overwriting a user's existing
-- /startup.lua would destroy unrelated machine configuration, which is far worse
-- than not having autostart.  "ours" is therefore identified by a marker comment
-- and a foreign file is NEVER touched -- see installer.autostart_decision.
installer.AUTOSTART_PATH = "/startup.lua"

-- The marker that identifies OUR startup file on a later run: an idempotent
-- re-run can refresh it and "autostart off" can delete it, without ever touching
-- a file someone else wrote.  Detection is a plain substring test.
installer.AUTOSTART_MARKER = "CCNBSPlayer-autostart"

-- The EXACT bytes written to /startup.lua.  The marker appears verbatim (it is
-- what makes the overwrite/delete decision possible next run), and the fs.exists
-- guard means a user who later deletes the player does not get a boot error.
installer.AUTOSTART_BODY =
  "-- CCNBSPlayer 开机自启动 —— 删除本文件即可关闭\n"
  .. "-- 本文件由 CCNBSPlayer 安装器写入（" .. installer.AUTOSTART_MARKER .. "）\n"
  .. "if fs.exists(\"/lib/ccnbsplayer\") or fs.exists(\"/lib/ccnbsplayer.lua\") then\n"
  .. "  shell.run(\"/lib/ccnbsplayer\")\n"
  .. "end\n"

-- The FALLBACK file list, used only when the manifest cannot be fetched.  It is
-- the exact set a running install needs -- the runtime modules the code
-- `require`s plus the two entry programs -- and NOTHING else (no tests/**, no
-- scripts).  The drift guard asserts this list covers the derived requirement
-- set just as strictly as the manifest, because a stale fallback would be
-- worse than no fallback at all.
installer.RUNTIME_FILES = {
  "ccnbs.lua",
  "ccnbsplayer.lua",
  "updater.lua",
  "installer.lua",
  "nbs/analyze.lua",
  "nbs/cp1252.lua",
  "nbs/decode.lua",
  "nbs/header.lua",
  "nbs/instrument_table.lua",
  "nbs/instruments_custom.lua",
  "nbs/layers.lua",
  "nbs/notes.lua",
  "nbs/reader.lua",
  "nbs/speakers.lua",
  "player/clock.lua",
  "player/dispatch.lua",
  "player/fanout.lua",
  "player/mapping.lua",
  "player/plan.lua",
  "player/runtime.lua",
  "player/speaker.lua",
  "player/tempo.lua",
  "player/warnings.lua",
  "net/http.lua",
  "net/nbw.lua",
  "net/zip.lua",
  "ui/basalt_app.lua",
  "ui/cjk.lua",
  "ui/i18n.lua",
  "ui/installer_app.lua",
  "ui/presenter.lua",
  "vendor/basalt.lua",
  "vendor/utf8display.lua",
  "ui/icons.lua",
  "ui/settings.lua",
  "ui/history.lua",
  "ui/ime.lua",
  "ui/songs.lua",
  "ui/transport.lua",
  "ui/app_shell.lua",
  "ui/screens/frame.lua",
  "ui/screens/collection.lua",
  "ui/screens/home.lua",
  "ui/screens/browse.lua",
  "ui/screens/library.lua",
  "ui/screens/detail.lua",
  "ui/screens/nowplaying.lua",
  "ui/screens/queue.lua",
  "ui/screens/settings.lua",
  "ui/screens/about.lua",
  "ui/screens/help.lua",
  "vendor/mplayer-icons/Album.lua",
  "vendor/mplayer-icons/Discover.lua",
  "vendor/mplayer-icons/Favorite.lua",
  "vendor/mplayer-icons/Favorite1.lua",
  "vendor/mplayer-icons/Favorite2.lua",
  "vendor/mplayer-icons/Home.lua",
  "vendor/mplayer-icons/Like.lua",
  "vendor/mplayer-icons/List.lua",
  "vendor/mplayer-icons/Loading-circle.lua",
  "vendor/mplayer-icons/LoopPlay.lua",
  "vendor/mplayer-icons/LoopPlay2.lua",
  "vendor/mplayer-icons/Maximise.lua",
  "vendor/mplayer-icons/Menu.lua",
  "vendor/mplayer-icons/MusicalNote.lua",
  "vendor/mplayer-icons/NextSong.lua",
  "vendor/mplayer-icons/Pause.lua",
  "vendor/mplayer-icons/PauseCircle.lua",
  "vendor/mplayer-icons/PlayCircle.lua",
  "vendor/mplayer-icons/Podcast.lua",
  "vendor/mplayer-icons/PreviousSong.lua",
  "vendor/mplayer-icons/Recently.lua",
  "vendor/mplayer-icons/Roaming.lua",
  "vendor/mplayer-icons/Search.lua",
  "vendor/mplayer-icons/Settings.lua",
  "vendor/mplayer-icons/ShufflePlay.lua",
  "vendor/mplayer-icons/TrashCan.lua",
  "vendor/mplayer-icons/User.lua",
  "vendor/mplayer-icons/Volume.lua",
  "vendor/mplayer-icons/X.lua",
  "vendor/mplayer-icons/chevron-down.lua",
  "vendor/mplayer-icons/chevron-left.lua",
  "vendor/mplayer-icons/chevron-right.lua",
  "vendor/mplayer-icons/chevron-up.lua",
  "vendor/mplayer-icons/circle-filled.lua",
  "vendor/mplayer-icons/play.lua",
}

-- ---------------------------------------------------------------------------
-- Language: the local, keyed string table and the seam that selects a language
-- ---------------------------------------------------------------------------
-- Mirrors qa/ingame.lua: the active code comes from ui/i18n.lua when available,
-- otherwise English.  No call site hard-codes prose.  {named} placeholders are
-- substituted; a missing key returns the key itself so a gap is visible.

local L10N = {
  en = {
    ["installer.http_disabled"] =
      "Install failed: HTTP is disabled on this computer, so the installer "
      .. "cannot download the project files (http-disabled).\n"
      .. "Good news: HTTP is enabled by default on both platforms, so most "
      .. "users need no change.\n"
      .. "If it has been disabled, enable it and RESTART before retrying:\n"
      .. "  * CraftOS-PC emulator: edit <user data dir>/config/global.json and "
      .. "set http_enable to true;\n"
      .. "  * real CC:Tweaked server: edit computercraft-server.toml and set "
      .. "http.enabled to true;\n"
      .. "  * note: the tested CraftOS-PC 2.8.3 build IGNORES the -o / "
      .. "--option command-line flag, so editing the config file and restarting "
      .. "is the only thing that works.\n"
      .. "After HTTP is back, run the install command again.",
    ["installer.mkdir_failed"] =
      "Install failed: could not create the install directory (mkdir-failed): {dir}",
    ["installer.download_failed"] =
      "Install failed: could not download a file (download-failed): {url}{detail}"
      .. " [installed {installed}/{total}; the install is incomplete]",
    ["installer.write_failed"] =
      "Install failed: could not write a file (write-failed): {target}"
      .. " [installed {installed}/{total}; the install is incomplete]",
    ["installer.dir_refused"] =
      "Install failed: a directory already occupies a target path; refusing to "
      .. "overwrite it (dir-refused): {target} [installed {installed}/{total}]",
    ["installer.low_space_pre"] =
      "Install failed: not enough free space (low-space): {free} bytes free, "
      .. "at least {needed} required. Free some space and retry.",
    ["installer.low_space_file"] =
      "Install failed: not enough free space (low-space): {target} needs "
      .. "{needed} bytes but only {free} are free"
      .. " [installed {installed}/{total}; the install is incomplete]",
    ["installer.progress"] = "{index}/{total} {name}",
    ["installer.installed_file"] = "installed {path}",
    ["installer.retry"] =
      "download attempt {attempt}/{max} failed, retrying: {url}",
    ["installer.manifest_fallback"] =
      "manifest unavailable; using the built-in file list.",
    ["installer.mirror_try"] =
      "trying source {name}: {base}",
    ["installer.mirror_used"] =
      "using mirror {name}.",
    ["installer.mirror_next"] =
      "{name} did not answer; trying the next source.",
    ["installer.mirrors.title"] = "available sources (tried in this order):",
    ["installer.mirrors.entry"] = "  {index}. {name}  {base}",
    ["installer.choose.title"] = "Choose a download source (everything comes from ONE source):",
    ["installer.choose.auto"] = "  0. automatic - try each source in order",
    ["installer.choose.entry"] = "  {index}. {name}  {base}",
    ["installer.choose.prompt"] = "Enter a number (or a source name) [0 = automatic]: ",
    ["installer.choose.invalid"] = "Not a valid choice. Enter 0-{count} or a source name.",
    ["installer.choose.selected"] = "source: {name}  ({base})",
    ["installer.choose.checking"] = "checking {name} ...",
    ["installer.choose.reachable"] = "{name}: reachable.",
    ["installer.choose.unreachable"] = "{name}: no response; trying the next source.",
    ["installer.choose.no_input"] = "No interactive input available; using automatic mode.",
    ["installer.choose.auto_selected"] =
      "automatic mode: the first source that answers will be used.",
    ["installer.bootstrap.loading"] =
      "preparing the graphical installer from {base} ...",
    ["installer.bootstrap.failed"] =
      "could not prepare the graphical installer; falling back to the text installer.",
    ["installer.bootstrap.failed_named"] =
      "graphical installer bootstrap: {name} failed ({detail})",
    ["installer.autostart.write"] =
      "autostart: wrote /startup.lua (the player starts automatically at boot).",
    ["installer.autostart.overwrite"] =
      "autostart: refreshed our /startup.lua.",
    ["installer.autostart.delete"] =
      "autostart: removed our /startup.lua.",
    ["installer.autostart.skip-foreign"] =
      "autostart: /startup.lua was written by someone else, so it was left "
      .. "untouched. To enable autostart yourself, add this line to it: "
      .. "shell.run(\"/lib/ccnbsplayer\")",
    ["installer.autostart.none"] =
      "autostart: nothing to do (/startup.lua does not exist).",
    ["installer.autostart.no_fs"] =
      "autostart: the filesystem is unavailable; /startup.lua was not changed.",
    ["installer.autostart.failed"] =
      "autostart: could not update /startup.lua.",
    ["installer.usage.autostart"] =
      "  - --autostart: write /startup.lua so the player starts at boot",
    ["installer.usage.no_autostart"] =
      "  - --no-autostart: remove our /startup.lua (never a foreign one); the default",
    ["installer.banner.source"] = "downloaded from: {name}  ({base})",
    ["installer.banner.title"] = "========== CCNBSPlayer install complete ==========",
    ["installer.banner.version"] =
      "version: {version}  files installed: {installed}",
    ["installer.banner.usage"] = "usage: type  /lib/ccnbsplayer  in the shell",
    ["installer.banner.tip"] =
      "tip: put .nbs songs in the current directory, then pick one in the player.",
    ["installer.banner.footer"] = "===============================================",
    ["installer.banner.update"] = "to update later, run:  /lib/updater",
    ["installer.usage.title"] = "CCNBSPlayer installer v{version}",
    ["installer.usage.syntax"] =
      "usage: wget run <script url> [base url] [result=<file>]",
    ["installer.usage.base"] =
      "  - base url: overrides the default repository base ({default})",
    ["installer.usage.result"] =
      "  - result=: writes one install-result line to that file (headless acceptance)",
    ["installer.usage.mirror"] =
      "  - --mirror <name|url>: use ONLY that source (no automatic fallback); "
      .. "names: {names}",
    ["installer.usage.no_mirror"] =
      "  - --no-mirror: use only the canonical GitHub address, never a mirror",
    ["installer.usage.list_mirrors"] =
      "  - --list-mirrors: list the available sources and exit",
    ["installer.usage.location"] = "install location: {root}",
  },
  zh = {
    ["installer.http_disabled"] =
      "安装失败：本机未启用 HTTP，安装器无法下载项目文件 (http-disabled)。\n"
      .. "好消息：两个平台的 HTTP 默认都是开启的，绝大多数用户无需改动。\n"
      .. "若 HTTP 被人为关闭，请启用后重启再重试：\n"
      .. "  * CraftOS-PC 模拟器：编辑 <用户数据目录>/config/global.json，把 http_enable 设为 true；\n"
      .. "  * 真实 CC:Tweaked 服务器：编辑 computercraft-server.toml，把 http.enabled 设为 true；\n"
      .. "  * 注意：本模拟器构建会忽略 -o / --option 启动参数，改完配置文件后必须重启才生效。\n"
      .. "重启 HTTP 后，重新运行安装命令即可。",
    ["installer.mkdir_failed"] =
      "安装失败：无法创建安装目录 (mkdir-failed)：{dir}",
    ["installer.download_failed"] =
      "安装失败：下载文件失败 (download-failed)：{url}{detail}"
      .. "（已安装 {installed}/{total}，安装不完整）",
    ["installer.write_failed"] =
      "安装失败：写入文件失败 (write-failed)：{target}"
      .. "（已安装 {installed}/{total}，安装不完整）",
    ["installer.dir_refused"] =
      "安装失败：目标路径已被一个同名目录占用，拒绝覆盖 (dir-refused)：{target}"
      .. "（已安装 {installed}/{total}）",
    ["installer.low_space_pre"] =
      "安装失败：磁盘剩余空间不足 (low-space)：剩余 {free} 字节，至少需要 {needed} 字节。"
      .. "请清理空间后重试。",
    ["installer.low_space_file"] =
      "安装失败：磁盘剩余空间不足 (low-space)：{target} 需要 {needed} 字节，"
      .. "但仅剩 {free} 字节（已安装 {installed}/{total}，安装不完整）",
    ["installer.progress"] = "{index}/{total} {name}",
    ["installer.installed_file"] = "已安装 {path}",
    ["installer.retry"] =
      "下载第 {attempt}/{max} 次尝试失败，正在重试：{url}",
    ["installer.manifest_fallback"] =
      "无法获取清单文件，改用内置文件列表。",
    ["installer.mirror_try"] = "正在尝试来源 {name}：{base}",
    ["installer.mirror_used"] = "已使用镜像 {name}。",
    ["installer.mirror_next"] = "{name} 无响应，尝试下一个来源。",
    ["installer.mirrors.title"] = "可用来源（按此顺序依次尝试）：",
    ["installer.mirrors.entry"] = "  {index}. {name}  {base}",
    ["installer.choose.title"] = "请选择下载来源（整次安装只会用一个来源）：",
    ["installer.choose.auto"] = "  0. 自动——按顺序依次尝试各来源",
    ["installer.choose.entry"] = "  {index}. {name}  {base}",
    ["installer.choose.prompt"] = "输入编号（或来源名称）[0 = 自动]：",
    ["installer.choose.invalid"] = "无效选择，请输入 0-{count} 或来源名称。",
    ["installer.choose.selected"] = "来源：{name}（{base}）",
    ["installer.choose.checking"] = "正在检查 {name} ...",
    ["installer.choose.reachable"] = "{name}：可用。",
    ["installer.choose.unreachable"] = "{name}：无响应，尝试下一个来源。",
    ["installer.choose.no_input"] = "当前无法交互输入，改用自动模式。",
    ["installer.choose.auto_selected"] = "自动模式：将使用第一个能答上的来源。",
    ["installer.bootstrap.loading"] = "正在从 {base} 准备图形安装程序……",
    ["installer.bootstrap.failed"] = "无法准备图形安装程序，改用文本安装器。",
    ["installer.bootstrap.failed_named"] =
      "图形安装程序引导失败：{name} 出错（{detail}）",
    ["installer.autostart.write"] = "开机自启动：已写入 /startup.lua（开机自动运行播放器）。",
    ["installer.autostart.overwrite"] = "开机自启动：已更新本安装器写入的 /startup.lua。",
    ["installer.autostart.delete"] = "开机自启动：已删除本安装器写入的 /startup.lua。",
    ["installer.autostart.skip-foreign"] =
      "开机自启动：/startup.lua 是他人写入的，未做任何改动。若要自行启用，"
      .. "请在文件中加入这一行：shell.run(\"/lib/ccnbsplayer\")",
    ["installer.autostart.none"] = "开机自启动：无需处理（/startup.lua 不存在）。",
    ["installer.autostart.no_fs"] = "开机自启动：文件系统不可用，未改动 /startup.lua。",
    ["installer.autostart.failed"] = "开机自启动：无法更新 /startup.lua。",
    ["installer.usage.autostart"] = "  · --autostart：写入 /startup.lua，让播放器开机自动启动",
    ["installer.usage.no_autostart"] =
      "  · --no-autostart：删除本安装器写入的 /startup.lua（绝不碰他人的）；默认行为",
    ["installer.banner.source"] = "下载来源：{name}（{base}）",
    ["installer.banner.title"] = "========== CCNBSPlayer 安装完成 ==========",
    ["installer.banner.version"] =
      "版本：{version}　已安装文件：{installed}",
    ["installer.banner.usage"] = "用法：在 shell 里输入  /lib/ccnbsplayer",
    ["installer.banner.tip"] = "提示：把 .nbs 歌曲放到当前目录，运行播放器后用它选择曲目。",
    ["installer.banner.footer"] = "==========================================",
    ["installer.banner.update"] = "以后想更新：运行  /lib/updater",
    ["installer.usage.title"] = "CCNBSPlayer 安装器 v{version}",
    ["installer.usage.syntax"] = "用法：wget run <本脚本地址> [基础地址] [result=<结果文件>]",
    ["installer.usage.base"] =
      "  · 基础地址：覆盖默认仓库地址（默认 {default}）",
    ["installer.usage.result"] =
      "  · result=：把一行安装结果写入指定文件（用于无头验收）",
    ["installer.usage.mirror"] =
      "  · --mirror <名称|地址>：只用该来源，不再自动回退；可用名称：{names}",
    ["installer.usage.no_mirror"] = "  · --no-mirror：只使用 GitHub 官方地址，不使用镜像",
    ["installer.usage.list_mirrors"] = "  · --list-mirrors：列出所有可用来源后退出",
    ["installer.usage.location"] = "安装位置：{root}",
  },
}

installer.DEFAULT_LANGUAGE = "en"

-- The active language.  Module-level: the whole installer shares one UI language.
local active_language = installer.DEFAULT_LANGUAGE

-- Try to follow ui/i18n.lua (guarded: a host without it simply stays English).
local i18n = nil
do
  local ok_module, module = pcall(require, "ui.i18n")
  if ok_module and type(module) == "table"
    and type(module.get_language) == "function" then
    i18n = module
    local ok_code, code = pcall(module.get_language)
    if ok_code and type(code) == "string" and L10N[code] ~= nil then
      active_language = code
    end
  end
end

-- installer.languages() -> the sorted array of supported language codes.
function installer.languages()
  local codes = {}
  for code in pairs(L10N) do
    codes[#codes + 1] = code
  end
  table.sort(codes)
  return codes
end

-- installer.get_language() -> the active code.
function installer.get_language()
  return active_language
end

-- installer.set_language(code) -> true | false.  Never raises.  Also nudges
-- ui/i18n.lua so the whole program shares one language.
function installer.set_language(code)
  if type(code) ~= "string" or L10N[code] == nil then
    return false
  end
  active_language = code
  if i18n ~= nil and type(i18n.set_language) == "function" then
    pcall(i18n.set_language, code)
  end
  return true
end

-- Replace "{name}" placeholders from args, leaving an unmatched one intact so a
-- Lua nil can NEVER reach a printed line.  Plain byte gsub; no utf8.*.
local function substitute(text, args)
  if type(text) ~= "string" then
    return text
  end
  return (text:gsub("{([%w_]+)}", function(name)
    local value = args[name]
    if value == nil then
      return "{" .. name .. "}"
    end
    return tostring(value)
  end))
end

-- installer.tr(key, args) -> the sentence for `key` in the ACTIVE language.
-- Never raises and never returns nil: an unknown language falls back to English,
-- and an unknown key returns the key itself (a visible, greppable gap).
function installer.tr(key, args)
  local table_for_language = L10N[active_language] or L10N[installer.DEFAULT_LANGUAGE]
  local text = table_for_language[key]
  if type(text) ~= "string" then
    text = L10N[installer.DEFAULT_LANGUAGE][key]
  end
  if type(text) ~= "string" then
    return key
  end
  if type(args) ~= "table" then
    args = {}
  end
  return substitute(text, args)
end

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

-- installer.normalize_base(base) -> string.  Strips trailing slashes; an empty
-- or non-string base falls back to DEFAULT_BASE_URL.
function installer.normalize_base(base)
  if type(base) ~= "string" then
    return installer.DEFAULT_BASE_URL
  end
  local trimmed = base:gsub("/+$", "")
  if trimmed == "" then
    return installer.DEFAULT_BASE_URL
  end
  return trimmed
end

-- installer.file_url(base, path) -> string.  `path` is repo-relative.
function installer.file_url(base, path)
  return installer.normalize_base(base) .. "/" .. tostring(path)
end

-- installer.manifest_url(base) -> the URL the manifest is fetched from.
function installer.manifest_url(base)
  return installer.file_url(base, installer.MANIFEST_NAME)
end

-- installer.target_path(path) -> string.  Absolute destination on the computer.
function installer.target_path(path)
  return installer.INSTALL_ROOT .. "/" .. tostring(path)
end

-- installer.parent_dir(path) -> string.  The directory containing `path`.
function installer.parent_dir(path)
  local slash = tostring(path):match("^.*()/")
  if slash == nil or slash <= 1 then
    return "/"
  end
  return tostring(path):sub(1, slash - 1)
end

-- installer.parse_manifest(text) -> array of repo-relative paths.  Pure: reads
-- no files, fetches nothing.  The manifest format is documented in the header;
-- blank/comment lines are skipped, each path is trimmed, and duplicates are
-- dropped while ORDER IS PRESERVED.
function installer.parse_manifest(text)
  local paths = {}
  local seen = {}
  if type(text) ~= "string" then
    return paths
  end
  for raw_line in text:gmatch("[^\r\n]*") do
    local line = raw_line:gsub("^%s+", "")
    line = line:gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if not seen[line] then
        seen[line] = true
        paths[#paths + 1] = line
      end
    end
  end
  return paths
end

-- installer.install_dirs(files) -> array of directories, SHALLOW-FIRST so each
-- parent precedes its children.  Pure.  Derived from the files themselves, so a
-- new module directory can never be forgotten -- the install always creates the
-- parents of everything it is about to write.
function installer.install_dirs(files)
  if type(files) ~= "table" then
    files = installer.RUNTIME_FILES
  end
  local set = {}
  for index = 1, #files do
    local dir = installer.parent_dir(installer.target_path(files[index]))
    while dir ~= nil and dir ~= "/" and dir ~= "" do
      if set[dir] then
        break
      end
      set[dir] = true
      dir = installer.parent_dir(dir)
    end
  end
  local dirs = {}
  for dir in pairs(set) do
    dirs[#dirs + 1] = dir
  end
  table.sort(dirs, function(a, b)
    local depth_a = select(2, a:gsub("/", ""))
    local depth_b = select(2, b:gsub("/", ""))
    if depth_a ~= depth_b then
      return depth_a < depth_b
    end
    return a < b
  end)
  return dirs
end

-- installer.install_plan(base, files) -> array of {
--     repo_path, url, target, dir
--   }.  Pure: no I/O.  `files` defaults to the fallback list.
function installer.install_plan(base, files)
  if type(files) ~= "table" then
    files = installer.RUNTIME_FILES
  end
  local normalized = installer.normalize_base(base)
  local plan = {}
  for index = 1, #files do
    local path = files[index]
    local target = installer.target_path(path)
    plan[index] = {
      repo_path = path,
      url = normalized .. "/" .. path,
      target = target,
      dir = installer.parent_dir(target),
    }
  end
  return plan
end

-- installer.download_tasks(base, files) -> array of task tables, one per file.
--
-- A thin EXTENSION of installer.install_plan (never a re-implementation): it
-- adds the 1-based `index` and the `total`, because the Basalt view must render
-- `N/M <name>` while it walks the list ASYNCHRONOUSLY.  Building the task list
-- in ONE place keeps the view from re-deriving URLs, targets or directories,
-- which is exactly how the two install paths would silently drift apart.
function installer.download_tasks(base, files)
  local plan = installer.install_plan(base, files)
  local total = #plan
  for index = 1, total do
    plan[index].index = index
    plan[index].total = total
  end
  return plan
end

-- installer.should_overwrite(kind) -> "write" | "refuse".
--   "dir"  -> refuse (never clobber a directory)
--   "file" -> write (idempotent re-run; truncate + replace)
--   "none" -> write (fresh install)
--
-- install() calls this for EVERY target, so this is the SINGLE owner of the
-- overwrite decision; `kind` classifies whatever already sits at the target.
function installer.should_overwrite(kind)
  if kind == "dir" then
    return "refuse"
  end
  return "write"
end

-- installer.is_our_autostart(text) -> boolean.  PURE.  True only when the
-- content carries our marker; nil/foreign content is NOT ours, which is exactly
-- what makes "never clobber a stranger's startup file" enforceable.
function installer.is_our_autostart(text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  return text:find(installer.AUTOSTART_MARKER, 1, true) ~= nil
end

-- installer.autostart_decision(wants_autostart, exists, ours) ->
--   "write" | "overwrite" | "delete" | "skip-foreign" | "none".
--
-- PURE: no I/O, never raises.  The SINGLE owner of the autostart policy -- the
-- TUI and the non-interactive path both ask THIS, so they cannot disagree.
--
-- `wants_autostart` is TRI-STATE, and the distinction matters:
--   true  = the user asked for autostart
--   false = the user asked to turn it OFF
--   nil   = the user expressed NO PREFERENCE -> "none", change nothing
--
-- nil is NOT the same as false.  Reading nil as "off" made a non-interactive run
-- -- `/lib/updater`, say -- delete a /startup.lua the user had deliberately
-- enabled, so every update silently switched off their setting.  An installer
-- that was told nothing must assume nothing.
--
--   wants + no file          -> "write"
--   wants + OUR file         -> "overwrite"    (idempotent re-run)
--   wants + FOREIGN file     -> "skip-foreign" (NEVER clobber)
--   no wants + OUR file      -> "delete"       (off is a clean way to disable)
--   no wants + FOREIGN file  -> "skip-foreign" (NEVER touch)
--   no wants + no file       -> "none"
--   UNSET, anything at all   -> "none"         (leave the machine untouched)
function installer.autostart_decision(wants_autostart, exists, ours)
  if wants_autostart == nil then
    return "none"
  end
  if exists ~= true then
    if wants_autostart == true then
      return "write"
    end
    return "none"
  end
  if ours ~= true then
    return "skip-foreign"
  end
  if wants_autostart == true then
    return "overwrite"
  end
  return "delete"
end

-- installer.parse_args(argv) -> { base, mirror, no_mirror, list_mirrors,
--                                  result_path, help }.
--   * an argument containing "://" is the repository base URL
--   * `--mirror <name|url>` forces ONE source (no automatic fallback)
--   * `--no-mirror` restricts the install to the canonical GitHub address
--   * `--list-mirrors` prints the sources and exits
--   * `result=<path>` asks for a one-line harness result file
--   * `--autostart` / `--no-autostart` set boot autostart explicitly
--   * --help / -h / help prints usage
-- Anything unrecognised is ignored.
function installer.parse_args(argv)
  local parsed = {
    base = nil,
    mirror = nil,
    no_mirror = false,
    list_mirrors = false,
    result_path = nil,
    help = false,
    -- Tri-state: nil = UNSET (default OFF, never prompt on the non-interactive
    -- path), true = --autostart, false = --no-autostart.  When both flags are
    -- given the LAST one wins.
    autostart = nil,
  }
  if type(argv) ~= "table" then
    return parsed
  end
  for index = 1, #argv do
    local raw = argv[index]
    if type(raw) == "string" then
      if raw == "--help" or raw == "-h" or raw == "help" then
        parsed.help = true
      elseif raw == "--no-mirror" then
        parsed.no_mirror = true
      elseif raw == "--list-mirrors" then
        parsed.list_mirrors = true
      elseif raw == "--autostart" then
        parsed.autostart = true
      elseif raw == "--no-autostart" then
        parsed.autostart = false
      elseif raw == "--mirror" then
        -- A separate token: the next argument is the name or URL.
        local value = argv[index + 1]
        if type(value) == "string" and value ~= "" then
          parsed.mirror = value
        end
      elseif raw:sub(1, 9) == "--mirror=" then
        local value = raw:sub(10)
        if value ~= "" then
          parsed.mirror = value
        end
      elseif raw:sub(1, 7) == "result=" then
        parsed.result_path = raw:sub(8)
      elseif raw:find("://", 1, true) ~= nil then
        parsed.base = raw
      end
    end
  end
  return parsed
end

-- installer.autostart_requested(parsed) -> true | false | nil.
--
-- TRI-STATE, deliberately.  `nil` means the command line carried no autostart
-- flag: the user expressed NO PREFERENCE, and autostart_decision turns that into
-- "change nothing".
--
-- nil is NOT "off".  Collapsing unset to `false` here is exactly what made a
-- non-interactive run -- /lib/updater, for instance -- delete a /startup.lua the
-- user had enabled, so every update silently switched their setting off.  "Do not
-- enable by default" and "actively disable" are different instructions, and only
-- an explicit --no-autostart means the second one.
--
-- (In the interactive TUI the toggle starts OFF and the user chooses explicitly,
-- so that path passes a real boolean and is unaffected.)
function installer.autostart_requested(parsed)
  if type(parsed) ~= "table" then
    return nil
  end
  if parsed.autostart == true then
    return true
  end
  if parsed.autostart == false then
    return false
  end
  return nil
end

-- installer.find_mirror(name) -> the MIRRORS entry with that name, or nil.
function installer.find_mirror(name)
  if type(name) ~= "string" then
    return nil
  end
  for index = 1, #installer.MIRRORS do
    if installer.MIRRORS[index].name == name then
      return installer.MIRRORS[index]
    end
  end
  return nil
end

-- installer.sources_for(parsed) -> ordered array of { name, base }.
--
-- The one place that decides WHICH sources may be used and in what order:
--   * `--mirror <name>`  -> exactly that mirror (by name from MIRRORS)
--   * `--mirror <url>`   -> exactly that URL, named "custom"
--   * `--no-mirror`      -> only the canonical GitHub address
--   * default            -> every entry of MIRRORS, canonical first, so a host
--     that can reach GitHub behaves as if mirrors did not exist
-- An explicit `base` argument wins over all of it, because a caller that names
-- a base url means exactly that base.
function installer.sources_for(parsed)
  if type(parsed) ~= "table" then
    parsed = {}
  end
  if type(parsed.base) == "string" and parsed.base ~= "" then
    return { { name = "custom", base = installer.normalize_base(parsed.base) } }
  end
  if type(parsed.mirror) == "string" and parsed.mirror ~= "" then
    local known = installer.find_mirror(parsed.mirror)
    if known ~= nil then
      return { known }
    end
    if parsed.mirror:find("://", 1, true) ~= nil then
      return { { name = "custom", base = installer.normalize_base(parsed.mirror) } }
    end
    -- An unknown NAME is meaningless; fall through to the default chain rather
    -- than building a nonsense URL out of it.
  end
  if parsed.no_mirror then
    return { { name = "github", base = installer.DEFAULT_BASE_URL } }
  end
  local sources = {}
  for index = 1, #installer.MIRRORS do
    sources[index] = installer.MIRRORS[index]
  end
  return sources
end

-- installer.source_menu_lines(sources) -> array of strings.  PURE: it prints
-- nothing and reads nothing.  The interactive bootstrap prints these lines, so
-- the menu is a VALUE the tests can inspect rather than a side effect.
function installer.source_menu_lines(sources)
  if type(sources) ~= "table" or #sources == 0 then
    sources = installer.MIRRORS
  end
  local lines = {}
  lines[#lines + 1] = installer.tr("installer.choose.title")
  lines[#lines + 1] = installer.tr("installer.choose.auto")
  for index = 1, #sources do
    local entry = sources[index]
    lines[#lines + 1] = installer.tr("installer.choose.entry",
      { index = index, name = entry.name, base = entry.base })
  end
  lines[#lines + 1] = installer.tr("installer.choose.prompt")
  return lines
end

-- installer.parse_source_choice(text, count, names) -> 0 | 1..count | nil.
-- PURE.  "" means automatic (0); a number in range selects that entry; a source
-- NAME selects it case-insensitively; anything else is nil (the caller re-asks).
-- `names` defaults to installer.MIRRORS so the common case needs two arguments.
function installer.parse_source_choice(text, count, names)
  count = tonumber(count) or 0
  if type(text) ~= "string" then
    return nil
  end
  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return 0
  end

  local number = tonumber(trimmed)
  if number ~= nil then
    number = math.floor(number)
    if number == 0 then
      return 0
    end
    if number >= 1 and number <= count then
      return number
    end
    return nil
  end

  if type(names) ~= "table" then
    names = {}
    for index = 1, #installer.MIRRORS do
      names[index] = installer.MIRRORS[index].name
    end
  end
  local wanted = trimmed:lower()
  for index = 1, count do
    local name = names[index]
    if type(name) == "string" and name:lower() == wanted then
      return index
    end
  end
  return nil
end

-- installer.should_prompt(parsed, env) -> boolean.
--
-- The ONE place that decides whether the interactive menu runs.  A pinned base,
-- --mirror, --no-mirror or a headless result= is a CONTRACT, not a hint: the
-- installer must NOT prompt then, because CI has no keyboard.  Otherwise an
-- explicit env.interactive override wins, and the default is to prompt only on a
-- host that actually has HTTP and a way to read an answer.
--
-- It is deliberately pure: it inspects only `parsed` and `env`, so the whole
-- decision is unit-testable with no computer and no terminal.
function installer.should_prompt(parsed, env)
  parsed = type(parsed) == "table" and parsed or {}
  env = type(env) == "table" and env or {}

  if type(parsed.base) == "string" and parsed.base ~= "" then
    return false
  end
  if type(parsed.mirror) == "string" and parsed.mirror ~= "" then
    return false
  end
  if parsed.no_mirror == true then
    return false
  end
  if parsed.result_path ~= nil then
    return false
  end

  if env.interactive == false then
    return false
  end
  if env.interactive == true then
    return true
  end

  if type(env.http) ~= "function" then
    return false
  end
  if env.input ~= true then
    return false
  end
  return true
end

-- A one-line rendering of a possibly multi-line message.
function installer.one_line(text)
  return (tostring(text):gsub("[\r\n]+", " | "))
end

-- installer.install_dirs(RUNTIME_FILES), computed once for the fallback list.
-- Exposed for the tests and for documentation; install() recomputes it for the
-- ACTUAL list it settles on (manifest or fallback).
installer.INSTALL_DIRS = installer.install_dirs(installer.RUNTIME_FILES)

-- ---------------------------------------------------------------------------
-- Retry / space helpers (all seam-driven, never touching real globals)
-- ---------------------------------------------------------------------------

-- installer.fetch_with_retry(http, url, log, attempts) -> body, last_error.  Calls
-- the injected `http(url)` up to `attempts` times (defaulting to MAX_ATTEMPTS).
-- The FIRST non-nil body wins; otherwise the last error is returned.  Pure apart
-- from the injected `http`.  The optional `attempts` lets the BOOTSTRAP probe a
-- list of sources with a SINGLE bounded attempt each, so a dead host cannot make
-- the interactive menu appear to hang.
function installer.fetch_with_retry(http, url, log, attempts)
  attempts = tonumber(attempts) or installer.MAX_ATTEMPTS
  if attempts < 1 then
    attempts = 1
  end
  local last_error = nil
  for attempt = 1, attempts do
    local body, err = http(url)
    if body ~= nil then
      return body, nil
    end
    last_error = err
    if attempt < attempts and type(log) == "function" then
      log(installer.tr("installer.retry",
        { attempt = attempt, max = attempts, url = url }))
    end
  end
  return nil, last_error
end

-- installer.load_files(http, base, log) -> files, source.  Fetches and parses
-- the manifest from ONE base; on any failure returns the built-in fallback list.
-- `source` is "manifest" or "fallback".  Kept for single-source callers; the
-- multi-source path used by install() is load_files_from below.
function installer.load_files(http, base, log)
  local body = installer.fetch_with_retry(http, installer.manifest_url(base), log)
  if type(body) == "string" then
    local parsed = installer.parse_manifest(body)
    if #parsed > 0 then
      return parsed, "manifest"
    end
  end
  if type(log) == "function" then
    log(installer.tr("installer.manifest_fallback"))
  end
  return installer.RUNTIME_FILES, "fallback"
end

-- installer.load_files_from(sources, http, log, attempts) -> files, source, used.
--
-- Walks `sources` IN ORDER and stops at the first one that yields a usable
-- manifest.  `used` is the source that answered, so every later download comes
-- from the SAME host -- an install is never assembled from a mixture of mirrors,
-- which would otherwise be a way to get inconsistent file sets.
--
-- The optional `attempts` bounds how hard each source is tried (defaulting to
-- MAX_ATTEMPTS).  install() keeps the default; the interactive bootstrap passes
-- 1 so picking a source is a fast probe, not a long block.
--
-- `source` is "manifest" when a real manifest was read, or "fallback" when every
-- source failed and the built-in list stands in; in the fallback case `used` is
-- the FIRST source, because nothing answered and there is no better candidate.
function installer.load_files_from(sources, http, log, attempts)
  if type(sources) ~= "table" or #sources == 0 then
    sources = { { name = "github", base = installer.DEFAULT_BASE_URL } }
  end
  local say = type(log) == "function" and log or function() end

  for index = 1, #sources do
    local candidate = sources[index]
    say(installer.tr("installer.mirror_try",
      { name = candidate.name, base = candidate.base }))

    local body = installer.fetch_with_retry(
      http, installer.manifest_url(candidate.base), log, attempts)
    if type(body) == "string" then
      local parsed = installer.parse_manifest(body)
      if #parsed > 0 then
        if index > 1 then
          say(installer.tr("installer.mirror_used", { name = candidate.name }))
        end
        return parsed, "manifest", candidate
      end
    end

    if index < #sources then
      say(installer.tr("installer.mirror_next", { name = candidate.name }))
    end
  end

  say(installer.tr("installer.manifest_fallback"))
  return installer.RUNTIME_FILES, "fallback", sources[1]
end

-- installer.free_space(fs, path) -> number | nil.  nil means "unknown" (the
-- seam is absent or the host cannot answer), and every space check is skipped
-- rather than guessed.
function installer.free_space(fs, path)
  if type(fs) ~= "table" or type(fs.get_free_space) ~= "function" then
    return nil
  end
  local ok, value = pcall(fs.get_free_space, path)
  if ok and type(value) == "number" then
    return value
  end
  return nil
end

-- installer.write_one(fs, entry, body, ctx) -> { ok = true }
--                                          | { ok = false, code = <string>,
--                                              message = <string> }
--
-- The SINGLE-FILE half of install(): it writes ONE already-downloaded body to
-- its target.  Seam-driven (only the injected `fs` is touched) and it NEVER
-- raises -- a broken injected seam comes back as a typed failure.  This is the
-- writer the Basalt view calls, so the interactive path and the non-interactive
-- path cannot disagree about the overwrite policy, the space guard or the
-- wording of a refusal.
--
-- `entry` is a task from installer.install_plan / installer.download_tasks.
-- `ctx` is { installed = <n>, total = <n>, log = <fn|nil> }; `installed` is how
-- many files were already written, so a failure reports HONEST progress.
function installer.write_one(fs, entry, body, ctx)
  if type(fs) ~= "table" or type(entry) ~= "table" then
    return { ok = false, code = "write-failed", message = "write-failed" }
  end
  ctx = type(ctx) == "table" and ctx or {}
  local installed = tonumber(ctx.installed) or 0
  local total = tonumber(ctx.total) or 1
  local target = tostring(entry.target)

  -- Whatever already occupies the target is classified here, and the OVERWRITE
  -- POLICY is asked -- never re-implemented -- because installer.should_overwrite
  -- is its single owner.
  local existing_kind = "none"
  if type(fs.exists) == "function" and fs.exists(target) then
    if type(fs.is_dir) == "function" and fs.is_dir(target) then
      existing_kind = "dir"
    else
      existing_kind = "file"
    end
  end
  if installer.should_overwrite(existing_kind) == "refuse" then
    return {
      ok = false,
      code = "dir-refused",
      message = installer.tr("installer.dir_refused",
        { target = target, installed = installed, total = total }),
    }
  end

  -- The same precise per-file space check install() uses: never start a write
  -- that cannot finish.  An unknown free space (nil) skips the check.
  local free_here = installer.free_space(fs, entry.dir)
  if free_here ~= nil and free_here < (#body + installer.SPACE_MARGIN) then
    return {
      ok = false,
      code = "low-space",
      message = installer.tr("installer.low_space_file", {
        target = target,
        needed = #body + installer.SPACE_MARGIN,
        free = free_here,
        installed = installed,
        total = total,
      }),
    }
  end

  if type(fs.write) ~= "function" then
    return {
      ok = false,
      code = "write-failed",
      message = installer.tr("installer.write_failed",
        { target = target, installed = installed, total = total }),
    }
  end
  local wrote = fs.write(target, body)
  if wrote ~= true then
    return {
      ok = false,
      code = "write-failed",
      message = installer.tr("installer.write_failed",
        { target = target, installed = installed, total = total }),
    }
  end

  if type(ctx.log) == "function" then
    ctx.log(installer.tr("installer.installed_file", { path = target }))
  end
  return { ok = true }
end

-- installer.autostart_apply(fs, wants_autostart, ctx) -> { ok, code, message }.
--
-- The seam-driven action half of autostart: it reads whatever already sits at
-- /startup.lua through the INJECTED adapter (installer.wrap_fs's surface, never
-- a global), classifies it with is_our_autostart, asks autostart_decision, and
-- performs the single action the decision names.  NEVER raises -- a broken seam
-- comes back as a typed failure -- and NEVER touches a foreign file.
--
-- `code` is the decision ("write" / "overwrite" / "delete" / "skip-foreign" /
-- "none"), or "no-fs" / "write-failed" when the seam cannot perform it.
-- `message` is the localised sentence for the log / the TUI.
function installer.autostart_apply(fs, wants_autostart, ctx)
  ctx = type(ctx) == "table" and ctx or {}
  if type(fs) ~= "table" or type(fs.exists) ~= "function" then
    return {
      ok = false,
      code = "no-fs",
      message = installer.tr("installer.autostart.no_fs"),
    }
  end

  local path = installer.AUTOSTART_PATH

  local exists = false
  local ok_exists, value = pcall(fs.exists, path)
  if ok_exists and value == true then
    exists = true
  end

  local ours = false
  if exists and type(fs.read) == "function" then
    local ok_read, content = pcall(fs.read, path)
    if ok_read and type(content) == "string" then
      ours = installer.is_our_autostart(content)
    end
  end

  -- Pass the preference through UNCHANGED.  Coercing it to a boolean here would
  -- re-collapse "unset" into "off" and reintroduce the deleted-autostart bug.
  local decision = installer.autostart_decision(wants_autostart,
    exists, ours)

  if decision == "write" or decision == "overwrite" then
    local wrote = false
    if type(fs.write) == "function" then
      local ok_write, write_result = pcall(fs.write, path, installer.AUTOSTART_BODY)
      wrote = ok_write and write_result == true
    end
    if not wrote then
      return {
        ok = false,
        code = "write-failed",
        message = installer.tr("installer.autostart.failed"),
      }
    end
  elseif decision == "delete" then
    local removed = false
    if type(fs.delete) == "function" then
      local ok_delete, delete_result = pcall(fs.delete, path)
      removed = ok_delete and delete_result == true
    end
    if not removed then
      return {
        ok = false,
        code = "write-failed",
        message = installer.tr("installer.autostart.failed"),
      }
    end
  end

  return {
    ok = true,
    code = decision,
    message = installer.tr("installer.autostart." .. decision),
  }
end

-- ---------------------------------------------------------------------------
-- The filesystem adapter used by the real environment
-- ---------------------------------------------------------------------------

-- installer.wrap_fs(real_fs) -> adapter | nil.  Normalises CC:Tweaked's `fs`
-- API into the tiny surface install() needs.  Every call is pcall-guarded so a
-- host API quirk can never crash the installer with a raw traceback.
function installer.wrap_fs(real_fs)
  if type(real_fs) ~= "table" then
    return nil
  end
  local adapter = {}

  function adapter.exists(path)
    local ok, value = pcall(real_fs.exists, path)
    return ok and value == true
  end

  function adapter.is_dir(path)
    local ok, value = pcall(real_fs.isDir, path)
    return ok and value == true
  end

  function adapter.make_dir(path)
    if adapter.exists(path) and adapter.is_dir(path) then
      return true
    end
    local ok = pcall(real_fs.makeDir, path)
    if not ok then
      return false
    end
    return adapter.exists(path) and adapter.is_dir(path)
  end

  function adapter.write(path, body)
    local handle = nil
    local ok = pcall(function()
      handle = real_fs.open(path, "wb")
    end)
    if not ok or handle == nil then
      return false
    end
    local written = pcall(function()
      handle.write(body)
      handle.close()
    end)
    return written
  end

  function adapter.get_free_space(path)
    local ok, value = pcall(real_fs.getFreeSpace, path)
    if ok and type(value) == "number" then
      return value
    end
    return nil
  end

  -- read() is used by the autostart decision to tell OUR /startup.lua from a
  -- stranger's.  Returns the file body, or nil when it cannot be read (which the
  -- caller treats as "not ours", the safe default).
  function adapter.read(path)
    local handle = nil
    local ok = pcall(function()
      handle = real_fs.open(path, "r")
    end)
    if not ok or handle == nil then
      return nil
    end
    local data = nil
    local read_ok = pcall(function()
      data = handle.readAll()
      handle.close()
    end)
    if not read_ok or type(data) ~= "string" then
      return nil
    end
    return data
  end

  -- delete() is used only to remove OUR OWN /startup.lua.  A nil/false return is
  -- re-checked against exists(), so a host that reports success differently still
  -- gives an honest answer.
  function adapter.delete(path)
    local ok, value = pcall(real_fs.delete, path)
    if ok and value == true then
      return true
    end
    return not adapter.exists(path)
  end

  return adapter
end

-- ---------------------------------------------------------------------------
-- install(ioenv) -> result
-- ---------------------------------------------------------------------------

-- install(ioenv) performs the actual install through the injected seams.
-- See the header for the exact contract; the test suite verifies it.
function installer.install(ioenv)
  ioenv = ioenv or {}

  local http = ioenv.http
  if type(http) ~= "function" then
    return {
      ok = false,
      code = "http-disabled",
      message = installer.tr("installer.http_disabled"),
      installed = 0,
      total = 0,
    }
  end

  local fs = ioenv.fs
  if type(fs) ~= "table" then
    error("installer.install: ioenv.fs is required", 2)
  end

  -- WHICH SOURCES may be used, and in what order, is decided in ONE place.
  -- `ioenv.sources` lets a caller pin the chain; an injected `ioenv.base` is the
  -- older single-base contract and still wins, so existing callers are unaffected.
  local sources = ioenv.sources
  if type(sources) ~= "table" or #sources == 0 then
    if type(ioenv.base) == "string" and ioenv.base ~= "" then
      sources = { { name = "custom", base = installer.normalize_base(ioenv.base) } }
    else
      sources = installer.sources_for({})
    end
  end

  local log = ioenv.log
  if type(log) ~= "function" then
    log = function() end
  end

  -- The MANIFEST is the source of truth; the fallback only stands in when it
  -- cannot be fetched from ANY source.  Every later download uses the SAME
  -- source that answered, so an install is never a mixture of hosts.
  local files, source, used = installer.load_files_from(sources, http, log)
  local base = installer.normalize_base(used and used.base)
  local plan = installer.install_plan(base, files)
  local total = #plan

  -- Coarse space floor: refuse before writing a single byte when the target is
  -- hopeless, so a low-space host gets one clear message, not a broken tree.
  local free_at_root = installer.free_space(fs, installer.INSTALL_ROOT)
  if free_at_root ~= nil and free_at_root < installer.MIN_FREE_BYTES then
    return {
      ok = false,
      code = "low-space",
      message = installer.tr("installer.low_space_pre",
        { free = free_at_root, needed = installer.MIN_FREE_BYTES, total = total }),
      installed = 0,
      total = total,
    }
  end

  -- Directories first, shallow before deep, derived from the chosen file list.
  local dirs = installer.install_dirs(files)
  for index = 1, #dirs do
    local dir = dirs[index]
    if not fs.exists(dir) then
      local made = fs.make_dir(dir)
      if not made then
        return {
          ok = false,
          code = "write-failed",
          message = installer.tr("installer.mkdir_failed", { dir = dir }),
          installed = 0,
          total = total,
        }
      end
    end
  end

  local written = {}

  for index = 1, total do
    local entry = plan[index]

    -- The overwrite POLICY lives in ONE place -- installer.should_overwrite.
    -- Classify whatever already occupies the target ("none" / "file" / "dir")
    -- and let the policy decide.  A "refuse" (a directory sitting where a file
    -- must go) stops the install rather than destroying unrelated data; a
    -- "write" is the idempotent re-run / fresh install.
    local existing_kind = "none"
    if fs.exists(entry.target) then
      if fs.is_dir(entry.target) then
        existing_kind = "dir"
      else
        existing_kind = "file"
      end
    end
    if installer.should_overwrite(existing_kind) == "refuse" then
      return {
        ok = false,
        code = "dir-refused",
        message = installer.tr("installer.dir_refused",
          { target = entry.target, installed = #written, total = total }),
        installed = #written,
        total = total,
        failed_path = entry.repo_path,
      }
    end

    -- Progress: `N/M <name>` -- a slow link must visibly be alive.
    log(installer.tr("installer.progress",
      { index = index, total = total, name = entry.repo_path }))

    local body, fetch_error = installer.fetch_with_retry(http, entry.url, log)
    if body == nil then
      local detail = ""
      if fetch_error ~= nil then
        detail = "（" .. installer.one_line(fetch_error) .. "）"
      end
      return {
        ok = false,
        code = "http-failed",
        message = installer.tr("installer.download_failed", {
          url = entry.url,
          detail = detail,
          installed = #written,
          total = total,
        }),
        installed = #written,
        total = total,
        failed_path = entry.repo_path,
      }
    end

    -- The space guard and the write itself are shared with the interactive view
    -- through installer.write_one, so both paths refuse and space-check the same
    -- way and can never drift apart.
    local wrote = installer.write_one(fs, entry, body, {
      installed = #written,
      total = total,
      log = log,
    })
    if not wrote.ok then
      return {
        ok = false,
        code = wrote.code,
        message = wrote.message,
        installed = #written,
        total = total,
        failed_path = entry.repo_path,
      }
    end

    written[#written + 1] = entry.target
  end

  return {
    ok = true,
    code = "ok",
    installed = #written,
    total = total,
    source = source,
    mirror = used and used.name or nil,
    base = base,
    files = written,
  }
end

-- ---------------------------------------------------------------------------
-- Real environment, banner, usage, harness result
-- ---------------------------------------------------------------------------

-- installer.real_env() -> ioenv backed by the live CC:Tweaked globals.
--
-- `env.http` is the FETCH SEAM (`function(url) -> body, err`), never the raw
-- http API table: install() only accepts a function, and a nil here is exactly
-- how "HTTP is disabled on this computer" is detected.  The http API itself is
-- resolved LAZILY inside the closure, so a missing/disabled global yields nil
-- and the actionable http-disabled path.
function installer.real_env()
  local env = {}
  env.base = nil
  env.fs = installer.wrap_fs(rawget(_G, "fs"))
  env.log = function(text)
    local print_fn = rawget(_G, "print")
    if type(print_fn) == "function" then
      print_fn(text)
    else
      io.write(tostring(text) .. "\n")
    end
  end
  do
    local http_api = rawget(_G, "http")
    if type(http_api) == "table" and type(http_api.get) == "function" then
      env.http = function(url)
        local ok, response = pcall(http_api.get, url)
        if not ok or response == nil then
          return nil, "http.get failed"
        end
        local body = nil
        local read_ok = pcall(function()
          body = response.readAll()
        end)
        pcall(function()
          response.close()
        end)
        if not read_ok or type(body) ~= "string" then
          return nil, "http response unreadable"
        end
        return body
      end
    end
  end
  return env
end

-- installer.print_banner(env, result): the short success banner (language-keyed).
function installer.print_banner(env, result)
  local log = env.log
  if type(log) ~= "function" then
    log = function() end
  end
  log(installer.tr("installer.banner.title"))
  log(installer.tr("installer.banner.version",
    { version = installer.VERSION, installed = tostring(result.installed or 0) }))
  log(installer.tr("installer.banner.usage"))
  log(installer.tr("installer.banner.tip"))
  log(installer.tr("installer.banner.update"))
  if result ~= nil and result.mirror ~= nil and result.base ~= nil then
    log(installer.tr("installer.banner.source",
      { name = tostring(result.mirror), base = tostring(result.base) }))
  end
  log(installer.tr("installer.banner.footer"))
end

-- installer.mirror_names() -> comma-separated list of mirror names, for usage.
function installer.mirror_names()
  local names = {}
  for index = 1, #installer.MIRRORS do
    names[index] = installer.MIRRORS[index].name
  end
  return table.concat(names, ", ")
end

-- installer.print_mirrors(env): the ordered source list, for --list-mirrors.
function installer.print_mirrors(env)
  local log = (env and env.log) or function() end
  log(installer.tr("installer.mirrors.title"))
  for index = 1, #installer.MIRRORS do
    local entry = installer.MIRRORS[index]
    log(installer.tr("installer.mirrors.entry",
      { index = index, name = entry.name, base = entry.base }))
  end
end

-- installer.print_usage(env)
function installer.print_usage(env)
  local log = (env and env.log) or function() end
  log(installer.tr("installer.usage.title", { version = installer.VERSION }))
  log(installer.tr("installer.usage.syntax"))
  log(installer.tr("installer.usage.base", { default = installer.DEFAULT_BASE_URL }))
  log(installer.tr("installer.usage.mirror", { names = installer.mirror_names() }))
  log(installer.tr("installer.usage.no_mirror"))
  log(installer.tr("installer.usage.list_mirrors"))
  log(installer.tr("installer.usage.autostart"))
  log(installer.tr("installer.usage.no_autostart"))
  log(installer.tr("installer.usage.result"))
  log(installer.tr("installer.usage.location", { root = installer.INSTALL_ROOT }))
end

-- installer.write_result(env, path, result): a stable, machine-detectable
-- one-liner used by the headless dry run.  Never raises.
function installer.write_result(env, path, result)
  if type(env) ~= "table" or type(env.fs) ~= "table" then
    return false
  end
  local line = "INSTALLER status=" .. tostring(result.code)
    .. " ok=" .. tostring(result.ok == true)
    .. " installed=" .. tostring(result.installed or 0)
    .. " total=" .. tostring(result.total or 0)
    .. " version=" .. installer.VERSION
  if result.source ~= nil then
    line = line .. " source=" .. tostring(result.source)
  end
  if result.ok ~= true and result.message ~= nil then
    line = line .. " message=" .. installer.one_line(result.message)
  end
  local ok = pcall(env.fs.write, path, line .. "\n")
  return ok and true or false
end

-- ---------------------------------------------------------------------------
-- The interactive bootstrap: menu, bounded fetch, and the hand-off to the GUI
-- ---------------------------------------------------------------------------
-- `wget run <url>/installer.lua` puts ONLY installer.lua on the machine, so the
-- GUI cannot be `require`d -- it does not exist yet.  This phase therefore:
--
--   1. shows the SOURCE MENU in plain text and reads a choice (no network call
--      happens before the answer, so the menu itself can never hang),
--   2. resolves a manifest from the chosen source with a SINGLE bounded attempt
--      per source, so the whole install then comes from ONE host,
--   3. downloads the three bootstrap files (Basalt, utf8display, the view) and
--      load()s them,
--   4. hands control to ui/installer_app.lua.
--
-- Every step is guarded: if the GUI cannot be brought up, run_interactive()
-- returns nil and main() falls back to the plain-text installer, so a failed GUI
-- costs the user a GUI, never an install.

-- installer.read_seam(env) -> function() -> string | nil.  The read() seam: an
-- injected env.read wins, else the program's own `read` global, else _G.read.
-- (CC:Tweaked's basic globals such as read/sleep live in the program
-- environment; the bare reference finds them there, and rawget is a backstop.)
function installer.read_seam(env)
  if type(env) == "table" and type(env.read) == "function" then
    return env.read
  end
  local from_environment = read
  if type(from_environment) == "function" then
    return from_environment
  end
  local from_global = rawget(_G, "read")
  if type(from_global) == "function" then
    return from_global
  end
  return nil
end

-- installer.has_input(env) -> boolean.  True only when there is a way to read an
-- answer.  should_prompt() consumes this through env.input.
function installer.has_input(env)
  return installer.read_seam(env) ~= nil
end

-- installer.bootstrap_fetch(env) -> fetch | nil.  A ONE-ATTEMPT fetch function
-- (function(url) -> body, err) built on the ASYNCHRONOUS http.request plus an
-- os.startTimer watchdog.  Used only before Basalt exists.  Returns nil when the
-- raw HTTP API is unavailable, which makes main() use the plain path.
function installer.bootstrap_fetch(env)
  local http_api = rawget(_G, "http")
  local oslib = rawget(_G, "os")
  if type(http_api) ~= "table" or type(http_api.request) ~= "function" then
    return nil
  end
  if type(oslib) ~= "table"
    or type(oslib.pullEvent) ~= "function"
    or type(oslib.startTimer) ~= "function" then
    return nil
  end

  local timeout = installer.BOOTSTRAP_TIMEOUT
  if type(env) == "table" then
    timeout = tonumber(env.bootstrap_timeout) or timeout
  end

  return function(url)
    if type(url) ~= "string" or url == "" then
      return nil, "empty url"
    end

    local request_url = url
    if request_url:find("?", 1, true) ~= nil then
      request_url = request_url .. "&CCNBSBootstrap=1"
    else
      request_url = request_url .. "?CCNBSBootstrap=1"
    end

    local ok, accepted, request_error = pcall(http_api.request, {
      url = request_url,
      method = "GET",
      headers = { ["User-Agent"] = "CCNBSPlayer-Installer/1.0" },
      timeout = timeout,
    })
    if not ok or accepted == false then
      return nil, tostring(request_error or "http request rejected")
    end

    local timer = oslib.startTimer(timeout)
    while true do
      local event, first, second = oslib.pullEvent()
      if event == "http_success" and first == request_url then
        local read_ok, body = pcall(function()
          return second.readAll()
        end)
        pcall(function()
          second.close()
        end)
        if read_ok and type(body) == "string" then
          return body
        end
        return nil, "response unreadable"
      elseif event == "http_failure" and first == request_url then
        return nil, tostring(second or "network failure")
      elseif event == "timer" and first == timer then
        return nil, "timed out"
      end
    end
  end
end

-- installer.load_source(compile, source, name) -> value | nil, error.
--
-- Compiles fetched Lua source and runs it, returning whatever it produced.
--
-- It REPORTS its error rather than swallowing it.  An earlier version returned a
-- bare nil on any failure, which made a broken Basalt load indistinguishable
-- from a missing file: the GUI quietly fell back to the text installer and the
-- real cause ("attempt to index global 'package'") was never printed anywhere.
-- A bootstrap that cannot say why it failed is worse than one that crashes.
function installer.load_source(compile, source, name)
  if type(compile) ~= "function" then
    return nil, "no compiler available"
  end
  if type(source) ~= "string" then
    return nil, "no source to compile"
  end
  local chunk, compile_error = compile(source, name, "t", _G)
  if chunk == nil then
    return nil, "compile failed: " .. tostring(compile_error)
  end
  local ok, value = pcall(chunk)
  if ok then
    return value
  end
  return nil, "run failed: " .. tostring(value)
end

-- installer.choose_source(env, sources) -> sources', automatic.
-- Prints the menu (installer.source_menu_lines) and reads an answer through the
-- read seam until it is valid; an empty answer means automatic.  A pinned choice
-- returns a ONE-element list, so every later download is forced through it.
function installer.choose_source(env, sources)
  if type(sources) ~= "table" or #sources == 0 then
    sources = installer.MIRRORS
  end
  local log = function() end
  if type(env) == "table" and type(env.log) == "function" then
    log = env.log
  end
  local reader = installer.read_seam(env)
  if reader == nil then
    log(installer.tr("installer.choose.no_input"))
    return sources, true
  end

  local lines = installer.source_menu_lines(sources)
  for index = 1, #lines do
    log(lines[index])
  end
  local names = {}
  for index = 1, #sources do
    names[index] = sources[index].name
  end
  for _ = 1, 20 do
    local answer = reader()
    local choice = installer.parse_source_choice(answer, #sources, names)
    if choice == 0 then
      return sources, true
    end
    if choice ~= nil then
      return { sources[choice] }, false
    end
    log(installer.tr("installer.choose.invalid", { count = #sources }))
  end
  return sources, true
end

-- installer.run_interactive(parsed, env) -> result | nil.
-- The whole bootstrap.  Returns nil when the GUI cannot be prepared (no raw
-- HTTP, no load, a failed download, a failed compile), and main() then runs the
-- plain-text installer instead.
function installer.run_interactive(parsed, env)
  env = type(env) == "table" and env or {}
  local log = type(env.log) == "function" and env.log or function() end

  local sources = env.sources
  if type(sources) ~= "table" or #sources == 0 then
    sources = installer.sources_for(parsed)
  end

  local fetch = installer.bootstrap_fetch(env)
  if fetch == nil then
    return nil
  end

  local chosen, automatic = installer.choose_source(env, sources)
  if automatic then
    log(installer.tr("installer.choose.auto_selected"))
  end

  -- One bounded attempt per source here; the source that answers is then used
  -- for EVERY download, so an install is never assembled from two hosts.
  local files, source_kind, used = installer.load_files_from(chosen, fetch, log, 1)
  if type(files) ~= "table" or type(used) ~= "table"
    or type(used.base) ~= "string" then
    return nil
  end
  local origin = installer.normalize_base(used.base)
  log(installer.tr("installer.choose.selected",
    { name = used.name, base = origin }))

  local compile = rawget(_G, "load")
  if type(compile) ~= "function" then
    return nil
  end

  log(installer.tr("installer.bootstrap.loading", { base = origin }))
  local basalt_body = installer.fetch_with_retry(fetch,
    installer.file_url(origin, "vendor/basalt.lua"), log, 1)
  local utf8_body = installer.fetch_with_retry(fetch,
    installer.file_url(origin, "vendor/utf8display.lua"), log, 1)
  local app_body = installer.fetch_with_retry(fetch,
    installer.file_url(origin, "ui/installer_app.lua"), log, 1)
  if type(basalt_body) ~= "string" or type(utf8_body) ~= "string"
    or type(app_body) ~= "string" then
    log(installer.tr("installer.bootstrap.failed"))
    return nil
  end

  local basalt, basalt_error = installer.load_source(compile, basalt_body, "=basalt")
  local utf8display, utf8_error = installer.load_source(compile, utf8_body, "=utf8display")
  local app, app_error = installer.load_source(compile, app_body, "=installer_app")
  if type(basalt) ~= "table" or type(app) ~= "table"
    or type(app.run) ~= "function" then
    -- Say WHICH piece failed and why.  A bare "bootstrap failed" sent a real
    -- bug ("attempt to index global 'package'") into hiding for several rounds.
    if type(basalt) ~= "table" then
      log(installer.tr("installer.bootstrap.failed_named",
        { name = "Basalt", detail = tostring(basalt_error or "not a table") }))
    end
    if type(app) ~= "table" then
      log(installer.tr("installer.bootstrap.failed_named",
        { name = "installer_app", detail = tostring(app_error or "not a table") }))
    elseif type(app.run) ~= "function" then
      log(installer.tr("installer.bootstrap.failed_named",
        { name = "installer_app.run", detail = "missing" }))
    end
    if type(utf8display) ~= "table" then
      log(installer.tr("installer.bootstrap.failed_named",
        { name = "utf8display", detail = tostring(utf8_error or "not a table") }))
    end
    log(installer.tr("installer.bootstrap.failed"))
    return nil
  end

  local result = app.run({
    basalt = basalt,
    utf8display = utf8display,
    installer = installer,
    sources = chosen,
    base = origin,
    files = files,
    -- Pass the TRI-STATE through: true/false is an explicit command-line choice,
    -- nil means the user said nothing and the TUI must fall back to the disk state
    -- rather than assume OFF.  (Collapsing nil to false here is what made the GUI
    -- delete an autostart the user had enabled, merely because they re-ran the
    -- installer and left the toggle alone.)
    autostart = parsed.autostart,
    log = log,
  })

  local exit_code = 0
  if type(result) == "table" and type(result.exit_code) == "number" then
    exit_code = result.exit_code
  end
  return {
    ok = true,
    code = "tui",
    installed = #files,
    total = #files,
    source = source_kind,
    base = origin,
    exit_code = exit_code,
  }
end

-- ---------------------------------------------------------------------------
-- main(argv, ioenv)
-- ---------------------------------------------------------------------------

-- installer.main(argv, ioenv) -> result.  Parses arguments, installs, prints the
-- banner on success, and RAISES on failure so a non-interactive caller
-- (wget run / shell.run) sees a non-zero outcome.  `ioenv` defaults to the real
-- environment and may be injected in tests.
function installer.main(argv, ioenv)
  local parsed = installer.parse_args(argv)
  local env = ioenv
  if env == nil then
    env = installer.real_env()
  end

  if parsed.help then
    pcall(installer.print_usage, env)
    return { ok = true, code = "help", installed = 0, total = 0 }
  end

  if parsed.list_mirrors then
    pcall(installer.print_mirrors, env)
    return { ok = true, code = "list-mirrors", installed = 0, total = 0 }
  end

  -- Which sources may be used, and in what order.  install() honours ioenv.base
  -- as the older single-base contract, so sources_for() is only consulted when
  -- no explicit base was given.
  env.sources = installer.sources_for(parsed)
  env.base = parsed.base

  -- INTERACTIVE DEFAULT: on a real computer with HTTP and a keyboard, show the
  -- source menu and the Basalt GUI.  should_prompt() is the SINGLE decision, so
  -- a pinned --mirror / --no-mirror / base / result= (CI, the headless harness)
  -- still runs the plain path with NO prompt.
  env.input = installer.has_input(env)
  if installer.should_prompt(parsed, env) then
    local tui = installer.run_interactive(parsed, env)
    if tui ~= nil then
      if parsed.result_path ~= nil then
        installer.write_result(env, parsed.result_path, tui)
      end
      return tui
    end
    -- The GUI could not be prepared: fall through to the plain-text installer so
    -- a failed GUI never leaves the user with nothing.
  end

  local result = installer.install(env)

  if parsed.result_path ~= nil then
    installer.write_result(env, parsed.result_path, result)
  end

  if result.ok then
    -- Autostart is applied HERE only on the NON-INTERACTIVE path: the interactive
    -- TUI owns it (its toggle), and this branch is reached only when the GUI was
    -- skipped or could not start.  An unset flag means "no preference", so nothing
    -- on disk is changed -- a run that was told nothing must not disable a
    -- /startup.lua the user enabled earlier.  Only an explicit --no-autostart
    -- removes OUR file, and a foreign /startup.lua is never touched either way.
    local auto = installer.autostart_apply(env.fs,
      installer.autostart_requested(parsed), { log = env.log })
    if type(env.log) == "function" and auto.message ~= nil
      and auto.code ~= "none" then
      env.log(auto.message)
    end
    pcall(installer.print_banner, env, result)
    return result
  end

  if type(env.log) == "function" then
    env.log(result.message)
  end
  error(result.message, 0)
end

-- ---------------------------------------------------------------------------
-- Autorun
-- ---------------------------------------------------------------------------
-- Run as a program (wget run / shell) inside a real computer environment -- but
-- NOT when the file is merely `require`d by the desktop test runner.
--
-- `shell` is injected into each PROGRAM's environment, not into the global
-- table, so it cannot be probed with rawget(_G, ...).  `fs` IS a ROM global and
-- is the reliable "am I on a computer?" signal; `require` is detected instead by
-- its first argument (a bare module name such as "installer" or "lib.installer").
-- `__CCNBS_INSTALLER_NO_AUTORUN` is an explicit escape hatch.
do
  local first = (...)
  local looks_like_module_name = type(first) == "string"
    and first:match("^[%a_][%w_%.]*$") ~= nil
  local has_cc_env = type(rawget(_G, "fs")) == "table"
  local opted_out = rawget(_G, "__CCNBS_INSTALLER_NO_AUTORUN") == true
  if has_cc_env and not looks_like_module_name and not opted_out then
    installer.main({ ... }, installer.real_env())
  end
end

return installer
