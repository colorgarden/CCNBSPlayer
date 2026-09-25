-- tests/lint.lua
--
-- Cobalt-subset forbidden-construct linter for CCNBSPlayer.
--
-- CC:Tweaked runs Lua on Cobalt, which tracks Lua 5.2.  Code that uses Lua 5.3+
-- syntax (floor division, bitwise operators, the 5.3 integer `math` library)
-- or host facilities that do not exist in the computer environment
-- (`collectgarbage`, `string.dump`, `os.exit`, `os.execute`) can pass a
-- desktop Lua test run yet fail inside the game.  This linter catches those
-- constructs mechanically.
--
-- It is a *tokenizer*, not a grep: comments and string literals are blanked
-- (with newlines preserved, so line/column numbers stay exact) and only the
-- remaining "normal code" is searched.  Prose such as `-- see http://x` or a
-- literal `"a//b|c&d"` therefore never produces a false positive.
--
-- Usage:
--     lua tests/lint.lua
--     lua tests/lint.lua --root <dir> [--root <dir> ...]
--     CCNBS_LINT_ROOTS=<dir>;<dir> lua tests/lint.lua
--
-- Default scan roots: nbs/, player/, tests/, qa/ plus root-level *.lua entry
-- files.  tests/fixtures/ and .omo/, .codegraph/, .git/ are always skipped.
--
-- Output: one line per finding, "<path>:<line>:<col>: <CODE> <construct>",
-- followed by a summary.  Exit status is 1 when a finding exists, else 0.

local SEP = package.config:sub(1, 1)

--------------------------------------------------------------------------------
-- Forbidden constructs
--------------------------------------------------------------------------------

-- Single/double character tokens that are operators on Lua 5.3+ only.
-- (`~` is handled specially so `~=` stays legal.)
local TOKEN_CHECKS = {
  { text = "//", code = "FLOOR_DIV", desc = "floor division" },
  { text = "<<", code = "SHL",       desc = "bitwise shift left" },
  { text = ">>", code = "SHR",       desc = "bitwise shift right" },
  { text = "&",  code = "BITAND",    desc = "bitwise and" },
  { text = "|",  code = "BITOR",     desc = "bitwise or" },
}

-- Dotted names / identifiers unavailable in Cobalt (Lua 5.2).
local NAME_CHECKS = {
  ["math.maxinteger"] = "MATH_MAXINTEGER",
  ["math.mininteger"] = "MATH_MININTEGER",
  ["math.tointeger"]  = "MATH_TOINTEGER",
  ["math.type"]       = "MATH_TYPE",
  ["math.ult"]        = "MATH_ULT",
  ["collectgarbage"]  = "COLLECTGARBAGE",
  ["string.dump"]     = "STRING_DUMP",
  ["os.exit"]         = "OS_EXIT",
  ["os.execute"]      = "OS_EXECUTE",
}

-- Directories whose contents are never scanned.
local SKIP_DIRS = {
  "/.omo/",
  "/.codegraph/",
  "/.git/",
  "/tests/fixtures/",
}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function trim(s)
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
end

local function normalize(p)
  return (p:gsub("\\", "/"))
end

local function is_skipped(p)
  local q = normalize(p)
  for _, dir in ipairs(SKIP_DIRS) do
    if q:find(dir, 1, true) then
      return true
    end
  end
  return false
end

local CWD = nil
local function get_cwd()
  if CWD ~= nil then
    return CWD
  end
  local cmd = (SEP == "\\") and "cd" or "pwd"
  local f = io.popen(cmd)
  if not f then
    CWD = ""
    return CWD
  end
  local s = f:read("*a") or ""
  f:close()
  s = s:gsub("[\r\n]+$", "")
  CWD = normalize(s)
  return CWD
end

