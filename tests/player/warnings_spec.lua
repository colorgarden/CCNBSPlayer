-- tests/player/warnings_spec.lua
--
-- Tier-1 spec for player/warnings.lua -- THE WARNING RENDERER.
-- Written FIRST, before player/warnings.lua exists (strict TDD: watch it fail).
--
-- WHY THIS MODULE EXISTS
-- ---------------------------------------------------------------------------
-- Several modules already emit BARE warning codes:
--   player/dispatch.lua  -> "custom-instrument", "play-sound-pitch"
--   player/tempo.lua     -> "tempo-clamp"        (tempo.CLAMP_WARN_CODE)
--   player/fanout.lua    -> "speakers"           (+ warning_args)
--   nbs/analyze.lua      -> has_extended_range   => "extended-range"
-- and ccnbs.lua deduplicates them by code and forwards each code ONCE to a
-- bare callback opts.on_warning(code, args).  The one missing piece is the
-- SINGLE place that renders a bare code into the STABLE machine-detectable line
--   WARN[<code>] <Chinese explanation>
-- and enforces the once-per-song rule at the PRESENTATION layer.
--
-- FROZEN PUBLIC INTERFACE (asserted here)
--   local warnings = require("player.warnings")
--   warnings.CODES = { EXTENDED_RANGE, SPEAKERS, CUSTOM_INSTRUMENT,
--                      TEMPO_CLAMP, PLAY_SOUND_PITCH }
--   warnings.MARKER_PREFIX = "WARN"
--   warnings.format(code, args) -> string   -- PURE; no state; never emits
--   warnings.new(opts) -> w                  -- opts.emit, opts.quiet
--   w:report(code, args) -> line | nil       -- at most once per instance
--   w:has(code) -> boolean
--   w:lines() -> array (emission order)
--   w:reset()                                 -- fresh song
--   warnings.to_callback(w) -> function(code, args)
--
-- Marker shape: every emitted line begins with "WARN[<code>] " and continues
-- with a human-readable Chinese explanation.  Unknown codes still format
-- deterministically.  A Lua `nil` must NEVER appear in a line.
--
-- Compatibility: Lua 5.2 / Cobalt.  no `//`, no bitwise, no utf8.*.
--
-- Fixture loading mirrors tests/nbs/analyze_spec.lua.

local warnings = require("player.warnings")
local decode = require("nbs.decode")
local analyze = require("nbs.analyze")

-- ---------------------------------------------------------------------------
-- Project root + fixture helpers (same convention as analyze_spec.lua)
-- ---------------------------------------------------------------------------

local function project_root()
  local first = package.path:match("^(.-)/%?%.lua")
  if first == nil or first == "" then
    return "."
  end
  return first
end

local ROOT = project_root()

local function join(root, rel)
  if root == "." or root == "" then
    return rel
  end
  return root .. "/" .. rel
end

local FIXTURES_DIR = join(ROOT, "tests/fixtures")

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a") or ""
  handle:close()
  return data
end

