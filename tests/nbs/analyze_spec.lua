-- tests/nbs/analyze_spec.lua
--
-- Tier-1 spec for nbs/analyze.lua -- the PURE load-time analysis pass.
--
-- FROZEN PUBLIC INTERFACE UNDER TEST
-- ----------------------------------
--   local analyze = require("nbs.analyze")
--   analyze.analyze(song) -> result          -- pure: no clock, no I/O, no globals
--
--   result = {
--     total_notes              -- integer, #song.notes
--     ticks_per_second         -- number, header.tempo_ticks_per_second
--     tick_ms                  -- number, 1000 / ticks_per_second
--     peak_concurrent          -- integer, max simultaneous notes in any 50 ms window
--     peak_window_ms           -- 50 (constant)
--     vanilla_notes_at_peak    -- integer, peak-window notes with instrument id 0..15
--     play_sound_notes_at_peak -- integer, peak-window notes with id 16..19 when v6
--     has_extended_range       -- boolean, any key outside 33..57
--     min_key, max_key         -- integers over all notes (0 and 0 when empty)
--     loop = { loop, max_loop_count, loop_start_tick }  -- copied from the header
--   }
--
-- THE CLOCK DISTINCTION THIS SPEC PINS DOWN
-- -----------------------------------------
-- NBS tempo is ticks per second, so ONE NBS TICK is (1000 / ticks_per_second) ms.
-- The speaker ceiling is enforced per MINECRAFT game tick (50 ms), NOT per NBS
-- tick.  At 10 NBS ticks/second one NBS tick is 100 ms -- TWO game windows -- so
-- two notes on consecutive NBS ticks are further apart than one window.  Cases 3
-- and 4 below exist specifically to catch a NBS-tick-as-window conflation.
--
-- Fixture loading mirrors tests/nbs/decode_spec.lua.

local analyze = require("nbs.analyze")
local decode = require("nbs.decode")
local instrument_table = require("nbs.instrument_table")
local speakers = require("nbs.speakers")

-- ---------------------------------------------------------------------------
-- Project root + fixture helpers (same convention as decode_spec.lua)
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
-- Synthetic song builders.  A note record carries exactly the fields analyze
-- may read; the header carries tempo + vanilla-instrument count + loop metadata.
-- ---------------------------------------------------------------------------

local function n(tick, instrument, key)
  return {
    tick = tick,
    instrument = instrument,
    key = key,
    velocity = 100,
    panning = 100,
    pitch = 0,
  }
end

local function song(opts)
  opts = opts or {}
  return {
    header = {
      tempo_ticks_per_second = opts.tps or 10,
      vanilla_instrument_count = opts.vic or 16,
      loop = opts.loop,
      max_loop_count = opts.max_loop_count,
      loop_start_tick = opts.loop_start_tick,
    },
    notes = opts.notes or {},
  }
end

-- Deterministic canonical fingerprint of a result, for the determinism case.
local function fingerprint(r)
  return table.concat({
    "total=" .. tostring(r.total_notes),
    "tps=" .. tostring(r.ticks_per_second),
    "tick_ms=" .. tostring(r.tick_ms),
    "peak=" .. tostring(r.peak_concurrent),
    "pwm=" .. tostring(r.peak_window_ms),
    "v=" .. tostring(r.vanilla_notes_at_peak),
    "ps=" .. tostring(r.play_sound_notes_at_peak),
    "er=" .. tostring(r.has_extended_range),
    "min=" .. tostring(r.min_key),
    "max=" .. tostring(r.max_key),
    "loop=" .. tostring(r.loop.loop),
    "mlc=" .. tostring(r.loop.max_loop_count),
    "lst=" .. tostring(r.loop.loop_start_tick),
  }, "|")
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("nbs.analyze scalar summary", function()
  it("1. a single vanilla note at tick 0 key 45", function()
    local result = analyze.analyze(song({ notes = { n(0, 1, 45) } }))

    expect.equal(result.total_notes, 1)
    expect.equal(result.peak_concurrent, 1)
    expect.equal(result.peak_window_ms, 50)
    expect.equal(result.vanilla_notes_at_peak, 1)
    expect.equal(result.play_sound_notes_at_peak, 0)
    expect.equal(result.has_extended_range, false)
    expect.equal(result.min_key, 45)
    expect.equal(result.max_key, 45)
  end)

  it("2. an empty song reports zeros and does not raise", function()
    local result = analyze.analyze(song({ notes = {} }))

    expect.equal(result.total_notes, 0)
    expect.equal(result.peak_concurrent, 0)
    expect.equal(result.peak_window_ms, 50)
    expect.equal(result.vanilla_notes_at_peak, 0)
    expect.equal(result.play_sound_notes_at_peak, 0)
    expect.equal(result.min_key, 0)
    expect.equal(result.max_key, 0)
    expect.equal(result.has_extended_range, false)
  end)

  it("reports ticks_per_second and the derived tick_ms", function()
    local result = analyze.analyze(song({ tps = 10, notes = { n(0, 1, 45) } }))
    expect.equal(result.ticks_per_second, 10)
    expect.near(result.tick_ms, 100)

    local result25 = analyze.analyze(song({ tps = 40, notes = { n(0, 1, 45) } }))
    expect.equal(result25.ticks_per_second, 40)
    expect.near(result25.tick_ms, 25)
  end)
end)

