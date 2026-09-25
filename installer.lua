-- installer.lua
--
-- THE ONE-CLICK INSTALLER.
--
-- Entry shape on a CC:Tweaked / CraftOS-PC computer:
--
--     wget run https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main/installer.lua
--
-- It downloads the runtime files (the `nbs/` and `player/` modules plus the
-- root `ccnbs.lua` and `ccnbsplayer.lua`) from the repository and places them
-- so `require` resolves them afterwards.
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
--
-- A program run as `/lib/ccnbsplayer` has dir == "/lib", so every nested
-- require resolves inside `/lib`.  A user's own script elsewhere can opt in
-- with:  package.path = "/lib/?.lua;/lib/?/init.lua;" .. package.path
--
-- ===========================================================================
-- PURITY (for tests/installer_spec.lua)
-- ===========================================================================
-- All decision logic is PURE and lives on the returned table: the file list,
-- URL construction, target mapping, the install plan and the overwrite rules.
-- The only I/O routine, install(ioenv), talks EXCLUSIVELY to the injected
-- `ioenv.http` and `ioenv.fs` -- never to the real globals -- so a unit test
-- drives it with a fake http/filesystem and NO real network.
--
-- ===========================================================================
-- IDEMPOTENCY
-- ===========================================================================
-- Re-running overwrites every managed file cleanly (fs.open(...,"wb") truncates)
-- and recreates missing directories.  The one thing it refuses to do is
-- overwrite a DIRECTORY that sits where a file must go -- that is reported
-- instead of silently destroying unrelated data.  It never writes outside its
-- own target paths and never touches the file the user is currently running.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  The installer is the ONLY part
-- of the project that touches the network; the runtime never does.  No integer
-- division, no bitwise operators, no utf8.*, no os.exit, no os.execute.

local installer = {}

-- The installed version.  Kept in lockstep with ccnbs.version.
installer.VERSION = "1.0.0"

-- Everything is installed under this root (see the header).
installer.INSTALL_ROOT = "/lib"

-- The directories created before any file is written, SHALLOW-FIRST so each
-- parent exists before its child.
installer.INSTALL_DIRS = {
  "/lib",
  "/lib/nbs",
  "/lib/player",
}

-- Where the runtime lives, relative to the install root.  This is the exact set
-- of files a running install needs; nothing else is fetched.
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
}

-- The default repository base.  `wget run <url>/installer.lua` fetches this
-- file from the same base, and the installer then fetches its siblings from
-- here.  Override it by passing a base URL argument (the dry-run test does).
installer.DEFAULT_BASE_URL =
  "https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main"

-- All user-facing failure text.  Chinese, actionable, and each carries a
-- stable ASCII token so downstream tooling can match it.
installer.MESSAGES = {
  HTTP_DISABLED =
    "安装失败：本机未启用 HTTP，安装器无法下载项目文件。\n"
    .. "请先在服务器端启用 HTTP（(http-disabled)）：\n"
    .. "  * Minecraft 服务器：编辑 computercraft-server.toml，把 http.enable = true（或在新版里设置 http_enable）；\n"
    .. "  * CraftOS-PC 模拟器：启动参数加 -o http_enable=true。\n"
    .. "启用 HTTP 后，重新运行安装命令即可。",
  MKDIR_FAILED_PREFIX = "安装失败：无法创建安装目录 (mkdir-failed)：",
  DOWNLOAD_FAILED_PREFIX = "安装失败：下载文件失败 (download-failed)：",
  WRITE_FAILED_PREFIX = "安装失败：写入文件失败 (write-failed)：",
  DIR_REFUSED_PREFIX =
    "安装失败：目标路径已被一个同名目录占用，拒绝覆盖 (dir-refused)：",
}

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

-- installer.install_plan(base) -> array of {
--     repo_path, url, target, dir
--   }.  Pure: no I/O.
function installer.install_plan(base)
  local normalized = installer.normalize_base(base)
  local plan = {}
  for index = 1, #installer.RUNTIME_FILES do
    local path = installer.RUNTIME_FILES[index]
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

  return adapter
end

-- ---------------------------------------------------------------------------
-- install(ioenv) -> result
-- ---------------------------------------------------------------------------

-- install(ioenv) performs the actual install through the injected seams.
-- See the header and tests/installer_spec.lua for the exact contract.
function installer.install(ioenv)
  ioenv = ioenv or {}

  local http = ioenv.http
  if type(http) ~= "function" then
    return {
      ok = false,
      code = "http-disabled",
      message = installer.MESSAGES.HTTP_DISABLED,
      installed = 0,
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
  local plan = installer.install_plan(base)

  -- Directories first, shallow before deep.
  for index = 1, #installer.INSTALL_DIRS do
    local dir = installer.INSTALL_DIRS[index]
    if not fs.exists(dir) then
      local made = fs.make_dir(dir)
      if not made then
        return {
          ok = false,
          code = "write-failed",
          message = installer.MESSAGES.MKDIR_FAILED_PREFIX .. dir,
          installed = 0,
        }
      end
    end
  end

  local written = {}

  for index = 1, #plan do
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
        message = installer.MESSAGES.DIR_REFUSED_PREFIX .. entry.target,
        installed = #written,
      }
    end

    local body, fetch_error = http(entry.url)
    if body == nil then
      local detail = ""
      if fetch_error ~= nil then
        detail = "（" .. installer.one_line(fetch_error) .. "）"
      end
      return {
        ok = false,
        code = "http-failed",
        message = installer.MESSAGES.DOWNLOAD_FAILED_PREFIX .. entry.url .. detail,
        installed = #written,
      }
    end

    local ok = fs.write(entry.target, body)
    if not ok then
      return {
        ok = false,
        code = "write-failed",
        message = installer.MESSAGES.WRITE_FAILED_PREFIX .. entry.target,
        installed = #written,
      }
    end

    written[#written + 1] = entry.target
    log("已安装 " .. entry.target)
  end

  return { ok = true, code = "ok", installed = #written, files = written }
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

-- installer.print_banner(env, result): the short Chinese success banner.
function installer.print_banner(env, result)
  local log = env.log
  if type(log) ~= "function" then
    log = function() end
  end
  log("========== CCNBSPlayer 安装完成 ==========")
  log("版本：" .. installer.VERSION .. "　已安装文件：" .. tostring(result.installed))
  log("用法：在 shell 里输入  /lib/ccnbsplayer")
  log("提示：把 .nbs 歌曲放到当前目录，运行播放器后用它选择曲目。")
  log("==========================================")
end

-- installer.print_usage(env)
function installer.print_usage(env)
  local log = (env and env.log) or function() end
  log("CCNBSPlayer 安装器 v" .. installer.VERSION)
  log("用法：wget run <本脚本地址> [基础地址] [result=<结果文件>]")
  log("  · 基础地址：覆盖默认仓库地址（默认 " .. installer.DEFAULT_BASE_URL .. "）")
  log("  · result=：把一行安装结果写入指定文件（用于无头验收）")
  log("安装位置：" .. installer.INSTALL_ROOT)
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
    .. " version=" .. installer.VERSION
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
    return { ok = true, code = "help", installed = 0 }
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
