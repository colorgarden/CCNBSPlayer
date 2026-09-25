-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 colorgarden
-- Part of CCNBSPlayer. Licensed under GPL-2.0; see LICENSE.
--
-- updater.lua
--
-- THE ONE-COMMAND UPDATER.  Run it in a computer's shell:
--
--   /lib/updater
--
-- It answers one question -- "is this install behind the repository?" -- and, if
-- it is, refreshes the install by driving installer.install() with the newest
-- file list.
--
-- ===========================================================================
-- WHY IT PARSES A VERSION AND DOES NOT FETCH ONE FILE CALLED "version"
-- ===========================================================================
-- The version lives in exactly ONE place: `installer.VERSION` in installer.lua.
-- A separate `version` file would be a second copy that can drift from the code
-- it describes, and a stale version file makes an updater confidently wrong.
--
-- So the remote version is read by fetching the REMOTE installer.lua and
-- extracting its `installer.VERSION = "..."` line -- the same technique MPlayer
-- uses, for the same reason.  A unit test asserts that parsing the shipped
-- installer.lua yields exactly the version that installer.lua itself reports, so
-- the extraction cannot silently break when the file is edited.
--
-- ===========================================================================
-- WHY IT REUSES installer.lua RATHER THAN REIMPLEMENTING ANYTHING
-- ===========================================================================
-- installer.lua is always installed beside this file, and it already owns the
-- hard parts: the MIRRORS chain, the manifest format, retry, the filesystem
-- adapter, the overwrite policy, language selection and the user-facing prose.
-- This module adds ONLY what is specific to updating: comparing two versions and
-- deciding whether to install.  It writes no files itself -- installer.install()
-- is the single writer, so "update" and "install" can never disagree about what
-- a correct install looks like.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt, same subset as the rest of the
-- project (no `//`, no bitwise operators, no utf8.*, no collectgarbage, no
-- string.dump, no os.exit).

local installer = require("installer")

local updater = {}

updater.VERSION = "1.0.0"

-- ---------------------------------------------------------------------------
-- Result codes
-- ---------------------------------------------------------------------------
--   "up-to-date"        the installed version equals the repository's
--   "update-available"  the repository is ahead; run() will install it
--   "newer-installed"   the install is AHEAD of the repository (a local build)
--   "unknown"           a version could not be read from one side
--   "ok"                an install was performed and finished
--   plus every failure code installer.install() can return.

-- ---------------------------------------------------------------------------
-- Localisation -- the same shape as installer.lua's L10N, so both programs
-- speak with one voice and follow ui/i18n.lua when it is present.
-- ---------------------------------------------------------------------------

local L10N = {
  en = {
    ["updater.title"] = "CCNBSPlayer updater v{version}",
    ["updater.local"] = "installed version: {version}",
    ["updater.remote"] = "repository version: {version} ({name})",
    ["updater.up_to_date"] = "Already up to date. Nothing to do.",
    ["updater.available"] =
      "An update is available: {local} -> {remote}. Installing it now.",
    ["updater.newer"] =
      "The installed version ({local}) is AHEAD of the repository ({remote}). "
      .. "This is a local or development build, so nothing is changed.",
    ["updater.unknown"] =
      "Could not determine both versions, so no update decision was made. "
      .. "Re-running the installer is always safe; use installer.lua if you "
      .. "want to force a refresh.",
    ["updater.trying_next"] = "{name} did not answer; trying the next source.",
    ["updater.no_http"] =
      "Cannot check for updates: HTTP is disabled on this computer. "
      .. "See installer.lua for how to enable it.",
    ["updater.done"] = "Update complete.",
    ["updater.failed"] = "Update failed: {message}",
    ["updater.usage.title"] = "CCNBSPlayer updater v{version}",
    ["updater.usage.syntax"] = "usage: /lib/updater [--check] [--mirror <name|url>] [--no-mirror]",
    ["updater.usage.check"] = "  - --check: report whether an update exists, change nothing",
    ["updater.usage.mirror"] =
      "  - --mirror <name|url>: use ONLY that source; names: {names}",
    ["updater.usage.no_mirror"] = "  - --no-mirror: use only the canonical GitHub address",
    ["updater.usage.list_mirrors"] = "  - --list-mirrors: list the available sources and exit",
  },
  zh = {
    ["updater.title"] = "CCNBSPlayer 更新器 v{version}",
    ["updater.local"] = "已安装版本：{version}",
    ["updater.remote"] = "仓库版本：{version}（{name}）",
    ["updater.up_to_date"] = "已是最新版本，无需操作。",
    ["updater.available"] = "发现新版本：{local} → {remote}，现在开始更新。",
    ["updater.newer"] =
      "已安装版本（{local}）高于仓库版本（{remote}）。这是本地/开发构建，不做任何改动。",
    ["updater.unknown"] =
      "无法同时取得两个版本号，因此没有做更新判断。重新运行安装器始终是安全的；"
    .. "若想强制刷新，请使用 installer.lua。",
    ["updater.trying_next"] = "{name} 无响应，尝试下一个来源。",
    ["updater.no_http"] = "无法检查更新：本机未启用 HTTP。启用方法见 installer.lua。",
    ["updater.done"] = "更新完成。",
    ["updater.failed"] = "更新失败：{message}",
    ["updater.usage.title"] = "CCNBSPlayer 更新器 v{version}",
    ["updater.usage.syntax"] = "用法：/lib/updater [--check] [--mirror <名称|地址>] [--no-mirror]",
    ["updater.usage.check"] = "  · --check：只报告是否有新版本，不做任何改动",
    ["updater.usage.mirror"] = "  · --mirror <名称|地址>：只用该来源；可用名称：{names}",
    ["updater.usage.no_mirror"] = "  · --no-mirror：只使用 GitHub 官方地址",
    ["updater.usage.list_mirrors"] = "  · --list-mirrors：列出所有可用来源后退出",
  },
}