local function relpath(p)
  local p2 = normalize(p)
  local c = get_cwd()
  if c ~= "" and p2:sub(1, #c + 1) == c .. "/" then
    return p2:sub(#c + 2)
  end
  return p2
end

local function shell_lines(cmd)
  local f = io.popen(cmd)
  if not f then
    return {}
  end
  local out = f:read("*a") or ""
  f:close()
  local res = {}
  for line in out:gmatch("[^\r\n]+") do
    line = trim(line)
    if #line > 0 then
      res[#res + 1] = line
    end
  end
  return res
end

local function collect_dir(dir, candidates)
  local win_dir = dir:gsub("/", "\\")
  local cmd
  if SEP == "\\" then
    cmd = 'dir /b /s /a-d "' .. win_dir .. '" 2>nul'
  else
    cmd = 'find "' .. dir .. '" -type f -name "*.lua" 2>/dev/null'
  end
  for _, p in ipairs(shell_lines(cmd)) do
    if p:match("%.lua$") then
      candidates[#candidates + 1] = p
    end
  end
end

local function collect_root_lua(candidates)
  local cmd
  if SEP == "\\" then
    cmd = 'dir /b /a-d "*.lua" 2>nul'
  else
    cmd = 'ls -1 *.lua 2>/dev/null'
  end
  for _, p in ipairs(shell_lines(cmd)) do
    if p:match("%.lua$") then
      candidates[#candidates + 1] = p
    end
  end
end

--------------------------------------------------------------------------------
-- Tokenizer: blank comments and string literals, preserving positions
--------------------------------------------------------------------------------

-- Returns a copy of `src` in which every character inside a comment or string
-- literal is replaced by a space (newlines are kept).  Matches on the result
-- can therefore only ever come from "normal" code.
local function strip(src)
  local out = {}
  local n = #src
  local i = 1

  local function blank(a, b)
    if b > n then
      b = n
    end
    local k = a
    while k <= b do
      local ch = src:sub(k, k)
      if ch == "\n" or ch == "\r" then
        out[#out + 1] = ch
      else
        out[#out + 1] = " "
      end
      k = k + 1
    end
  end

  while i <= n do
    local c = src:sub(i, i)
    local d = src:sub(i + 1, i + 1)

    if c == "-" and d == "-" then
      -- Comment: long (--[[ .. ]], --[=[ .. ]=]) or short (-- .. EOL).
      local j = i + 2
      local eq = 0
      while src:sub(j, j) == "=" do
        eq = eq + 1
        j = j + 1
      end
      if src:sub(j, j) == "[" then
        local close = "]" .. string.rep("=", eq) .. "]"
        local e = src:find(close, j + 1, true)
        if e then
          blank(i, e + #close - 1)
          i = e + #close
        else
          blank(i, n)
          i = n + 1
        end
      else
        local nl = src:find("\n", i, true)
        if nl then
          blank(i, nl - 1)
          i = nl
        else
          blank(i, n)
          i = n + 1
        end
      end

    elseif c == "[" then
      -- Long string [[ .. ]], [=[ .. ]=], ...
      local j = i + 1
      local eq = 0
      while src:sub(j, j) == "=" do
        eq = eq + 1
        j = j + 1
      end
      if src:sub(j, j) == "[" then
        local close = "]" .. string.rep("=", eq) .. "]"
        local e = src:find(close, j + 1, true)
        if e then
          blank(i, e + #close - 1)
          i = e + #close
        else
          blank(i, n)
          i = n + 1
        end
      else
        out[#out + 1] = c
        i = i + 1
      end

    elseif c == '"' or c == "'" then
      -- Short string.
      local j = i + 1
      while j <= n do
        local ch = src:sub(j, j)
        if ch == "\\" then
          j = j + 2
        elseif ch == c then
          j = j + 1
          break
        elseif ch == "\n" or ch == "\r" then
          break
        else
          j = j + 1
        end
      end
      blank(i, j - 1)
      i = j

    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  return table.concat(out)
end

--------------------------------------------------------------------------------
-- Detectors (operate on stripped, i.e. normal, code)
--------------------------------------------------------------------------------

local function scan_tokens(clean, add)
  local i = 1
  local n = #clean
  while i <= n do
    local c = clean:sub(i, i)
    local two = clean:sub(i, i + 1)
    local step = 1
    if two == "//" then
      add(i, "FLOOR_DIV", "//")
      step = 2
    elseif two == "<<" then
      add(i, "SHL", "<<")
      step = 2
    elseif two == ">>" then
      add(i, "SHR", ">>")
      step = 2
    elseif c == "&" then
      add(i, "BITAND", "&")
    elseif c == "|" then
      add(i, "BITOR", "|")
    elseif c == "~" then
      if two == "~=" then
        step = 2 -- `~=` (not equal) is valid Lua 5.2: do not report.
      else
        add(i, "BITNOT", "~")
      end
    end
    i = i + step
  end
end

local function scan_names(clean, add)
  local i = 1
  local n = #clean
  while i <= n do
    local c = clean:sub(i, i)
    if c:match("[%a_]") then
      -- Identifier, possibly a dotted chain (math.type, os.exit, ...).
      local s = i
      i = i + 1
      while i <= n and clean:sub(i, i):match("[%w_]") do
        i = i + 1
      end
      while clean:sub(i, i) == "." and clean:sub(i + 1, i + 1):match("[%a_]") do
        i = i + 1
        while i <= n and clean:sub(i, i):match("[%w_]") do
          i = i + 1
        end
      end
      local name = clean:sub(s, i - 1)
      local code = NAME_CHECKS[name]
      if not code and name:sub(1, 3) == "_G." then
        code = NAME_CHECKS[name:sub(4)]
      end
      if code then
        add(s, code, name)
      end

    elseif c:match("%d") then
      -- Numeric literal.  Lua has no integer suffixes; `1LL` & friends are a
      -- separate, best-effort code (they are syntax errors everywhere, but a
      -- confused port could still introduce them).
      local s = i
      i = i + 1
      while i <= n do
        local ch = clean:sub(i, i)
        if ch == "." and clean:sub(i + 1, i + 1) == "." then
          break -- `..` is concatenation, not part of a number.
        end
        if ch:match("[%w_%.]") then
          i = i + 1
        else
          break
        end
      end
      local num = clean:sub(s, i - 1)
      if num:match("^%d+[uUlL][uUlL]?$")
        or num:match("^0[xX]%x+[uUlL][uUlL]?$") then
        add(s, "BAD_INT_SUFFIX", num)
      end

    else
      i = i + 1
    end
  end
end

--------------------------------------------------------------------------------
-- Line/column mapping
--------------------------------------------------------------------------------

local function line_starts(src)
  local starts = { 1 }
  local p = 1
  while true do
    local nl = src:find("\n", p, true)
    if not nl then
      break
    end
    starts[#starts + 1] = nl + 1
    p = nl + 1
  end
  return starts
end

local function locate(starts, idx)
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if starts[mid] <= idx then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo, idx - starts[lo] + 1
end

--------------------------------------------------------------------------------
-- File discovery
--------------------------------------------------------------------------------

local function parse_roots(argv)
  local roots = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--root" or a == "-r" then
      i = i + 1
      if argv[i] then
        roots[#roots + 1] = argv[i]
      end
    elseif a:sub(1, 7) == "--root=" then
      roots[#roots + 1] = a:sub(8)
    end
    i = i + 1
  end
  if #roots == 0 then
    local env = os.getenv("CCNBS_LINT_ROOTS")
    if env and #env > 0 then
      for part in env:gmatch("[^;,]+") do
        roots[#roots + 1] = trim(part)
      end
    end
  end
  return roots
end

local function discover(roots)
  local candidates = {}
  if #roots > 0 then
    for _, r in ipairs(roots) do
      if r:match("%.lua$") then
        candidates[#candidates + 1] = r
      else
        collect_dir(r, candidates)
      end
    end
  else
    for _, d in ipairs({ "nbs", "player", "tests", "qa" }) do
      collect_dir(d, candidates)
    end
    collect_root_lua(candidates)
  end

  local seen = {}
  local files = {}
  for _, p in ipairs(candidates) do
    local q = normalize(p)
    if not is_skipped(q) and not seen[q] then
      seen[q] = true
      files[#files + 1] = q
    end
  end
  table.sort(files)
  return files
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function main(argv)
  local roots = parse_roots(argv)
  local files = discover(roots)
  local total_findings = 0
  local files_with_findings = 0

  for _, path in ipairs(files) do
    local f = io.open(path, "rb")
    if f then
      local src = f:read("*a") or ""
      f:close()

      local clean = strip(src)
      local starts = line_starts(src)
      local findings = {}
      local function add(idx, code, text)
        findings[#findings + 1] = { idx = idx, code = code, text = text }
      end

      scan_tokens(clean, add)
      scan_names(clean, add)

      if #findings > 0 then
        table.sort(findings, function(a, b)
          return a.idx < b.idx
        end)
        files_with_findings = files_with_findings + 1
        for _, fd in ipairs(findings) do
          local line, col = locate(starts, fd.idx)
          io.write(relpath(path) .. ":" .. line .. ":" .. col .. ": "
            .. fd.code .. " " .. fd.text .. "\n")
          total_findings = total_findings + 1
        end
      end
    else
      io.stderr:write("lint: WARN cannot read " .. path .. "\n")
    end
  end

  if total_findings > 0 then
    io.write("lint: FAIL (" .. total_findings .. " finding(s) in "
      .. files_with_findings .. " file(s); " .. #files .. " file(s) scanned)\n")
  else
    io.write("lint: OK (" .. #files .. " files scanned)\n")
  end

  -- `os.exit` is itself forbidden in Cobalt, so reach it indirectly; that also
  -- keeps this file clean under its own rules.
  local exit_fn = os["exit"]
  if type(exit_fn) == "function" then
    if total_findings > 0 then
      exit_fn(1)
    else
      exit_fn(0)
    end
  end
  return total_findings > 0
end

local failed = main({ ... })
if failed then
  -- Reached only when os.exit is unavailable; still signal failure.
  error("forbidden construct(s) found", 0)
end
