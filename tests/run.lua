-- tests/run.lua
--
-- Zero-dependency Lua test runner for CCNBSPlayer.
-- Target interpreter: Lua 5.2 (same family as CC:Tweaked's Cobalt). No
-- integer division, no bitwise operators, no goto, no math.maxinteger, no
-- collectgarbage, no string.dump and no os.exit (tests/lint.lua enforces the
-- same forbidden set across the source tree).
--
-- Run from the project root:
--   lua tests/run.lua
-- Run a subset (paths are relative to the project root):
--   lua tests/run.lua tests/nbs/reader_spec.lua
--
-- Behaviour:
--   * Recursively discovers tests/**/*_spec.lua and sorts the paths for a
--     deterministic order. Optional command-line path arguments replace
--     discovery; an argument that matches no file is reported and contributes
--     zero specs.
--   * Prepends the project root to package.path, so specs may require modules
--     like require("nbs.reader") and require("tests.support.expect").
--   * Installs the assertion library as the GLOBAL `expect` table before each
--     spec file is loaded. It is also available as
--     require("tests.support.expect") -- both entry points return the same
--     table.
--
-- Contract exposed to spec files:
--   describe(name, fn)        groups tests (may nest)
--   it(name, fn)              registers one test (alias: test)
--   before_each(fn)/after_each(fn)  hooks around every test of a spec file
--   expect.*                  assertion functions (see expect.lua)
--
-- Output:
--   SPEC <path>               one line per spec file
--   PASS <name>               one line per passing test
--   FAIL <name>               one line per failing test, followed by the
--                             assertion message and a debug.traceback
--   ERROR <path>: <message>   spec file failed to load/compile or its
--                             top-level chunk raised (counted as `errored`)
--   SUMMARY: <p> passed, <f> failed, <e> errored
--
-- Exit status: 0 iff failed == 0 and errored == 0. On failure the process ends
-- with a non-zero status by raising an uncaught error (the `lua` interpreter
-- exits with code 1). We intentionally do NOT call the os-exit primitive here:
-- it belongs to the Cobalt-forbidden set that tests/lint.lua checks for, and
-- an uncaught error gives us the same non-zero exit code.

-- ---------------------------------------------------------------------------
-- Project root and module search path
-- ---------------------------------------------------------------------------

local script_path = "tests/run.lua"
if arg and arg[0] then
  script_path = arg[0]
end
script_path = script_path:gsub("\\", "/")

local ROOT = script_path:match("^(.*)/tests/run%.lua$")
if not ROOT or ROOT == "" then
  ROOT = "."
end

package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

-- Expose the assertion library both ways documented above.
local expect_module = require("tests.support.expect")
expect = expect_module

local TESTS_DIR = (ROOT == ".") and "tests" or (ROOT .. "/tests")

-- ---------------------------------------------------------------------------
-- Filesystem helpers (no external dependencies; io.popen belongs to stdlib)
-- ---------------------------------------------------------------------------

local is_windows = package.config:sub(1, 1) == "\\"

local function shell_lines(command)
  local pipe = io.popen(command)
  if not pipe then
    return {}
  end
  local output = pipe:read("*a") or ""
  pipe:close()
  local lines = {}
  for line in output:gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function list_entries(path, dirs_only)
  if is_windows then
    local flag = dirs_only and "/ad" or "/a-d"
    local entries = {}
    local lines = shell_lines('dir /b ' .. flag .. ' "' .. path .. '" 2>nul')
    for _, line in ipairs(lines) do
      if line ~= "File Not Found" then
        entries[#entries + 1] = line
      end
    end
    return entries
  end
  local kind = dirs_only and "d" or "f"
  return shell_lines('find "' .. path .. '" -mindepth 1 -maxdepth 1 -type '
    .. kind .. ' -printf "%f\\n" 2>/dev/null')
end

local function join_path(dir, name)
  if dir == "" or dir == "." then
    return name
  end
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

local function discover_specs(dir, found)
  found = found or {}
  for _, name in ipairs(list_entries(dir, true)) do
    discover_specs(join_path(dir, name), found)
  end
  for _, name in ipairs(list_entries(dir, false)) do
    if name:match("_spec%.lua$") then
      found[#found + 1] = join_path(dir, name)
    end
  end
  return found
end

-- Resolve one command-line argument to a list of spec paths. A readable file is
-- used as-is; a directory is searched recursively; anything else (including a
-- path that does not exist) contributes nothing.
local function resolve_argument(target)
  local normalized = target:gsub("\\", "/")
  local candidates = { normalized }
  if ROOT ~= "." then
    candidates[#candidates + 1] = join_path(ROOT, normalized)
  end

  for _, candidate in ipairs(candidates) do
    local handle = io.open(candidate, "r")
    if handle then
      handle:close()
      return { candidate }
    end
  end

  for _, candidate in ipairs(candidates) do
    local found = discover_specs(candidate)
    if #found > 0 then
      return found
    end
  end

  io.write("warning: no spec files matched '" .. normalized .. "'\n")
  return {}
end

-- ---------------------------------------------------------------------------
-- Test registry (globals used by spec files)
-- ---------------------------------------------------------------------------

local current = nil

local function new_collector()
  return { tests = {}, stack = {}, before_each = {}, after_each = {} }
end

local function qualified_name(name)
  if #current.stack == 0 then
    return tostring(name)
  end
  return table.concat(current.stack, " > ") .. " > " .. tostring(name)
end

function describe(name, fn)
  if type(fn) ~= "function" then
    error("describe: expected a function body, got " .. type(fn), 2)
  end
  current.stack[#current.stack + 1] = tostring(name)
  local ok, err = pcall(fn)
  current.stack[#current.stack] = nil
  if not ok then
    error(err, 0)
  end
end

function it(name, fn)
  if type(fn) ~= "function" then
    error("it: expected a test function, got " .. type(fn), 2)
  end
  current.tests[#current.tests + 1] = {
    name = qualified_name(name),
    fn = fn,
    before_each = current.before_each,
    after_each = current.after_each,
  }
end

-- Alias kept for specs that prefer the shorter name.
function test(name, fn)
  it(name, fn)
end

function before_each(fn)
  current.before_each[#current.before_each + 1] = fn
end

function after_each(fn)
  current.after_each[#current.after_each + 1] = fn
end

-- ---------------------------------------------------------------------------
-- Execution and reporting
-- ---------------------------------------------------------------------------

local passed, failed, errored = 0, 0, 0

local function write_block(text)
  local string_value = tostring(text)
  if string_value == "" then
    return
  end
  for line in string_value:gmatch("[^\r\n]+") do
    io.write("    " .. line .. "\n")
  end
end

local function message_handler(err)
  return err, debug.traceback("", 2)
end

local function run_test(entry)
  local function body()
    for _, hook in ipairs(entry.before_each) do
      hook()
    end
    entry.fn()
    for _, hook in ipairs(entry.after_each) do
      hook()
    end
  end

  local ok, err, trace = xpcall(body, message_handler)
  if ok then
    passed = passed + 1
    io.write("PASS " .. entry.name .. "\n")
  else
    failed = failed + 1
    io.write("FAIL " .. entry.name .. "\n")
    write_block(err)
    if type(trace) == "string" and trace ~= "" then
      write_block(trace)
    end
  end
end

local function load_and_run_spec(path)
  io.write("SPEC " .. path .. "\n")

  local chunk, load_error = loadfile(path)
  if not chunk then
    errored = errored + 1
    io.write("ERROR " .. path .. ": " .. tostring(load_error) .. "\n")
    return
  end

  current = new_collector()
  local collector = current
  local ok, err, trace = xpcall(chunk, message_handler)
  current = nil

  if not ok then
    errored = errored + 1
    io.write("ERROR " .. path .. ": " .. tostring(err) .. "\n")
    write_block(trace)
    return
  end

  for _, entry in ipairs(collector.tests) do
    run_test(entry)
  end
end

local function collect_spec_paths()
  local paths = {}
  if arg and #arg > 0 then
    for _, target in ipairs(arg) do
      for _, path in ipairs(resolve_argument(target)) do
        paths[#paths + 1] = path
      end
    end
  else
    for _, path in ipairs(discover_specs(TESTS_DIR)) do
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

local function main()
  local spec_paths = collect_spec_paths()

  if #spec_paths == 0 then
    io.write("no spec files discovered\n")
  end

  for _, path in ipairs(spec_paths) do
    load_and_run_spec(path)
  end

  io.write(string.format(
    "SUMMARY: %d passed, %d failed, %d errored\n", passed, failed, errored))
  io.flush()

  if failed > 0 or errored > 0 then
    error(string.format("test run failed: %d failed, %d errored", failed, errored), 0)
  end
end

main()
