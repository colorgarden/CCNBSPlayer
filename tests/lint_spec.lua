-- tests/lint_spec.lua
--
-- Spec for tests/lint.lua, the Cobalt-subset forbidden-construct linter.
--
-- Works two ways:
--   * under the project harness:  lua tests/run.lua
--     (the harness installs the global describe/it/expect helpers)
--   * standalone:                 lua tests/lint_spec.lua
--     (a tiny local describe/it shim runs the same tests and exits non-zero
--      by raising an uncaught error when one fails)
--
-- Cases:
--   a. the clean project tree lints with exit 0 and an "lint: OK" summary;
--   b. a temp file containing floor division is rejected with exit 1 and the
--      output names the probe file and line (probe is removed afterwards);
--   c. a comment holding a URL with "||" and a string holding "//", "|" and
--      "&" do NOT trigger a finding (no false positives).

local is_windows = package.config:sub(1, 1) == "\\"

--------------------------------------------------------------------------------
-- Locate the interpreter and the linter, whatever the working directory is.
--------------------------------------------------------------------------------

local function self_dir()
  local self = (arg and arg[0]) or "tests/lint_spec.lua"
  self = self:gsub("\\", "/")
  local dir = self:match("^(.*)/[^/]*$")
  if not dir or dir == "" then
    return "."
  end
  return dir
end

local LUA = (arg and arg[-1]) or "lua"
local DIR = self_dir()
local LINT = DIR .. "/lint.lua"
local TMP = DIR .. "/.tmp"

-- cmd.exe mangles a command line that *begins* with a quoted executable, so on
-- Windows the interpreter is launched through `call "..."`.
local RUNNER = is_windows and ('call "' .. LUA .. '"') or ('"' .. LUA .. '"')

--------------------------------------------------------------------------------
-- Tiny process / filesystem helpers (io.popen is stdlib and not forbidden)
--------------------------------------------------------------------------------

local function quote(s)
  return '"' .. s .. '"'
end

-- Returns exit code and combined stdout.  io.popen honours the shell; a
-- non-zero child exit surfaces through close() as (nil, "exit", <code>).
local function run(command)
  local pipe = io.popen(command)
  if not pipe then
    return -1, ""
  end
  local output = pipe:read("*a") or ""
  local ok, _how, code = pipe:close()
  if ok then
    code = 0
  end
  if type(code) ~= "number" then
    code = -1
  end
  return code, output
end

local function lint_command(root)
  local cmd = RUNNER .. " " .. quote(LINT)
  if root then
    cmd = cmd .. " --root " .. quote(root)
  end
  return cmd
end

local function write_file(path, contents)
  local handle = io.open(path, "wb")
  if not handle then
    error("cannot open for writing: " .. path, 0)
  end
  handle:write(contents)
  handle:close()
end

local function mkdir(path)
  local command
  if is_windows then
    command = 'mkdir "' .. path:gsub("/", "\\") .. '" 2>nul'
  else
    command = 'mkdir -p "' .. path .. '"'
  end
  local pipe = io.popen(command)
  if pipe then
    pipe:read("*a")
    pipe:close()
  end
end

local function rmdir(path)
  local command
  if is_windows then
    command = 'rmdir /q "' .. path:gsub("/", "\\") .. '" 2>nul'
  else
    command = 'rmdir "' .. path .. '" 2>/dev/null'
  end
  local pipe = io.popen(command)
  if pipe then
    pipe:read("*a")
    pipe:close()
  end
end

-- Remove a probe file (if any) and its directory, never raising.
local function cleanup_probe(file, dir)
  pcall(os.remove, file)
  rmdir(dir)
end

--------------------------------------------------------------------------------
-- Assertions (framework-independent; an error fails the test under the harness)
--------------------------------------------------------------------------------

local function fail(message)
  error(message, 0)
end

local function assert_true(condition, message)
  if not condition then
    fail(message)
  end
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    fail(message .. " (expected " .. tostring(expected)
      .. ", got " .. tostring(actual) .. ")")
  end
end

--------------------------------------------------------------------------------
-- Standalone shim: only when the harness has not installed describe/it.
--------------------------------------------------------------------------------

local standalone = (type(describe) ~= "function") or (type(it) ~= "function")
local registry = {}

if standalone then
  function describe(_name, body)
    body()
  end
  function it(name, body)
    registry[#registry + 1] = { name = name, body = body }
  end
end

--------------------------------------------------------------------------------
-- Cases
--------------------------------------------------------------------------------

describe("lint", function()

  it("passes on the clean source tree (exit 0, OK summary)", function()
    local code, out = run(lint_command(nil))
    assert_equal(code, 0, "clean tree must lint clean; output:\n" .. out)
    assert_true(out:find("lint: OK", 1, true) ~= nil,
      "expected an 'lint: OK' summary; output:\n" .. out)
    assert_true(out:find("files scanned", 1, true) ~= nil,
      "expected a scanned-file count; output:\n" .. out)
  end)

  it("rejects floor division in a scanned file (exit 1, names file+line)", function()
    local dir = TMP .. "/lint_probe"
    local file = dir .. "/probe.lua"
    mkdir(dir)
    write_file(file, "local x = 5 // 2\n")

    local ok, code, out = pcall(function()
      return run(lint_command(dir))
    end)
    cleanup_probe(file, dir)
    if not ok then
      fail("lint invocation raised: " .. tostring(code))
    end

    assert_equal(code, 1, "probe with floor division must be rejected; output:\n" .. out)
    assert_true(out:find("probe.lua:1:", 1, true) ~= nil,
      "output must name the probe file and line; output:\n" .. out)
    assert_true(out:find("FLOOR_DIV", 1, true) ~= nil,
      "output must carry the FLOOR_DIV code; output:\n" .. out)
  end)

  it("does not false-positive on comments or string literals (exit 0)", function()
    local dir = TMP .. "/lint_control"
    local file = dir .. "/control.lua"
    mkdir(dir)
    -- URL with "||" in a comment; "//", "|" and "&" inside a string literal.
    write_file(file,
      "-- see http://example.com/a||b\n"
      .. "local s = \"a//b|c&d\"\n"
      .. "return s\n")

    local ok, code, out = pcall(function()
      return run(lint_command(dir))
    end)
    cleanup_probe(file, dir)
    if not ok then
      fail("lint invocation raised: " .. tostring(code))
    end

    assert_equal(code, 0,
      "comments/strings must not be flagged; output:\n" .. out)
    assert_true(out:find("lint: OK", 1, true) ~= nil,
      "expected an 'lint: OK' summary; output:\n" .. out)
  end)

end)

--------------------------------------------------------------------------------
-- Standalone execution
--------------------------------------------------------------------------------

if standalone then
  local failed = 0
  for _, entry in ipairs(registry) do
    local ok, err = xpcall(entry.body, debug.traceback)
    if ok then
      io.write("PASS " .. entry.name .. "\n")
    else
      failed = failed + 1
      io.write("FAIL " .. entry.name .. "\n")
      io.write(tostring(err) .. "\n")
    end
  end
  io.write(string.format("SUMMARY: %d passed, %d failed\n",
    #registry - failed, failed))
  if failed > 0 then
    error("lint_spec: " .. failed .. " test(s) failed", 0)
  end
end
