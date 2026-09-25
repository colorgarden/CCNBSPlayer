-- tests/installer_spec.lua
--
-- Tier-1 spec for installer.lua -- THE ONE-CLICK INSTALLER'S PURE LOGIC.
-- Written FIRST, before installer.lua exists (strict TDD: watch it fail).
--
-- WHY THE INSTALLER IS TESTABLE
-- ---------------------------------------------------------------------------
-- The installer runs inside CraftOS-PC / CC:Tweaked, where the network and the
-- filesystem are globals.  To unit-test it on the desktop with NO real network
-- and NO real filesystem, the installer separates:
--
--   * PURE logic (no I/O): RUNTIME_FILES, file_url, target_path, install_plan,
--     should_overwrite, parse_args; and
--   * one seam-driven routine, install(ioenv), which only ever talks to the
--     injected `ioenv.http` and `ioenv.fs` -- never to the real globals.
--
-- install(ioenv) contract
--   ioenv.http(url)            -> body, err   (nil body == fetch failed)
--                                ioenv.http == nil means HTTP is UNAVAILABLE
--   ioenv.fs.exists(path)      -> boolean
--   ioenv.fs.is_dir(path)      -> boolean
--   ioenv.fs.make_dir(path)    -> boolean
--   ioenv.fs.write(path, body) -> boolean
--   ioenv.log(line)            -> optional
--
--   -> { ok=<bool>, code=<string>, message=<string|nil>, installed=<int>,
--        files=<array|nil> }
--   codes: "ok" | "http-disabled" | "http-failed" | "dir-refused" |
--          "write-failed"
--
-- THE INSTALL ROOT DECISION (verified against the target, see README)
-- ---------------------------------------------------------------------------
-- `require` does NOT have a fixed `/lib/` search root: package.path is
-- `?;?.lua;?/init.lua;/rom/modules/main/?;...` and the `?` patterns resolve
-- relative to the directory of the RUNNING PROGRAM (`fs.getDir(program)`).
-- `/lib/` therefore works precisely because everything -- including the
-- entry program ccnbsplayer.lua -- is co-located under it.  The installer
-- installs the whole runtime under /lib and maps `nbs/decode.lua` to
-- `/lib/nbs/decode.lua`.
--
-- Lua 5.2 / Cobalt subset: no `//`, no bitwise operators, no utf8.*.

local installer = require("installer")

-- ---------------------------------------------------------------------------
-- Test fixtures: an in-memory http + fs
-- ---------------------------------------------------------------------------

-- The repo files are read from disk by the FAKE http so the installer's
-- fetched bodies can be compared with the real sources.  No network is used.
local function read_repo_file(relative_path)
  local handle = io.open(relative_path, "rb")
  if handle == nil then
    return nil
  end
  local body = handle:read("*a")
  handle:close()
  return body
end

