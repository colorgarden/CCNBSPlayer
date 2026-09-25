-- installer.lua
--
-- THE ONE-CLICK INSTALLER.
--
-- Entry shape on a CC:Tweaked / CraftOS-PC computer:
--
--     wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua
--
-- It downloads the runtime files (the `nbs/`, `player/`, `net/` and `ui/`
-- modules plus the root `ccnbs.lua` / `ccnbsplayer.lua` entry programs) from
-- the repository and places them so `require` resolves them afterwards.
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
--     /lib/nbs/*.lua            require("nbs.decode")  ...
--     /lib/player/*.lua         require("player.tui")  ...
--     /lib/net/*.lua            require("net.http")    ...
--     /lib/ui/*.lua             require("ui.i18n")     ...
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

-- How many times a single fetch is attempted before it is declared failed.
installer.MAX_ATTEMPTS = 3

-- Refuse to start when the install root has less than this many bytes free.
-- The whole runtime is a few hundred KiB, so this is a coarse floor; the
-- per-file check below is the precise guard.
installer.MIN_FREE_BYTES = 65536

-- Keep this much headroom when checking a single file against free space.
installer.SPACE_MARGIN = 2048

-- The FALLBACK file list, used only when the manifest cannot be fetched.  It is
-- the exact set a running install needs -- the runtime modules the code
-- `require`s plus the two entry programs -- and NOTHING else (no tests/**, no
-- scripts).  The drift guard asserts this list covers the derived requirement
-- set just as strictly as the manifest, because a stale fallback would be
-- worse than no fallback at all.
installer.RUNTIME_FILES = {
  "ccnbs.lua",
  "ccnbsplayer.lua",
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
  "player/tui.lua",
  "player/warnings.lua",
  "net/http.lua",
  "net/nbw.lua",
  "net/zip.lua",
  "ui/i18n.lua",
  "ui/presenter.lua",
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
    ["installer.banner.title"] = "========== CCNBSPlayer install complete ==========",
    ["installer.banner.version"] =
      "version: {version}  files installed: {installed}",
    ["installer.banner.usage"] = "usage: type  /lib/ccnbsplayer  in the shell",
    ["installer.banner.tip"] =
      "tip: put .nbs songs in the current directory, then pick one in the player.",
    ["installer.banner.footer"] = "===============================================",
    ["installer.usage.title"] = "CCNBSPlayer installer v{version}",
    ["installer.usage.syntax"] =
      "usage: wget run <script url> [base url] [result=<file>]",
    ["installer.usage.base"] =
      "  - base url: overrides the default repository base ({default})",
    ["installer.usage.result"] =
      "  - result=: writes one install-result line to that file (headless acceptance)",
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
    ["installer.banner.title"] = "========== CCNBSPlayer 安装完成 ==========",
    ["installer.banner.version"] =
      "版本：{version}　已安装文件：{installed}",
    ["installer.banner.usage"] = "用法：在 shell 里输入  /lib/ccnbsplayer",
    ["installer.banner.tip"] = "提示：把 .nbs 歌曲放到当前目录，运行播放器后用它选择曲目。",
    ["installer.banner.footer"] = "==========================================",
    ["installer.usage.title"] = "CCNBSPlayer 安装器 v{version}",
    ["installer.usage.syntax"] = "用法：wget run <本脚本地址> [基础地址] [result=<结果文件>]",
    ["installer.usage.base"] =
      "  · 基础地址：覆盖默认仓库地址（默认 {default}）",
    ["installer.usage.result"] =
      "  · result=：把一行安装结果写入指定文件（用于无头验收）",
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

-- installer.parse_args(argv) -> { base, result_path, help }.
--   * an argument containing "://" is the repository base URL
--   * `result=<path>` asks for a one-line harness result file
--   * --help / -h / help prints usage
-- Anything unrecognised is ignored.
function installer.parse_args(argv)
  local parsed = { base = nil, result_path = nil, help = false }
  if type(argv) ~= "table" then
    return parsed
  end
  for index = 1, #argv do
    local raw = argv[index]
    if type(raw) == "string" then
      if raw == "--help" or raw == "-h" or raw == "help" then
        parsed.help = true
      elseif raw:sub(1, 7) == "result=" then
        parsed.result_path = raw:sub(8)
      elseif raw:find("://", 1, true) ~= nil then
        parsed.base = raw
      end
    end
  end
  return parsed
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

-- installer.fetch_with_retry(http, url, log) -> body, last_error.  Calls the
-- injected `http(url)` up to MAX_ATTEMPTS times.  The FIRST non-nil body wins;
-- otherwise the last error is returned.  Pure apart from the injected `http`.
function installer.fetch_with_retry(http, url, log)
  local attempts = installer.MAX_ATTEMPTS
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
-- the manifest; on any failure returns the built-in fallback list.  `source` is
-- "manifest" or "fallback".
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

  local log = ioenv.log
  if type(log) ~= "function" then
    log = function() end
  end

  local base = installer.normalize_base(ioenv.base)

  -- The MANIFEST is the source of truth; the fallback only stands in when it
  -- cannot be fetched.  `files` and `source` are recorded on the result.
  local files, source = installer.load_files(http, base, log)
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

    -- Precise per-file space check: never start a write that cannot finish.
    local free_here = installer.free_space(fs, entry.dir)
    if free_here ~= nil and free_here < (#body + installer.SPACE_MARGIN) then
      return {
        ok = false,
        code = "low-space",
        message = installer.tr("installer.low_space_file", {
          target = entry.target,
          needed = #body + installer.SPACE_MARGIN,
          free = free_here,
          installed = #written,
          total = total,
        }),
        installed = #written,
        total = total,
        failed_path = entry.repo_path,
      }
    end

    local ok = fs.write(entry.target, body)
    if not ok then
      return {
        ok = false,
        code = "write-failed",
        message = installer.tr("installer.write_failed",
          { target = entry.target, installed = #written, total = total }),
        installed = #written,
        total = total,
        failed_path = entry.repo_path,
      }
    end

    written[#written + 1] = entry.target
    log(installer.tr("installer.installed_file", { path = entry.target }))
  end

  return {
    ok = true,
    code = "ok",
    installed = #written,
    total = total,
    source = source,
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
  log(installer.tr("installer.banner.footer"))
end

-- installer.print_usage(env)
function installer.print_usage(env)
  local log = (env and env.log) or function() end
  log(installer.tr("installer.usage.title", { version = installer.VERSION }))
  log(installer.tr("installer.usage.syntax"))
  log(installer.tr("installer.usage.base", { default = installer.DEFAULT_BASE_URL }))
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

  env.base = parsed.base
  local result = installer.install(env)

  if parsed.result_path ~= nil then
    installer.write_result(env, parsed.result_path, result)
  end

  if result.ok then
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
