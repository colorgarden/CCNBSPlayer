-- tests/nbs/speakers_spec.lua
--
-- Tier-1 spec for nbs/speakers.lua -- the REQUIRED-SPEAKER-COUNT formula.
--
-- FROZEN PUBLIC INTERFACE UNDER TEST
-- ----------------------------------
--   local speakers = require("nbs.speakers")
--
--   speakers.MAX_NOTES_PER_TICK                  -- 8
--   speakers.required_count(analysis)            -> integer >= 0
--   speakers.assess(analysis, found_count)       -> {
--     required, found, sufficient, shortfall,
--     peak, vanilla_at_peak, play_sound_at_peak,
--   }
--
-- `analysis` is the value produced by nbs.analyze (a pure analysis table); this
-- module must NEVER recompute the peak or the bucket split -- it is a pure
-- formula over fields analyze already produced.
--
-- THE FORMULA
-- -----------
--   required = ceil(vanilla_notes_at_peak / 8) + play_sound_notes_at_peak
--
-- WHY THE SECOND TERM IS ADDITIVE (the invariant most likely to be "optimised"
-- away): CC:Tweaked's speaker accepts up to 8 playNote calls per game tick, but
-- only ONE playSound per tick.  A single trumpet note therefore consumes an
-- entire speaker-tick, so the playSound count is added as a whole, NOT divided
-- by 8 and NOT folded into the same ceiling.  Cases 3 and 4 below pin this down.
--
-- CUSTOM INSTRUMENTS DO NOT COUNT.  A custom-instrument note is refused at
-- playback, so it must not inflate the requirement.  Both analyze buckets
-- already exclude custom ids, so the formula has no third term (case 5).
--
-- Fixture loading mirrors tests/nbs/analyze_spec.lua.

local speakers = require("nbs.speakers")
local analyze = require("nbs.analyze")
local decode = require("nbs.decode")

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