describe("nbs.analyze 50 ms window vs NBS tick", function()
  it("3a. CLOCK TRAP: 10 notes on ONE NBS tick share one instant", function()
    local notes = {}
    for index = 1, 10 do
      notes[#notes + 1] = n(5, 1, 45)
    end
    local result = analyze.analyze(song({ tps = 10, notes = notes }))

    expect.near(result.tick_ms, 100)
    expect.equal(result.peak_concurrent, 10)
    io.write("    CASE3a tps=10 tick_ms=100 one-instant peak="
      .. result.peak_concurrent .. "\n")
  end)

  it("3b. CLOCK TRAP: 10 notes on TEN consecutive NBS ticks peak at 1", function()
    -- tick_ms == 100, so consecutive NBS ticks are 100 ms apart -- MORE than the
    -- 50 ms window.  Using the NBS tick as the window would wrongly report 10.
    local notes = {}
    for index = 0, 9 do
      notes[#notes + 1] = n(5 + index, 1, 45)
    end
    local result = analyze.analyze(song({ tps = 10, notes = notes }))

    expect.near(result.tick_ms, 100)
    expect.equal(result.peak_concurrent, 1)
    io.write("    CASE3b tps=10 tick_ms=100 ten-consecutive-ticks peak="
      .. result.peak_concurrent .. "\n")
  end)

  it("4a. STRICT BOUNDARY: 50 ms apart is NOT inside one window", function()
    -- tick_ms == 50 exactly; window test is `diff < 50`, so tick 0 and tick 1
    -- (50 ms apart) are in SEPARATE windows.
    local result = analyze.analyze(song({
      tps = 20,
      notes = { n(0, 1, 45), n(1, 1, 45) },
    }))

    expect.near(result.tick_ms, 50)
    expect.equal(result.peak_concurrent, 1)
    io.write("    CASE4a tick_ms=50 diff=50 peak=" .. result.peak_concurrent .. "\n")
  end)

  it("4b. STRICT BOUNDARY: 25 ms apart is inside one window", function()
    local result = analyze.analyze(song({
      tps = 40,
      notes = { n(0, 1, 45), n(1, 1, 45) },
    }))

    expect.near(result.tick_ms, 25)
    expect.equal(result.peak_concurrent, 2)
    io.write("    CASE4b tick_ms=25 diff=25 peak=" .. result.peak_concurrent .. "\n")
  end)

  it("5. two bursts 100 ms apart do not merge", function()
    local notes = {}
    for index = 1, 10 do
      notes[#notes + 1] = n(0, 1, 45)
    end
    for index = 1, 10 do
      notes[#notes + 1] = n(100, 1, 45)
    end
    local result = analyze.analyze(song({ tps = 1000, notes = notes }))

    expect.near(result.tick_ms, 1)
    expect.equal(result.peak_concurrent, 10)
    io.write("    CASE5 tick_ms=1 bursts-at-0-and-100 peak="
      .. result.peak_concurrent .. "\n")
  end)
end)

describe("nbs.analyze instrument buckets", function()
  it("6. a mixed window splits into vanilla + play_sound", function()
    local result = analyze.analyze(song({
      vic = 20,
      notes = {
        n(0, 0, 45), n(0, 5, 45), n(0, 15, 45), -- 3 vanilla
        n(0, 16, 45), n(0, 17, 45),             -- 2 trumpets (v6)
      },
    }))

    expect.equal(result.peak_concurrent, 5)
    expect.equal(result.vanilla_notes_at_peak, 3)
    expect.equal(result.play_sound_notes_at_peak, 2)
  end)

  it("7. custom notes count toward the peak but NEITHER bucket", function()
    local result = analyze.analyze(song({
      vic = 20,
      notes = {
        n(0, 0, 45),  -- vanilla
        n(0, 20, 45), -- custom (id >= vic)
        n(0, 21, 45), -- custom
      },
    }))

    expect.equal(result.peak_concurrent, 3)
    expect.equal(result.vanilla_notes_at_peak, 1)
    expect.equal(result.play_sound_notes_at_peak, 0)
  end)

  it("7b. a custom-only window keeps peak_concurrent but both buckets 0", function()
    local result = analyze.analyze(song({
      vic = 20,
      notes = { n(0, 20, 45), n(0, 21, 45) },
    }))

    expect.equal(result.peak_concurrent, 2)
    expect.equal(result.vanilla_notes_at_peak, 0)
    expect.equal(result.play_sound_notes_at_peak, 0)
  end)

  it("8. v5: ids 16..19 are CUSTOM, not trumpets", function()
    local result = analyze.analyze(song({
      vic = 16,
      notes = { n(0, 16, 45), n(0, 17, 45), n(0, 18, 45), n(0, 19, 45) },
    }))

    expect.equal(result.peak_concurrent, 4)
    expect.equal(result.vanilla_notes_at_peak, 0)
    expect.equal(result.play_sound_notes_at_peak, 0)
  end)
end)

describe("nbs.analyze all-custom detection", function()
  it("21. a song whose EVERY note is a custom instrument reports all_notes_custom", function()
    local result = analyze.analyze(song({
      vic = 16,
      notes = { n(0, 16, 45), n(1, 17, 45), n(2, 20, 45) },
    }))

    expect.equal(result.all_notes_custom, true)
    expect.equal(result.vanilla_notes_at_peak, 0)
    expect.equal(result.play_sound_notes_at_peak, 0)
    io.write("    CASE21 all-custom=" .. tostring(result.all_notes_custom) .. "\n")
  end)

  it("21b. a single playable note ANYWHERE (not just at the peak) makes it false", function()
    -- The custom note sits at tick 0 (the earliest, and therefore the reported
    -- peak window); the vanilla note sits later.  The PEAK buckets are 0/0, but
    -- the song is NOT all-custom, so the flag must still be false.
    local result = analyze.analyze(song({
      vic = 16,
      notes = { n(0, 16, 45), n(5, 0, 45) },
    }))

    expect.equal(result.vanilla_notes_at_peak, 0)
    expect.equal(result.all_notes_custom, false)
  end)

  it("21c. an empty song is not all-custom", function()
    local result = analyze.analyze(song({ notes = {} }))
    expect.equal(result.all_notes_custom, false)
  end)
end)

describe("nbs.analyze extended range", function()
  it("9. a low key out of range", function()
    local result = analyze.analyze(song({ notes = { n(0, 1, 20) } }))
    expect.equal(result.has_extended_range, true)
    expect.equal(result.min_key, 20)
    expect.equal(result.max_key, 20)
  end)

  it("10. a high key out of range", function()
    local result = analyze.analyze(song({ notes = { n(0, 1, 60) } }))
    expect.equal(result.has_extended_range, true)
    expect.equal(result.min_key, 60)
    expect.equal(result.max_key, 60)
  end)

  it("11a. the two-octave bounds 33 and 57 are inclusive", function()
    local result = analyze.analyze(song({ notes = { n(0, 1, 33), n(0, 1, 57) } }))
    expect.equal(result.has_extended_range, false)
    expect.equal(result.min_key, 33)
    expect.equal(result.max_key, 57)
  end)

  it("11b. one step below/above the bounds is out of range", function()
    local low = analyze.analyze(song({ notes = { n(0, 1, 32) } }))
    expect.equal(low.has_extended_range, true)

    local high = analyze.analyze(song({ notes = { n(0, 1, 58) } }))
    expect.equal(high.has_extended_range, true)
  end)
end)

describe("nbs.analyze loop passthrough", function()
  it("12a. a v4/v5 fixture copies loop/max_loop_count/loop_start_tick", function()
    local bytes = read_file(join(FIXTURES_DIR, "compat_demo_song.nbs"))
    expect.truthy(bytes ~= nil)
    local decoded = decode.decode(bytes)
    expect.equal(decoded.ok, true)
    expect.equal(decoded.song.header.version, 4)

    local result = analyze.analyze(decoded.song)
    expect.equal(result.loop.loop, decoded.song.header.loop)
    expect.equal(result.loop.max_loop_count, decoded.song.header.max_loop_count)
    expect.equal(result.loop.loop_start_tick, decoded.song.header.loop_start_tick)
  end)

  it("12b. a legacy v0 fixture yields all three loop fields as nil", function()
    local bytes = read_file(join(FIXTURES_DIR, "compat_old_demo_song.nbs"))
    expect.truthy(bytes ~= nil)
    local decoded = decode.decode(bytes)
    expect.equal(decoded.ok, true)
    expect.equal(decoded.song.header.version, 0)

    local result = analyze.analyze(decoded.song)
    expect.equal(result.loop.loop, nil)
    expect.equal(result.loop.max_loop_count, nil)
    expect.equal(result.loop.loop_start_tick, nil)
  end)
end)

describe("nbs.analyze purity and determinism", function()
  it("13. ten runs on the same song are identical", function()
    local subject = song({
      tps = 10,
      vic = 20,
      loop = 0,
      max_loop_count = 0,
      loop_start_tick = 0,
      notes = {
        n(0, 0, 45), n(0, 16, 45), n(0, 21, 45),
        n(3, 5, 33), n(3, 5, 57), n(10, 1, 20),
      },
    })

    local first = fingerprint(analyze.analyze(subject))
    for _ = 1, 10 do
      expect.equal(fingerprint(analyze.analyze(subject)), first)
    end
  end)

  it("14. analyze does not mutate its input", function()
    local subject = song({
      notes = { n(0, 1, 45), n(4, 2, 50), n(9, 3, 40) },
    })

    local before = {}
    for key, value in pairs(subject.notes[1]) do
      before[key] = value
    end
    local before_len = #subject.notes

    analyze.analyze(subject)

    expect.equal(#subject.notes, before_len)
    for key, value in pairs(before) do
      expect.equal(subject.notes[1][key], value)
    end
    for key in pairs(subject.notes[1]) do
      expect.truthy(before[key] ~= nil)
    end
  end)
end)

describe("nbs.analyze tied maximum", function()
  it("16. the EARLIEST window that attains the maximum supplies the split", function()
    -- Two windows each attain peak 2.  The earliest (tick 0) is 2 vanilla notes;
    -- the later (tick 10) is 1 vanilla + 1 trumpet.  The reported split must come
    -- from the earliest window: vanilla 2, play_sound 0.
    local result = analyze.analyze(song({
      tps = 100,
      vic = 20,
      notes = {
        n(0, 0, 45), n(0, 1, 45),   -- window A: 2 vanilla
        n(10, 2, 45), n(10, 16, 45), -- window B: 1 vanilla + 1 trumpet
      },
    }))

    expect.near(result.tick_ms, 10)
    expect.equal(result.peak_concurrent, 2)
    expect.equal(result.vanilla_notes_at_peak, 2)
    expect.equal(result.play_sound_notes_at_peak, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 17-19. classification agrees with nbs.instrument_table (B3)
--
-- The classifier must have ONE owner.  analyze.lua used to re-implement the
-- rule with hardcoded constants while instrument_table.resolve() used the
-- file's own vanilla_instrument_count -- and the two disagreed for counts 10
-- and 17..19.  A single-note song makes analyze's bucket observable: the note
-- lands in vanilla_notes_at_peak, play_sound_notes_at_peak, or neither (custom).
-- ---------------------------------------------------------------------------

describe("nbs.analyze instrument buckets agree with nbs.instrument_table", function()
  -- Which bucket analyze's result implies for a ONE-note song.
  local function observed_bucket(instrument, count)
    local result = analyze.analyze(song({
      vic = count,
      notes = { n(0, instrument, 45) },
    }))
    if result.vanilla_notes_at_peak == 1 then
      return "vanilla"
    end
    if result.play_sound_notes_at_peak == 1 then
      return "play_sound"
    end
    return "custom"
  end

  -- The bucket instrument_table.resolve() implies for the same pair.
  local function expected_bucket(instrument, count)
    local kind = instrument_table.resolve(instrument, count).kind
    if kind == "play_note" then
      return "vanilla"
    end
    return kind
  end

  it("17. CROSS PRODUCT: counts {10,16,17,18,19,20} x ids {0,15,16,17,19,20,25} classify identically in analyze and resolve", function()
    local counts = { 10, 16, 17, 18, 19, 20 }
    local ids = { 0, 15, 16, 17, 19, 20, 25 }
    local rows = {}
    for count_index = 1, #counts do
      local count = counts[count_index]
      for id_index = 1, #ids do
        local id = ids[id_index]
        local observed = observed_bucket(id, count)
        local expected = expected_bucket(id, count)
        expect.equal(observed, expected)
        rows[#rows + 1] = string.format("%d/%d=%s", count, id, observed)
      end
    end
    io.write("    CASE17 cross product: " .. table.concat(rows, " ") .. "\n")
  end)

  it("18. LEGACY v0 (count 10): ids 10..15 are CUSTOM, so they inflate neither the vanilla bucket nor the requirement", function()
    local result = analyze.analyze(song({
      vic = 10,
      notes = {
        n(0, 0, 45), n(0, 1, 45), n(0, 2, 45),
        n(0, 10, 45), n(0, 11, 45), n(0, 12, 45),
        n(0, 13, 45), n(0, 14, 45), n(0, 15, 45),
      },
    }))

    expect.equal(result.peak_concurrent, 9)
    expect.equal(result.vanilla_notes_at_peak, 3)
    expect.equal(result.play_sound_notes_at_peak, 0)

    -- One speaker is enough; counting ids 10..15 as vanilla (9 at peak) would
    -- wrongly demand two speakers and raise a bogus speakers warning.
    local assessed = speakers.assess(result, 1)
    expect.equal(assessed.required, 1)
    expect.equal(assessed.sufficient, true)

    io.write(string.format(
      "    CASE18 legacy count=10: peak=%d vanilla=%d playSound=%d required=%d sufficient=%s\n",
      result.peak_concurrent, result.vanilla_notes_at_peak,
      result.play_sound_notes_at_peak, assessed.required,
      tostring(assessed.sufficient)))
  end)

  it("19. TRUMPET BOUNDARY (counts 17..19): id 16 is play_sound and adds a whole speaker-tick", function()
    local counts = { 17, 18, 19 }
    for count_index = 1, #counts do
      local count = counts[count_index]
      local result = analyze.analyze(song({
        vic = count,
        notes = { n(0, 0, 45), n(0, 16, 45) },
      }))

      expect.equal(result.peak_concurrent, 2)
      expect.equal(result.vanilla_notes_at_peak, 1)
      expect.equal(result.play_sound_notes_at_peak, 1)

      -- ceil(1/8) + 1 == 2: the trumpet needs its OWN speaker-tick.
      local assessed = speakers.assess(result, 2)
      expect.equal(assessed.required, 2)
      expect.equal(assessed.sufficient, true)

      io.write(string.format(
        "    CASE19 count=%d: vanilla=%d playSound=%d required=%d\n",
        count, result.vanilla_notes_at_peak, result.play_sound_notes_at_peak,
        assessed.required))
    end
  end)
end)

describe("nbs.analyze real fixtures", function()
  it("15. every .nbs fixture analyzes without error and reports a sane peak", function()
    local names = list_fixtures(FIXTURES_DIR)
    expect.truthy(#names >= 10)

    local rows = {}
    for _, name in ipairs(names) do
      local bytes = read_file(join(FIXTURES_DIR, name))
      expect.truthy(bytes ~= nil)

      local called, result = pcall(function()
        local decoded = decode.decode(bytes)
        expect.equal(decoded.ok, true)
        local analysed = analyze.analyze(decoded.song)
        return { decoded = decoded, analysed = analysed }
      end)
      expect.truthy(called)

      local analysed = result.analysed
      expect.equal(type(analysed), "table")
      expect.equal(type(analysed.peak_concurrent), "number")
      expect.truthy(analysed.peak_concurrent >= 0)
      expect.equal(analysed.total_notes, #result.decoded.song.notes)
      expect.equal(analysed.peak_window_ms, 50)

      rows[#rows + 1] = string.format(
        "    FIXTURE %-28s v=%s notes=%-4d peak=%-4d vanilla=%-4d playSound=%-3d extRange=%-5s minKey=%-3d maxKey=%d",
        name, tostring(result.decoded.song.header.version), analysed.total_notes,
        analysed.peak_concurrent, analysed.vanilla_notes_at_peak,
        analysed.play_sound_notes_at_peak, tostring(analysed.has_extended_range),
        analysed.min_key, analysed.max_key)
    end

    for _, row in ipairs(rows) do
      io.write(row .. "\n")
    end

    -- Baseline anchors called out by the task.
    local simple = read_file(join(FIXTURES_DIR, "simple.nbs"))
    local simple_decoded = decode.decode(simple)
    expect.equal(simple_decoded.ok, true)
    expect.equal(simple_decoded.song.header.version, 6)
    local simple_result = analyze.analyze(simple_decoded.song)
    expect.equal(simple_result.total_notes, 49)

    local demo = read_file(join(FIXTURES_DIR, "compat_demo_song.nbs"))
    local demo_decoded = decode.decode(demo)
    expect.equal(demo_decoded.ok, true)
    local demo_result = analyze.analyze(demo_decoded.song)
    expect.equal(demo_result.total_notes, 76)
  end)
end)