-- The active language is NOT tracked separately here.  installer.lua already
-- owns it: it follows ui/i18n.lua when present and falls back to English, and
-- updater.tr() asks installer.get_language() every time.  One owner, so the two
-- programs can never display different languages in the same session.

-- updater.tr(key, args) -> the sentence for `key` in the ACTIVE language.
function updater.tr(key, args)
  local code = "en"
  if type(installer.get_language) == "function" then
    local ok, value = pcall(installer.get_language)
    if ok and type(value) == "string" then
      code = value
    end
  end
  local table_for_language = L10N[code] or L10N.en
  local text = table_for_language[key] or L10N.en[key]
  if type(text) ~= "string" then
    return tostring(key)
  end
  if type(args) == "table" then
    for name, value in pairs(args) do
      text = text:gsub("{" .. tostring(name) .. "}", tostring(value))
    end
  end
  return text
end

-- ---------------------------------------------------------------------------
-- PURE version logic -- no I/O, fully unit-testable
-- ---------------------------------------------------------------------------

-- updater.parse_version(text) -> version string | nil.
--
-- Extracts the value of `installer.VERSION = "..."` from Lua SOURCE TEXT.  This
-- is deliberately tolerant of surrounding whitespace and of the assignment being
-- spelled `installer.VERSION` or `updater.VERSION`; it reads the FIRST such
-- assignment, which is the declaration near the top of both files.
function updater.parse_version(text)
  if type(text) ~= "string" then
    return nil
  end
  local found = text:match("[%a_][%w_]*%.VERSION%s*=%s*\"([^\"]+)\"")
  if type(found) == "string" and found ~= "" then
    return found
  end
  return nil
end