-- A renderer whose emitted lines are captured rather than printed.
local function renderer(opts)
  opts = opts or {}
  local captured = {}
  local subject = warnings.new({
    emit = function(line)
      captured[#captured + 1] = line
    end,
    quiet = opts.quiet,
  })
  return subject, captured
end

-- The five known codes, as a stable ordered array (order of warnings.CODES).
local function known_codes()
  return {
    warnings.CODES.EXTENDED_RANGE,
    warnings.CODES.SPEAKERS,
    warnings.CODES.CUSTOM_INSTRUMENT,
    warnings.CODES.TEMPO_CLAMP,
    warnings.CODES.PLAY_SOUND_PITCH,
  }
end

-- ---------------------------------------------------------------------------
-- 1/2. Format shape and every known code
-- ---------------------------------------------------------------------------

describe("warnings.format shape", function()
  it("1. extended-range names the real key range and starts with WARN[extended-range] ", function()
    local line = warnings.format("extended-range", { min_key = 27, max_key = 46 })

    expect.equal(type(line), "string")
    expect.equal(line:sub(1, #"WARN[extended-range] "), "WARN[extended-range] ")
    expect.contains(line, "27")
    expect.contains(line, "46")
    io.write("    CASE1 " .. line .. "\n")
  end)

  it("2. every known code formats and starts with WARN[<its code>] ", function()
    for _, code in ipairs(known_codes()) do
      local line = warnings.format(code, {})
      local prefix = warnings.MARKER_PREFIX .. "[" .. code .. "] "
      expect.equal(line:sub(1, #prefix), prefix)
      expect.contains(line, code)
    end
    io.write("    CASE2 codes=" .. #known_codes() .. " all prefixed\n")
  end)

  it("2b. warnings.CODES carries exactly the five frozen bare codes", function()
    expect.equal(warnings.CODES.EXTENDED_RANGE, "extended-range")
    expect.equal(warnings.CODES.SPEAKERS, "speakers")
    expect.equal(warnings.CODES.CUSTOM_INSTRUMENT, "custom-instrument")
    expect.equal(warnings.CODES.TEMPO_CLAMP, "tempo-clamp")
    expect.equal(warnings.CODES.PLAY_SOUND_PITCH, "play-sound-pitch")
    expect.equal(warnings.MARKER_PREFIX, "WARN")
  end)
end)

-- ---------------------------------------------------------------------------
-- 3. Purity
-- ---------------------------------------------------------------------------

describe("warnings.format purity", function()
  it("3. two identical calls give identical strings and do not touch a ledger", function()
    local first = warnings.format("speakers", { peak = 9, required = 2, found = 1, dropped = 1 })
    local second = warnings.format("speakers", { peak = 9, required = 2, found = 1, dropped = 1 })
    expect.equal(first, second)

    local w = warnings.new({ emit = function() end })
    warnings.format("extended-range", { min_key = 27, max_key = 46 })
    expect.equal(w:has("extended-range"), false)
    io.write("    CASE3 identical=" .. tostring(first == second) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. Unknown code
-- ---------------------------------------------------------------------------

describe("warnings.format unknown code", function()
  it("4. something-new formats deterministically instead of raising", function()
    local line = warnings.format("something-new", nil)
    expect.equal(type(line), "string")
    expect.contains(line, "WARN[something-new]")
    -- deterministic: a second call is identical
    expect.equal(warnings.format("something-new", nil), line)
    io.write("    CASE4 " .. line .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. No nil leaks
-- ---------------------------------------------------------------------------

describe("warnings.format never renders nil", function()
  it("5. every code with nil and {} args is a string without a nil substring", function()
    for _, code in ipairs(known_codes()) do
      local a = warnings.format(code, nil)
      local b = warnings.format(code, {})
      expect.equal(type(a), "string")
      expect.equal(type(b), "string")
      expect.equal(a:find("nil", 1, true), nil)
      expect.equal(b:find("nil", 1, true), nil)
    end
    io.write("    CASE5 no-nil-leaks across " .. #known_codes() .. " codes\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 6/7/8/9. Once-only ledger, order, reset
-- ---------------------------------------------------------------------------

describe("warnings once-only emission", function()
  it("6. a code emits exactly once; the second report returns nil", function()
    local w, captured = renderer()
    local first = w:report("extended-range", { min_key = 27, max_key = 46 })
    local second = w:report("extended-range", { min_key = 27, max_key = 46 })

    expect.equal(type(first), "string")
    expect.contains(first, "WARN[extended-range]")
    expect.equal(second, nil)
    expect.equal(#captured, 1)
    expect.equal(w:lines()[1], first)
    expect.equal(#w:lines(), 1)
    io.write("    CASE6 first=" .. first .. " | second=" .. tostring(second)
      .. " | emits=" .. tostring(#captured) .. " | lines=" .. tostring(#w:lines()) .. "\n")
  end)

  it("7. has() reflects the ledger and reset() clears it", function()
    local w = warnings.new({ emit = function() end })
    expect.equal(w:has("speakers"), false)
    w:report("speakers", { peak = 9, required = 2, found = 1, dropped = 1 })
    expect.equal(w:has("speakers"), true)
    w:reset()
    expect.equal(w:has("speakers"), false)
    expect.equal(#w:lines(), 0)
  end)

  it("8. after reset the same code emits again (a fresh song)", function()
    local w, captured = renderer()
    local first = w:report("tempo-clamp", nil)
    w:reset()
    local second = w:report("tempo-clamp", nil)

    expect.equal(type(first), "string")
    expect.equal(type(second), "string")
    expect.equal(first, second)
    expect.equal(#captured, 2)
    io.write("    CASE8 emits-after-reset=" .. tostring(#captured) .. "\n")
  end)

  it("9. lines() preserves EMISSION ORDER", function()
    local w = renderer()
    local speakers_line = w:report("speakers", { peak = 9, required = 2, found = 1, dropped = 1 })
    local custom_line = w:report("custom-instrument", { count = 2 })

    expect.equal(w:lines()[1], speakers_line)
    expect.equal(w:lines()[2], custom_line)
    expect.sequence_equal(w:lines(), { speakers_line, custom_line })
    io.write("    CASE9 order[1]=" .. w:lines()[1] .. "\n")
    io.write("    CASE9 order[2]=" .. w:lines()[2] .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. quiet suppresses output but not the ledger (the --quiet requirement)
-- ---------------------------------------------------------------------------

describe("warnings quiet mode", function()
  it("10. quiet returns nil, never emits, yet records has() and still suppresses", function()
    local w, captured = renderer({ quiet = true })

    local first = w:report("extended-range", { min_key = 27, max_key = 46 })
    local second = w:report("extended-range", { min_key = 27, max_key = 46 })

    expect.equal(first, nil)
    expect.equal(second, nil)
    expect.equal(#captured, 0)
    expect.equal(w:has("extended-range"), true)
    expect.equal(#w:lines(), 1)
    io.write("    CASE10 first=" .. tostring(first) .. " second=" .. tostring(second)
      .. " emits=" .. tostring(#captured) .. " has=" .. tostring(w:has("extended-range"))
      .. " lines=" .. tostring(#w:lines()) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. to_callback adapter
-- ---------------------------------------------------------------------------

describe("warnings.to_callback adapter", function()
  it("11. forwards bare codes to report(): two speaker reports -> one emit", function()
    local w, captured = renderer()
    local cb = warnings.to_callback(w)

    expect.equal(type(cb), "function")
    cb("speakers", { peak = 9, required = 2, found = 1, dropped = 1 })
    cb("speakers", { peak = 9, required = 2, found = 1, dropped = 1 })

    expect.equal(#captured, 1)
    expect.equal(w:has("speakers"), true)
    io.write("    CASE11 emits=" .. tostring(#captured) .. " line=" .. tostring(captured[1]) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 12/13. Real-analysis integration
-- ---------------------------------------------------------------------------

describe("warnings real-analysis integration", function()
  it("12. simple.nbs reports its REAL key range once per song (once per renderer)", function()
    local bytes = read_file(join(FIXTURES_DIR, "simple.nbs"))
    expect.truthy(bytes ~= nil)

    local function run_song()
      local decoded = decode.decode(bytes)
      expect.equal(decoded.ok, true)
      local result = analyze.analyze(decoded.song)
      expect.equal(result.has_extended_range, true)
      expect.equal(result.min_key, 27)

      local w, captured = renderer()
      if result.has_extended_range then
        w:report("extended-range", { min_key = result.min_key, max_key = result.max_key })
      end
      return w, captured, result
    end

    local w1, captured1, result1 = run_song()
    expect.equal(#captured1, 1)
    expect.contains(captured1[1], "WARN[extended-range]")
    expect.contains(captured1[1], tostring(result1.min_key))
    expect.contains(captured1[1], tostring(result1.max_key))
    io.write("    CASE12 song1 min=" .. tostring(result1.min_key)
      .. " max=" .. tostring(result1.max_key) .. " emits=" .. tostring(#captured1)
      .. " line=" .. captured1[1] .. "\n")

    -- A FRESH renderer means a fresh song: one line again, not globally once.
    local w2, captured2 = run_song()
    expect.equal(#captured2, 1)
    expect.equal(captured2[1], captured1[1])
    expect.equal(w1:has("extended-range"), true)
    expect.equal(w2:has("extended-range"), true)
    io.write("    CASE12 song2 emits=" .. tostring(#captured2)
      .. " (fresh renderer -> per-song, not global)\n")
  end)

  it("13. v4.nbs has nothing to warn about -> zero lines", function()
    local bytes = read_file(join(FIXTURES_DIR, "v4.nbs"))
    expect.truthy(bytes ~= nil)

    local decoded = decode.decode(bytes)
    expect.equal(decoded.ok, true)
    local result = analyze.analyze(decoded.song)
    expect.equal(result.has_extended_range, false)

    local w, captured = renderer()
    if result.has_extended_range then
      w:report("extended-range", { min_key = result.min_key, max_key = result.max_key })
    end

    expect.equal(#captured, 0)
    expect.equal(#w:lines(), 0)
    expect.equal(w:has("extended-range"), false)
    io.write("    CASE13 v4.nbs extRange=" .. tostring(result.has_extended_range)
      .. " emits=" .. tostring(#captured) .. "\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 14. Hostile args never raise
-- ---------------------------------------------------------------------------

describe("warnings.format hostile args", function()
  it("14. nil/empty/malformed/non-table args across all codes -> string, no raise", function()
    local variants = {
      { label = "nil", value = nil },
      { label = "{}", value = {} },
      { label = "{min_key='x'}", value = { min_key = "x" } },
      { label = "{count=false}", value = { count = false } },
      { label = "42 (non-table)", value = 42 },
      { label = "'nope' (non-table)", value = "nope" },
    }

    local checked = 0
    for _, code in ipairs(known_codes()) do
      for _, variant in ipairs(variants) do
        local ok, line = pcall(function()
          return warnings.format(code, variant.value)
        end)
        expect.equal(ok, true)
        expect.equal(type(line), "string")
        checked = checked + 1
      end
    end
    io.write("    CASE14 hostile format calls=" .. tostring(checked) .. " all strings\n")
  end)
end)