local function list_fixtures(dir)
  local is_windows = package.config:sub(1, 1) == "\\"
  local command
  if is_windows then
    command = 'dir /b "' .. dir:gsub("/", "\\") .. '" 2>nul'
  else
    command = 'ls -1 "' .. dir .. '" 2>/dev/null'
  end
  local names = {}
  local pipe = io.popen(command)
  if not pipe then
    return names
  end
  local output = pipe:read("*a") or ""
  pipe:close()
  for line in output:gmatch("[^\r\n]+") do
    local name = line:gsub("%s+$", "")
    if name:match("%.nbs$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- ---------------------------------------------------------------------------
-- Tiny analysis-table builder.  Only the fields the formula may read (plus
-- peak_concurrent, which it must NOT read) are present, so a stray read is
-- visible as a nil-driven failure.
-- ---------------------------------------------------------------------------

local function analysis(vanilla, play_sound, peak)
  return {
    peak_concurrent = peak or 0,
    vanilla_notes_at_peak = vanilla or 0,
    play_sound_notes_at_peak = play_sound or 0,
  }
end

local function req(vanilla, play_sound, peak)
  return speakers.required_count(analysis(vanilla, play_sound, peak))
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("nbs.speakers constants", function()
  it("1. MAX_NOTES_PER_TICK is 8", function()
    expect.equal(speakers.MAX_NOTES_PER_TICK, 8)
  end)
end)

describe("nbs.speakers required_count ceiling boundaries", function()
  it("2. the vanilla-only boundary table", function()
    expect.equal(req(8, 0), 1)   -- exactly one speaker's worth of notes
    expect.equal(req(9, 0), 2)   -- one over spills into a second speaker
    expect.equal(req(16, 0), 2)  -- exactly two speakers' worth
    expect.equal(req(17, 0), 3)  -- one over spills into a third
    expect.equal(req(0, 0), 0)   -- silence needs no speaker
  end)
end)

describe("nbs.speakers the playSound additive trap", function()
  it("3. THE ADDITIVE TRAP: 1 vanilla + 1 trumpet needs 2, NOT 1", function()
    local value = req(1, 1)
    expect.equal(value, 2)

    -- A future "simplification" back to ceil(peak / 8) would yield 1 here and
    -- silently drop the trumpet note; this assertion makes that regression loud.
    expect.truthy(value ~= 1)

    expect.equal(req(8, 1), 2)   -- 8 vanilla = 1 speaker, +1 trumpet-tick
    expect.equal(req(8, 2), 3)   -- the two trumpets take two separate ticks

    io.write(string.format(
      "    CASE3 additive trap: (1,1)=%d (NOT 1) (8,1)=%d (8,2)=%d\n",
      value, req(8, 1), req(8, 2)))
  end)
end)

describe("nbs.speakers playSound-only windows", function()
  it("4. trumpets alone each consume a whole speaker-tick", function()
    expect.equal(req(0, 2), 2)
    -- 8 trumpets are 8 separate speaker-ticks, NOT one speaker's worth.
    expect.equal(req(0, 8), 8)
  end)
end)

describe("nbs.speakers custom instruments", function()
  it("5. a custom-only peak needs ZERO speakers and peak does not leak", function()
    -- analyze reports the custom notes in peak_concurrent but in NEITHER bucket.
    -- The formula must read only the buckets, so the result is 0.
    local value = req(0, 0, 5)
    expect.equal(value, 0)
    expect.truthy(speakers.required_count(analysis(0, 0, 100)) == 0)

    io.write(string.format(
      "    CASE5 custom-only: peak=5 vanilla=0 playSound=0 -> required=%d (peak leaked? %s)\n",
      value, tostring(value ~= 0)))
  end)
end)

describe("nbs.speakers assess", function()
  it("6. required=2, found=2 -> sufficient, no shortfall", function()
    local result = speakers.assess(analysis(0, 2, 2), 2)
    expect.equal(result.required, 2)
    expect.equal(result.found, 2)
    expect.equal(result.sufficient, true)
    expect.equal(result.shortfall, 0)
  end)

  it("7. required=2, found=1 -> insufficient, shortfall 1", function()
    local result = speakers.assess(analysis(0, 2, 2), 1)
    expect.equal(result.required, 2)
    expect.equal(result.found, 1)
    expect.equal(result.sufficient, false)
    expect.equal(result.shortfall, 1)
  end)

  it("8. required=1, found=4 -> sufficient, shortfall clamped to 0", function()
    local result = speakers.assess(analysis(8, 0, 8), 4)
    expect.equal(result.required, 1)
    expect.equal(result.found, 4)
    expect.equal(result.sufficient, true)
    expect.equal(result.shortfall, 0)
  end)

  it("9. required=1, found=0 -> insufficient, shortfall 1, does not raise", function()
    local called, result = pcall(function()
      return speakers.assess(analysis(8, 0, 8), 0)
    end)
    expect.truthy(called)
    expect.equal(result.required, 1)
    expect.equal(result.found, 0)
    expect.equal(result.sufficient, false)
    expect.equal(result.shortfall, 1)
  end)

  it("10. passes peak / vanilla_at_peak / play_sound_at_peak through unchanged", function()
    local subject = analysis(5, 3, 8)
    local result = speakers.assess(subject, 1)
    expect.equal(result.required, 4) -- ceil(5/8)=1, +3 playSound = 4
    expect.equal(result.peak, 8)
    expect.equal(result.vanilla_at_peak, 5)
    expect.equal(result.play_sound_at_peak, 3)
  end)
end)

describe("nbs.speakers purity", function()
  it("12. required_count is pure: stable answer, input not mutated", function()
    local subject = analysis(3, 2, 5)

    local before = {}
    local before_count = 0
    for key, value in pairs(subject) do
      before[key] = value
      before_count = before_count + 1
    end

    local first = speakers.required_count(subject)
    local second = speakers.required_count(subject)
    expect.equal(second, first)

    local after_count = 0
    for key, value in pairs(subject) do
      after_count = after_count + 1
      expect.truthy(before[key] ~= nil)      -- no new keys added
      expect.equal(value, before[key])       -- no existing value changed
    end
    expect.equal(after_count, before_count)
  end)
end)

describe("nbs.speakers totality fuzz", function()
  it("13. sweeps 0..40 x 0..40: always a non-negative integer, never raises", function()
    for vanilla = 0, 40 do
      for play_sound = 0, 40 do
        local subject = analysis(vanilla, play_sound, vanilla + play_sound)
        local ok, value = pcall(speakers.required_count, subject)
        if not ok then
          error(string.format(
            "required_count raised for vanilla=%d play_sound=%d: %s",
            vanilla, play_sound, tostring(value)), 2)
        end
        expect.equal(type(value), "number")
        expect.truthy(is_integer(value))
        expect.truthy(value >= 0)
      end
    end
  end)
end)

describe("nbs.speakers real fixtures", function()
  it("11. every .nbs fixture computes a non-negative integer requirement", function()
    local names = list_fixtures(FIXTURES_DIR)
    expect.truthy(#names >= 10)

    local rows = {}
    for _, name in ipairs(names) do
      local bytes = read_file(join(FIXTURES_DIR, name))
      expect.truthy(bytes ~= nil)

      local called, payload = pcall(function()
        local decoded = decode.decode(bytes)
        expect.equal(decoded.ok, true)
        local analysed = analyze.analyze(decoded.song)
        return {
          version = decoded.song.header.version,
          total_notes = analysed.total_notes,
          analysed = analysed,
          required = speakers.required_count(analysed),
        }
      end)
      expect.truthy(called)

      expect.equal(type(payload.required), "number")
      expect.truthy(is_integer(payload.required))
      expect.truthy(payload.required >= 0)
      -- Every current fixture peaks well under 8 vanilla notes and has no
      -- playSound notes, so each needs exactly one speaker.  Pinning this makes
      -- a regression that grows the requirement visible.
      expect.equal(payload.required, 1)

      rows[#rows + 1] = string.format(
        "    FIXTURE %-28s v=%s notes=%-4d peak=%-3d vanilla=%-3d playSound=%-3d required=%d",
        name, tostring(payload.version), payload.total_notes,
        payload.analysed.peak_concurrent, payload.analysed.vanilla_notes_at_peak,
        payload.analysed.play_sound_notes_at_peak, payload.required)
    end

    for _, row in ipairs(rows) do
      io.write(row .. "\n")
    end
  end)
end)