-- updater.split_version(text) -> array of numbers.  "1.2.3" -> {1,2,3}.
-- A non-numeric component becomes 0 rather than raising, so a malformed version
-- degrades instead of crashing the updater.
function updater.split_version(text)
  local parts = {}
  if type(text) ~= "string" then
    return parts
  end
  for piece in text:gmatch("[^%.]+") do
    local number = tonumber(piece)
    if number == nil then
      number = 0
    end
    parts[#parts + 1] = number
  end
  return parts
end

-- updater.compare_versions(a, b) -> -1 | 0 | 1.
-- Numeric, component-wise, so "1.10.0" is correctly NEWER than "1.9.0" (a string
-- comparison would get that backwards).  Missing trailing components count as 0,
-- so "1.0" and "1.0.0" compare EQUAL.  Returns nil when either side is not a
-- usable version string.
function updater.compare_versions(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then
    return nil
  end
  if a == "" or b == "" then
    return nil
  end
  local left = updater.split_version(a)
  local right = updater.split_version(b)
  if #left == 0 or #right == 0 then
    return nil
  end
  local length = #left
  if #right > length then
    length = #right
  end
  for index = 1, length do
    local x = left[index] or 0
    local y = right[index] or 0
    if x < y then
      return -1
    end
    if x > y then
      return 1
    end
  end
  return 0
end

-- updater.decide(local_version, remote_version) -> code.
-- Pure mapping from the two version strings to one of the outcome codes above.
-- "unknown" whenever either side is missing, because guessing would be worse
-- than saying nothing: a wrong "up to date" would silently strand a user.
function updater.decide(local_version, remote_version)
  if type(remote_version) ~= "string" or remote_version == "" then
    return "unknown"
  end
  if type(local_version) ~= "string" or local_version == "" then
    return "unknown"
  end
  local order = updater.compare_versions(local_version, remote_version)
  if order == nil then
    return "unknown"
  end
  if order < 0 then
    return "update-available"
  end
  if order > 0 then
    return "newer-installed"
  end
  return "up-to-date"
end

-- ---------------------------------------------------------------------------
-- Reading the REMOTE version -- uses the installer's own mirror chain
-- ---------------------------------------------------------------------------

-- updater.remote_probe(sources, http, log) -> { version = ..., name = ...,
--                                                base = ... } | nil, error.
-- Fetches the remote installer.lua from the first source that answers and
-- extracts its version.  The source that answered is returned too, so the
-- subsequent install downloads from THE SAME host.
function updater.remote_probe(sources, http, log)
  if type(sources) ~= "table" or #sources == 0 then
    return nil, "no sources"
  end
  local say = type(log) == "function" and log or function() end

  for index = 1, #sources do
    local candidate = sources[index]
    local body = installer.fetch_with_retry(http,
      installer.file_url(candidate.base, "installer.lua"), log)
    if type(body) == "string" then
      local version = updater.parse_version(body)
      if version ~= nil then
        return {
          version = version,
          name = candidate.name,
          base = candidate.base,
        }
      end
    end
    if index < #sources then
      say(updater.tr("updater.trying_next", { name = candidate.name }))
    end
  end
  return nil, "no source yielded a version"
end

-- updater.local_version() -> the version THIS install reports.
-- Read from the installed installer.lua, which is the single source of truth.
function updater.local_version()
  return installer.VERSION
end

-- ---------------------------------------------------------------------------
-- check(opts) -- decide, changing nothing
-- ---------------------------------------------------------------------------
-- updater.check(opts) -> {
--     ok = <bool>, code = <string>,
--     local_version = <string|nil>, remote_version = <string|nil>,
--     mirror = <string|nil>, base = <string|nil>, message = <string|nil>,
--   }
-- Every dependency injectable: opts.sources, opts.http, opts.log.
function updater.check(opts)
  opts = opts or {}
  local log = type(opts.log) == "function" and opts.log or function() end
  local http = opts.http
  if type(http) ~= "function" then
    return {
      ok = false,
      code = "no-http",
      local_version = updater.local_version(),
      message = updater.tr("updater.no_http"),
    }
  end

  local sources = opts.sources
  if type(sources) ~= "table" or #sources == 0 then
    sources = installer.sources_for({})
  end

  local local_version = updater.local_version()
  local probe, err = updater.remote_probe(sources, http, log)
  local remote_version = probe and probe.version or nil
  local code = updater.decide(local_version, remote_version)

  return {
    ok = true,
    code = code,
    local_version = local_version,
    remote_version = remote_version,
    mirror = probe and probe.name or nil,
    base = probe and probe.base or nil,
    error = err,
  }
end

-- ---------------------------------------------------------------------------
-- run(opts) -- check, then install when the repository is ahead
-- ---------------------------------------------------------------------------
-- updater.run(opts) -> a check() result, or an installer result when an install
-- actually ran.  `opts.check_only` reports without changing anything.
--
-- The install itself is delegated to installer.install(), the SINGLE writer, with
-- the source that answered the version probe pinned.  That keeps "update" and
-- "install" from ever disagreeing about what a correct install is.
function updater.run(opts)
  opts = opts or {}
  local log = type(opts.log) == "function" and opts.log or function() end
  local env = opts.install_env or {}

  local probe_result = updater.check({
    sources = opts.sources,
    http = env.http,
    log = log,
  })

  log(updater.tr("updater.local", { version = tostring(probe_result.local_version) }))
  if probe_result.remote_version ~= nil then
    log(updater.tr("updater.remote", {
      version = probe_result.remote_version,
      name = tostring(probe_result.mirror),
    }))
  end

  if probe_result.code == "no-http" then
    return probe_result
  end

  if probe_result.code == "up-to-date" then
    log(updater.tr("updater.up_to_date"))
    return probe_result
  end

  if probe_result.code == "newer-installed" then
    log(updater.tr("updater.newer", {
      ["local"] = tostring(probe_result.local_version),
      remote = tostring(probe_result.remote_version),
    }))
    return probe_result
  end

  if probe_result.code == "unknown" then
    log(updater.tr("updater.unknown"))
    return probe_result
  end

  -- "update-available"
  log(updater.tr("updater.available", {
    ["local"] = tostring(probe_result.local_version),
    remote = tostring(probe_result.remote_version),
  }))

  if opts.check_only then
    return probe_result
  end

  -- Pin the source that answered the probe, so the update cannot half-come from
  -- one host and half from another.
  local install_opts = {}
  for key, value in pairs(env) do
    install_opts[key] = value
  end
  if probe_result.base ~= nil then
    install_opts.base = probe_result.base
  end
  install_opts.sources = nil
  install_opts.log = log

  local result = installer.install(install_opts)
  if result ~= nil and result.ok == true then
    log(updater.tr("updater.done"))
  elseif result ~= nil then
    log(updater.tr("updater.failed",
      { message = tostring(result.message or result.code) }))
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Argument parsing, usage, and the real environment
-- ---------------------------------------------------------------------------

-- updater.parse_args(argv) -> { check_only, sources_override, help,
--                               list_mirrors, mirror, no_mirror }.
-- Delegates source selection to installer.parse_args + installer.sources_for so
-- the updater accepts EXACTLY the same --mirror / --no-mirror / --list-mirrors
-- syntax as the installer, including the sources that are tried.
function updater.parse_args(argv)
  local parsed = installer.parse_args(argv)
  parsed.check_only = false
  if type(argv) == "table" then
    for index = 1, #argv do
      if argv[index] == "--check" then
        parsed.check_only = true
      end
    end
  end
  return parsed
end

-- updater.print_usage(env)
function updater.print_usage(env)
  local log = (env and env.log) or function() end
  log(updater.tr("updater.usage.title", { version = updater.VERSION }))
  log(updater.tr("updater.usage.syntax"))
  log(updater.tr("updater.usage.check"))
  log(updater.tr("updater.usage.mirror", { names = installer.mirror_names() }))
  log(updater.tr("updater.usage.no_mirror"))
  log(updater.tr("updater.usage.list_mirrors"))
end

-- updater.real_env() -> an ioenv backed by the live CC:Tweaked globals.  Built
-- by installer.real_env() so both programs fetch and write identically.
function updater.real_env()
  return installer.real_env()
end

-- ---------------------------------------------------------------------------
-- main(argv, env)
-- ---------------------------------------------------------------------------
-- Returns a result table and RAISES on a failed install, matching installer.main
-- so a non-interactive caller sees the same behaviour from either program.
function updater.main(argv, env)
  local parsed = updater.parse_args(argv)
  if env == nil then
    env = updater.real_env()
  end
  local log = type(env.log) == "function" and env.log or function() end

  if parsed.help then
    pcall(updater.print_usage, env)
    return { ok = true, code = "help" }
  end

  if parsed.list_mirrors then
    pcall(installer.print_mirrors, env)
    return { ok = true, code = "list-mirrors" }
  end

  local result = updater.run({
    sources = installer.sources_for(parsed),
    check_only = parsed.check_only,
    log = log,
    install_env = env,
  })

  if result ~= nil and result.ok == false and result.message ~= nil then
    error(result.message, 0)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Autorun
-- ---------------------------------------------------------------------------
-- Run as a program (`/lib/updater`) but NOT when merely `require`d by the
-- desktop test runner.  Same detection as installer.lua: `fs` is a ROM global
-- and is the reliable "am I on a computer?" signal, and a bare module name as
-- the first vararg means we were required rather than executed.
do
  local first = (...)
  local looks_like_module_name = type(first) == "string"
    and first:match("^[%a_][%w_%.]*$") ~= nil
  local has_cc_env = type(rawget(_G, "fs")) == "table"
  local opted_out = rawget(_G, "__CCNBS_UPDATER_NO_AUTORUN") == true
  if has_cc_env and not looks_like_module_name and not opted_out then
    updater.main({ ... }, updater.real_env())
  end
end

return updater
