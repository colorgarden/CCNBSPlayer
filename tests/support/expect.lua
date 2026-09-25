-- tests/support/expect.lua
--
-- Zero-dependency assertion library for the CCNBSPlayer test suite.
--
-- Usage inside a spec file:
--   local expect = require("tests.support.expect")
--   -- or just rely on the global `expect` table installed by tests/run.lua
--
-- Every assertion RAISES a Lua error on failure (via error(msg, 2)), so a test
-- body simply calls them inline and aborts at the first failed assertion. Each
-- failure message names the assertion and renders both the expected and the
-- actual value in a readable, greppable form, e.g.
--
--   expect.equal failed: expected=2 actual=1
--   expect.deep_equal failed: first difference at $.layers[2].volume: expected=99 actual=50
--
-- Compatible with Lua 5.2 / CC:Tweaked Cobalt: no integer division, no bitwise
-- operators, no goto, no math.maxinteger, no collectgarbage, no string.dump and
-- no os.exit (the latter set is checked by tests/lint.lua).

local expect = {}

-- ---------------------------------------------------------------------------
-- Value rendering
-- ---------------------------------------------------------------------------

local function quote(value)
  return string.format("%q", value)
end

local function is_identifier(value)
  return type(value) == "string" and value:match("^[%a_][%w_]*$") ~= nil
end

local function sorted_keys(tbl)
  local keys = {}
  for key in pairs(tbl) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local format -- forward declaration for table rendering