-- make_fake_http(base, fail_paths) -> function(url) -> body, err
-- Serves a file from disk for `<base>/<relative>`; returns nil for unknown
-- URLs and for any path listed in fail_paths.
local function make_fake_http(base, fail_paths)
  fail_paths = fail_paths or {}
  return function(url)
    local prefix = base .. "/"
    if url:sub(1, #prefix) ~= prefix then
      return nil, "unexpected url " .. url
    end
    local relative = url:sub(#prefix + 1)
    for index = 1, #fail_paths do
      if fail_paths[index] == relative then
        return nil, "simulated network failure"
      end
    end
    local body = read_repo_file(relative)
    if body == nil then
      return nil, "not found: " .. relative
    end
    return body
  end
end

local function make_fake_fs()
  local fs = {
    files = {},
    dirs = {},
    writes = {},
  }
  function fs.exists(path)
    return fs.files[path] ~= nil or fs.dirs[path] == true
  end
  function fs.is_dir(path)
    return fs.dirs[path] == true
  end
  function fs.make_dir(path)
    fs.dirs[path] = true
    return true
  end
  function fs.write(path, body)
    fs.files[path] = body
    fs.writes[#fs.writes + 1] = { path = path, body = body }
    return true
  end
  return fs
end

local EXPECTED_FILES = {
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

-- ---------------------------------------------------------------------------
-- Constants and the runtime file list
-- ---------------------------------------------------------------------------

describe("installer constants", function()
  it("exposes a version string", function()
    expect.equal(type(installer.VERSION), "string")
    expect.equal(installer.VERSION, "1.0.0")
  end)

  it("installs under the /lib root", function()
    expect.equal(installer.INSTALL_ROOT, "/lib")
  end)

  it("defaults to the project's raw GitHub base URL", function()
    expect.equal(installer.DEFAULT_BASE_URL,
      "https://raw.githubusercontent.com/colorgarden/CCNBSPlayer/main")
  end)

  it("lists exactly the runtime files, with no duplicates", function()
    local seen = {}
    for index = 1, #installer.RUNTIME_FILES do
      local path = installer.RUNTIME_FILES[index]
      expect.equal(seen[path], nil)
      seen[path] = true
    end
    expect.equal(#installer.RUNTIME_FILES, #EXPECTED_FILES)
    for index = 1, #EXPECTED_FILES do
      expect.equal(seen[EXPECTED_FILES[index]], true)
    end
  end)

  it("lists only files that exist in this checkout", function()
    for index = 1, #installer.RUNTIME_FILES do
      local path = installer.RUNTIME_FILES[index]
      local handle = io.open(path, "rb")
      expect.truthy(handle)
      handle:close()
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Pure path / URL mapping
-- ---------------------------------------------------------------------------

describe("installer URL construction", function()
  it("joins a base without a trailing slash", function()
    expect.equal(installer.file_url("https://example.test/base", "nbs/decode.lua"),
      "https://example.test/base/nbs/decode.lua")
  end)

  it("tolerates trailing slashes in the base", function()
    expect.equal(installer.file_url("https://example.test/base/", "player/tui.lua"),
      "https://example.test/base/player/tui.lua")
    expect.equal(installer.file_url("https://example.test/base///", "ccnbs.lua"),
      "https://example.test/base/ccnbs.lua")
  end)

  it("falls back to DEFAULT_BASE_URL when the base is empty", function()
    expect.equal(installer.file_url("", "ccnbs.lua"),
      installer.DEFAULT_BASE_URL .. "/ccnbs.lua")
    expect.equal(installer.file_url(nil, "ccnbs.lua"),
      installer.DEFAULT_BASE_URL .. "/ccnbs.lua")
  end)

  it("normalizes a base by stripping trailing slashes", function()
    expect.equal(installer.normalize_base("http://127.0.0.1:8000/"),
      "http://127.0.0.1:8000")
    expect.equal(installer.normalize_base("http://127.0.0.1:8000"),
      "http://127.0.0.1:8000")
    expect.equal(installer.normalize_base(""), installer.DEFAULT_BASE_URL)
  end)
end)

describe("installer target mapping", function()
  it("maps a root file to /lib", function()
    expect.equal(installer.target_path("ccnbs.lua"), "/lib/ccnbs.lua")
    expect.equal(installer.target_path("ccnbsplayer.lua"), "/lib/ccnbsplayer.lua")
  end)

  it("maps module files into matching subdirectories", function()
    expect.equal(installer.target_path("nbs/decode.lua"), "/lib/nbs/decode.lua")
    expect.equal(installer.target_path("player/tui.lua"), "/lib/player/tui.lua")
  end)

  it("computes the parent directory of a target", function()
    expect.equal(installer.parent_dir("/lib/ccnbs.lua"), "/lib")
    expect.equal(installer.parent_dir("/lib/nbs/decode.lua"), "/lib/nbs")
    expect.equal(installer.parent_dir("/lib/player/tui.lua"), "/lib/player")
  end)
end)

describe("installer install plan", function()
  it("is ordered, complete, and self-consistent", function()
    local base = "http://127.0.0.1:8000"
    local plan = installer.install_plan(base)
    expect.equal(#plan, #installer.RUNTIME_FILES)
    for index = 1, #plan do
      local entry = plan[index]
      local path = installer.RUNTIME_FILES[index]
      expect.equal(entry.repo_path, path)
      expect.equal(entry.url, base .. "/" .. path)
      expect.equal(entry.target, "/lib/" .. path)
      expect.equal(entry.dir, installer.parent_dir(entry.target))
    end
  end)

  it("creates the install directories shallow-first", function()
    local dirs = installer.INSTALL_DIRS
    expect.equal(dirs[1], "/lib")
    -- Every deeper directory must follow its parent in the list.
    local seen = {}
    for index = 1, #dirs do
      local dir = dirs[index]
      local parent = installer.parent_dir(dir)
      if seen[parent] then
        expect.truthy(seen[parent])
      end
      seen[dir] = true
    end
    expect.equal(seen["/lib/nbs"], true)
    expect.equal(seen["/lib/player"], true)
  end)
end)

-- ---------------------------------------------------------------------------
-- Idempotency decisions
-- ---------------------------------------------------------------------------

describe("installer overwrite decisions", function()
  it("overwrites an existing file (idempotent re-run)", function()
    expect.equal(installer.should_overwrite("file"), "write")
  end)

  it("writes when nothing is there yet", function()
    expect.equal(installer.should_overwrite("none"), "write")
  end)

  it("refuses to clobber a directory", function()
    expect.equal(installer.should_overwrite("dir"), "refuse")
  end)
end)

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------

describe("installer argument parsing", function()
  it("recognizes a custom base URL", function()
    local parsed = installer.parse_args({ "http://127.0.0.1:8000" })
    expect.equal(parsed.base, "http://127.0.0.1:8000")
    expect.equal(parsed.result_path, nil)
    expect.falsy(parsed.help)
  end)

  it("recognizes a harness result path", function()
    local parsed = installer.parse_args({ "result=install.txt" })
    expect.equal(parsed.result_path, "install.txt")
  end)

  it("recognizes help flags", function()
    expect.truthy(installer.parse_args({ "--help" }).help)
    expect.truthy(installer.parse_args({ "-h" }).help)
    expect.truthy(installer.parse_args({ "help" }).help)
  end)

  it("ignores unknown arguments and tolerates nil", function()
    local parsed = installer.parse_args({ "wat", "--nope" })
    expect.equal(parsed.base, nil)
    expect.equal(parsed.result_path, nil)
    expect.falsy(parsed.help)
    local empty = installer.parse_args(nil)
    expect.equal(#empty, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- install(ioenv): the seam-driven routine
-- ---------------------------------------------------------------------------

describe("installer install(ioenv)", function()
  local BASE = "http://127.0.0.1:8000"

  it("fetches every file and writes it to its /lib target", function()
    local fs = make_fake_fs()
    local result = installer.install({
      base = BASE,
      http = make_fake_http(BASE),
      fs = fs,
      log = function() end,
    })

    expect.truthy(result.ok)
    expect.equal(result.code, "ok")
    expect.equal(result.installed, #installer.RUNTIME_FILES)
    expect.equal(#fs.writes, #installer.RUNTIME_FILES)

    -- The bytes on the fake filesystem must equal the repo sources.
    for index = 1, #installer.RUNTIME_FILES do
      local path = installer.RUNTIME_FILES[index]
      local target = "/lib/" .. path
      expect.equal(fs.files[target], read_repo_file(path))
    end

    -- The directories were created.
    expect.truthy(fs.dirs["/lib"])
    expect.truthy(fs.dirs["/lib/nbs"])
    expect.truthy(fs.dirs["/lib/player"])
  end)

  it("is idempotent: a second run overwrites cleanly", function()
    local fs = make_fake_fs()
    local env = {
      base = BASE,
      http = make_fake_http(BASE),
      fs = fs,
      log = function() end,
    }

    local first = installer.install(env)
    expect.truthy(first.ok)
    local writes_after_first = #fs.writes

    -- A stale/corrupt copy in the target must be replaced, not skipped.
    fs.files["/lib/ccnbs.lua"] = "corrupted"

    local second = installer.install(env)
    expect.truthy(second.ok)
    expect.equal(second.code, "ok")
    expect.equal(#fs.writes, writes_after_first + #installer.RUNTIME_FILES)
    expect.equal(fs.files["/lib/ccnbs.lua"], read_repo_file("ccnbs.lua"))
  end)

  it("reports http-disabled when no http seam is supplied", function()
    local fs = make_fake_fs()
    local result = installer.install({ base = BASE, fs = fs, log = function() end })

    expect.falsy(result.ok)
    expect.equal(result.code, "http-disabled")
    expect.equal(result.installed, 0)
    expect.contains(result.message, "HTTP")
    expect.contains(result.message, "http_enable")
    expect.contains(result.message, "启用 HTTP")
    expect.equal(#fs.writes, 0)
  end)

  it("reports http-failed when a fetch returns nil", function()
    local fs = make_fake_fs()
    local result = installer.install({
      base = BASE,
      http = make_fake_http(BASE, { "player/tui.lua" }),
      fs = fs,
      log = function() end,
    })

    expect.falsy(result.ok)
    expect.equal(result.code, "http-failed")
    expect.contains(result.message, "download")
    expect.contains(result.message, "player/tui.lua")
    -- Nothing partial is left for the failed file.
    expect.equal(fs.files["/lib/player/tui.lua"], nil)
  end)

  it("refuses to clobber a directory where a file must go", function()
    local fs = make_fake_fs()
    fs.dirs["/lib/ccnbs.lua"] = true
    local result = installer.install({
      base = BASE,
      http = make_fake_http(BASE),
      fs = fs,
      log = function() end,
    })

    expect.falsy(result.ok)
    expect.equal(result.code, "dir-refused")
    expect.contains(result.message, "/lib/ccnbs.lua")
  end)

  it("consults should_overwrite as the SINGLE source of the overwrite policy", function()
    -- A file already sits at the first target, so install() must ask the policy
    -- what to do rather than re-implementing the decision inline.  Forcing the
    -- policy to refuse an existing FILE (not just a directory) must make
    -- install() refuse it too.
    local fs = make_fake_fs()
    fs.files["/lib/ccnbs.lua"] = "stale"

    local saved = installer.should_overwrite
    local kinds = {}
    installer.should_overwrite = function(kind)
      kinds[#kinds + 1] = kind
      if kind == "file" then
        return "refuse"
      end
      return saved(kind)
    end

    local result
    local ok = pcall(function()
      result = installer.install({
        base = BASE,
        http = make_fake_http(BASE),
        fs = fs,
        log = function() end,
      })
    end)

    installer.should_overwrite = saved

    expect.equal(ok, true)
    expect.equal(kinds[1], "file")
    expect.falsy(result.ok)
    expect.equal(result.code, "dir-refused")
  end)

  it("reports write-failed when the filesystem refuses the write", function()
    local fs = make_fake_fs()
    fs.write = function(path)
      if path == "/lib/nbs/decode.lua" then
        return false
      end
      fs.files[path] = true
      return true
    end
    local result = installer.install({
      base = BASE,
      http = make_fake_http(BASE),
      fs = fs,
      log = function() end,
    })

    expect.falsy(result.ok)
    expect.equal(result.code, "write-failed")
    expect.contains(result.message, "/lib/nbs/decode.lua")
  end)
end)