local function format_table(tbl, seen, depth)
  if depth > 8 then
    return "{...}"
  end
  seen = seen or {}
  if seen[tbl] then
    return "<cycle>"
  end
  seen[tbl] = true
  local parts = {}
  for _, key in ipairs(sorted_keys(tbl)) do
    local value = tbl[key]
    local rendered
    if type(value) == "table" then
      rendered = format_table(value, seen, depth + 1)
    else
      rendered = format(value)
    end
    if is_identifier(key) then
      parts[#parts + 1] = key .. " = " .. rendered
    else
      parts[#parts + 1] = "[" .. format(key) .. "] = " .. rendered
    end
  end
  seen[tbl] = nil
  if #parts == 0 then
    return "{}"
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

format = function(value)
  local kind = type(value)
  if kind == "string" then
    return quote(value)
  elseif kind == "number" then
    if value ~= value then
      return "(nan)"
    elseif value == math.huge then
      return "(inf)"
    elseif value == -math.huge then
      return "(-inf)"
    end
    return tostring(value)
  elseif kind == "table" then
    return format_table(value)
  end
  return tostring(value)
end

-- ---------------------------------------------------------------------------
-- Deep comparison used by deep_equal and sequence_equal
-- ---------------------------------------------------------------------------

local function build_path(base, key)
  if is_identifier(key) then
    return base .. "." .. key
  end
  return base .. "[" .. format(key) .. "]"
end

-- Returns: ok, first_differing_path, actual_value, expected_value
local function deep_compare(actual, expected, path, seen)
  if type(actual) ~= "table" or type(expected) ~= "table" then
    if actual ~= expected then
      return false, path, actual, expected
    end
    return true
  end

  seen = seen or {}
  seen[actual] = seen[actual] or {}
  if seen[actual][expected] then
    return true
  end
  seen[actual][expected] = true

  for key, value in pairs(actual) do
    if expected[key] == nil then
      return false, build_path(path, key), value, nil
    end
  end
  for key, value in pairs(expected) do
    if actual[key] == nil then
      return false, build_path(path, key), nil, value
    end
  end

  for _, key in ipairs(sorted_keys(actual)) do
    local ok, first_path, actual_value, expected_value =
      deep_compare(actual[key], expected[key], build_path(path, key), seen)
    if not ok then
      return false, first_path, actual_value, expected_value
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

-- Scalar (reference) equality with a readable diff.
function expect.equal(actual, expected)
  if actual ~= expected then
    error(string.format("expect.equal failed: expected=%s actual=%s",
      format(expected), format(actual)), 2)
  end
  return actual
end

-- Recursive table equality. Key order does not matter. Reports the first
-- differing path in the expected/actual pair.
function expect.deep_equal(actual, expected)
  local ok, path, actual_value, expected_value = deep_compare(actual, expected, "$")
  if not ok then
    error(string.format(
      "expect.deep_equal failed: first difference at %s: expected=%s actual=%s",
      path, format(expected_value), format(actual_value)), 2)
  end
  return actual
end

-- ORDERED list equality. On mismatch reports the first index that differs and
-- both values. Elements are compared deeply, so lists of tuples work too.
function expect.sequence_equal(actual, expected)
  if type(actual) ~= "table" or type(expected) ~= "table" then
    error(string.format(
      "expect.sequence_equal failed: both values must be sequences (tables): expected=%s actual=%s",
      format(expected), format(actual)), 2)
  end
  local actual_length = #actual
  local expected_length = #expected
  if actual_length ~= expected_length then
    error(string.format(
      "expect.sequence_equal failed: length mismatch: expected %d element(s) actual %d element(s)",
      expected_length, actual_length), 2)
  end
  for index = 1, expected_length do
    local ok = deep_compare(actual[index], expected[index], "[" .. index .. "]")
    if not ok then
      error(string.format(
        "expect.sequence_equal failed: first difference at index %d: expected=%s actual=%s",
        index, format(expected[index]), format(actual[index])), 2)
    end
  end
  return actual
end

function expect.truthy(value)
  if not value then
    error(string.format("expect.truthy failed: expected a truthy value actual=%s",
      format(value)), 2)
  end
  return value
end

function expect.falsy(value)
  if value then
    error(string.format("expect.falsy failed: expected a falsy value actual=%s",
      format(value)), 2)
  end
  return value
end

-- Plain (non-pattern) substring test.
function expect.contains(haystack, needle)
  if type(haystack) ~= "string" or type(needle) ~= "string" then
    error(string.format(
      "expect.contains failed: both arguments must be strings: expected=%s actual=%s",
      format(needle), format(haystack)), 2)
  end
  if not string.find(haystack, needle, 1, true) then
    error(string.format("expect.contains failed: expected substring=%s actual=%s",
      format(needle), format(haystack)), 2)
  end
  return haystack
end

-- Lua pattern match.
function expect.matches(value, pattern)
  if type(value) ~= "string" or type(pattern) ~= "string" then
    error(string.format(
      "expect.matches failed: both arguments must be strings: expected=%s actual=%s",
      format(pattern), format(value)), 2)
  end
  local first = string.match(value, pattern)
  if first == nil then
    error(string.format("expect.matches failed: expected pattern=%s actual=%s",
      format(pattern), format(value)), 2)
  end
  return first
end

-- Calls fn and requires it to raise. When expected_substring is given, the
-- error message must contain it. Fails when fn returns normally.
function expect.raises(fn, expected_substring)
  if type(fn) ~= "function" then
    error(string.format("expect.raises failed: first argument must be a function actual=%s",
      type(fn)), 2)
  end
  local ok, err = pcall(fn)
  if ok then
    error("expect.raises failed: expected the function to raise actual=returned normally", 2)
  end
  local message = tostring(err)
  if expected_substring ~= nil then
    if type(expected_substring) ~= "string" then
      error("expect.raises failed: the expected substring must be a string when provided", 2)
    end
    if not string.find(message, expected_substring, 1, true) then
      error(string.format(
        "expect.raises failed: expected error containing=%s actual=%s",
        format(expected_substring), format(message)), 2)
    end
  end
  return message
end

-- Numeric closeness for future timing tests.
function expect.near(actual, expected, tolerance)
  if type(actual) ~= "number" or type(expected) ~= "number" then
    error(string.format(
      "expect.near failed: both values must be numbers: expected=%s actual=%s",
      format(expected), format(actual)), 2)
  end
  tolerance = tolerance or 1e-9
  if type(tolerance) ~= "number" or tolerance < 0 then
    error(string.format("expect.near failed: tolerance must be a non-negative number actual=%s",
      format(tolerance)), 2)
  end
  local delta = math.abs(actual - expected)
  if delta > tolerance then
    error(string.format(
      "expect.near failed: expected=%s actual=%s (delta=%s tolerance=%s)",
      format(expected), format(actual), format(delta), format(tolerance)), 2)
  end
  return actual
end

-- Unconditional failure.
function expect.fail(message)
  error("expect.fail: " .. tostring(message), 2)
end

return expect
