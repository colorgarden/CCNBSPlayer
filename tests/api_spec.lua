-- tests/api_spec.lua
--
-- Tier-1 spec for ccnbs.lua -- THE PUBLIC LIBRARY MODULE AND ITS CONTRACT.
-- Written FIRST, before ccnbs.lua exists (strict TDD: watch it fail).
--
-- WHY A ROOT-LEVEL ccnbs.lua
-- ---------------------------------------------------------------------------
-- The entry point lives at the PROJECT ROOT as `ccnbs.lua`, NOT at
-- `nbs/init.lua`: package.path is not guaranteed to contain `?/init.lua` on the
-- target (plain Lua and CC:Tweaked differ), whereas a root-level `ccnbs.lua`
-- resolves under the plain `./?.lua` pattern that tests/run.lua guarantees.
--
-- FROZEN PUBLIC INTERFACE (asserted here)
--   local ccnbs = require("ccnbs")
--   ccnbs.decode(bytes)        -> same shape as nbs.decode.decode
--   ccnbs.analyze(song)        -> same shape as nbs.analyze.analyze
--   ccnbs.plan(song, analysis) -> the event array
--   ccnbs.discover_speakers()  -> thin pass-through to speaker.discover()
--   ccnbs.version              -> string
--   ccnbs.play(song, opts) -> session
--
--   session.cancel(), session.is_playing(), session.analysis, session.plan,
--   session.assignment, session.stats()
--
-- WARNING AGGREGATION
-- ---------------------------------------------------------------------------
-- `play` funnels EVERY warning class through the single on_warning(code, args)
-- callback, each BARE code AT MOST ONCE per session:
--   "extended-range"    (load-time property; BEFORE the first event)
--   "speakers"          (fan-out dropped something; args from warning_args)
--   "custom-instrument" (a custom event was refused;  args {count=...})
--   "play-sound-pitch"  (a trumpet pitch was clamped)
--   "tempo-clamp"       (a delay fell below the timer granularity)
-- ccnbs.lua does NOT format WARN[...] strings -- player/warnings.lua owns that.
--
-- THE CONVENTION SPLIT (DO NOT "UNIFY" IT)
-- ---------------------------------------------------------------------------
-- speaker records and the dispatcher are COLON-style: rec:play_note(...),
-- d:event(ev, speaker).  clock objects and the clock module are DOT-style:
-- vc.after(delay, fn), vc:now_ms() is WRONG, clock.advance_to(vc, target).
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt (no `//`, no bitwise operators,
-- no utf8.*, no os.exit, no collectgarbage).

local ccnbs = require("ccnbs")
local decode = require("nbs.decode")
local analyze = require("nbs.analyze")
local plan = require("player.plan")
local fanout = require("player.fanout")
local speaker = require("player.speaker")
local clock = require("player.clock")

-- ---------------------------------------------------------------------------
-- Paths
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

local FIXTURES = join(ROOT, "tests/fixtures")
local MALFORMED = join(ROOT, "tests/corpus/malformed")
local API_DOC = join(ROOT, "docs/API.md")

local function read_bytes(path)
  local handle = assert(io.open(path, "rb"), "cannot open " .. path)
  local data = handle:read("*a")
  handle:close()
  return data
end

local function load_fixture(name)
  local decoded = decode.decode(read_bytes(FIXTURES .. "/" .. name))
  assert(decoded.ok, "fixture failed to decode: " .. name)
  return decoded.song
end

-- ---------------------------------------------------------------------------
-- Synthetic songs (decode-independent, so warning cases are exact)
-- ---------------------------------------------------------------------------

local function note(tick, layer, instrument, key, velocity, pitch)
  return {
    tick = tick,
    layer = layer,
    instrument = instrument,
    key = key,
    velocity = velocity or 100,
    panning = 100,
    pitch = pitch or 0,
  }
end

-- make_song(notes, opts): a minimal decoded-shaped song.  Notes SHOULD start at
-- tick >= 1 in the warning-free cases, because an event at t_ms = 0 forces a
-- sub-granularity delay and legitimately emits "tempo-clamp".
local function make_song(notes, opts)
  opts = opts or {}
  return {
    header = {
      tempo_ticks_per_second = opts.tps or 10,
      vanilla_instrument_count = opts.vanilla or 20,
    },
    layers = { { name = "layer-0", volume = 100 } },
    notes = notes,
    custom_instruments = {},
  }
end

local function code_count(codes, wanted)
  local total = 0
  for index = 1, #codes do
    if codes[index] == wanted then
      total = total + 1
    end
  end
  return total
end

-- ---------------------------------------------------------------------------
-- 1. Module shape
-- ---------------------------------------------------------------------------

describe("ccnbs public module shape", function()
  it("exposes the frozen entry points with the right types", function()
    expect.equal(type(ccnbs.decode), "function")
    expect.equal(type(ccnbs.analyze), "function")
    expect.equal(type(ccnbs.plan), "function")
    expect.equal(type(ccnbs.play), "function")
    expect.equal(type(ccnbs.discover_speakers), "function")
    expect.equal(type(ccnbs.version), "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- 2 & 3. decode pass-through (success and failure)
-- ---------------------------------------------------------------------------

describe("decode pass-through", function()
  it("returns ok=true and the same header.version as nbs.decode", function()
    local bytes = read_bytes(FIXTURES .. "/simple.nbs")
    local direct = decode.decode(bytes)
    local via = ccnbs.decode(bytes)
    expect.equal(direct.ok, true)
    expect.equal(via.ok, true)
    expect.equal(via.song.header.version, direct.song.header.version)
  end)

  it("passes a malformed file's typed error code through unchanged", function()
    local bytes = read_bytes(MALFORMED .. "/version_9.nbs")
    local direct = decode.decode(bytes)
    local via = ccnbs.decode(bytes)
    expect.equal(direct.ok, false)
    expect.equal(via.ok, false)
    expect.equal(via.error.code, direct.error.code)
  end)
end)

-- ---------------------------------------------------------------------------
-- 4. analyze + plan pass-through
-- ---------------------------------------------------------------------------

describe("analyze and plan pass-through", function()
  it("matches nbs.analyze field-for-field and plans one event per note", function()
    local song = load_fixture("simple.nbs")
    local direct = analyze.analyze(song)
    local via = ccnbs.analyze(song)

    local fields = {
      "total_notes", "ticks_per_second", "tick_ms", "peak_concurrent",
      "peak_window_ms", "vanilla_notes_at_peak", "play_sound_notes_at_peak",
      "has_extended_range", "min_key", "max_key",
    }
    for index = 1, #fields do
      local key = fields[index]
      expect.equal(via[key], direct[key])
    end

    local events = ccnbs.plan(song, via)
    expect.equal(#events, #song.notes)
    expect.deep_equal(events, plan.plan(song, direct))
  end)
end)

-- ---------------------------------------------------------------------------
-- 5. Full end-to-end with injected seams
-- ---------------------------------------------------------------------------

describe("full end-to-end with injected seams", function()
  it("fires every non-custom event exactly once and on_event in frozen order", function()
    local song = load_fixture("simple.nbs")
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local seen = {}

    local started = os.clock()
    local session = ccnbs.play(song, {
      speakers = { left, right },
      clock = vclock,
      on_event = function(event)
        seen[#seen + 1] = event
      end,
    })
    -- A single synchronous block drives the whole song: no real clock, no sleep.
    clock.advance_to(vclock, 1000000)
    local elapsed = os.clock() - started

    -- on_event: once per event, in frozen plan order.
    expect.equal(#seen, #session.plan)
    for index = 1, #session.plan do
      expect.equal(seen[index].tick_index, session.plan[index].tick_index)
      expect.equal(seen[index].layer_index, session.plan[index].layer_index)
      expect.equal(seen[index].note_index, session.plan[index].note_index)
    end

    -- One speaker call per non-custom event, across both mocks.
    local non_custom = 0
    for index = 1, #session.plan do
      if session.plan[index].kind ~= "custom" then
        non_custom = non_custom + 1
      end
    end
    local calls = #left.calls + #right.calls
    expect.equal(calls, non_custom)

    -- Completes with no real time elapsed.
    expect.truthy(elapsed < 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- 6. Warning aggregation is deduplicated by code
-- ---------------------------------------------------------------------------

describe("warning aggregation", function()
  it("forwards each distinct code exactly once", function()
    -- tick 1 -> t_ms 100, so no legitimate tempo-clamp: the only warnings are
    -- the extended-range (key 20) and the custom instrument (id 20, vanilla 20).
    local song = make_song({
      note(1, 0, 0, 20),
      note(1, 0, 20, 45),
    }, { tps = 10, vanilla = 20 })

    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local codes = {}

    ccnbs.play(song, {
      speakers = { left, right },
      clock = vclock,
      on_warning = function(code)
        codes[#codes + 1] = code
      end,
    })
    clock.advance_to(vclock, 1000000)

    expect.equal(code_count(codes, "extended-range"), 1)
    expect.equal(code_count(codes, "custom-instrument"), 1)
    -- Every distinct code appears exactly once.
    local seen = {}
    for index = 1, #codes do
      local code = codes[index]
      seen[code] = (seen[code] or 0) + 1
      expect.equal(seen[code], 1)
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 7. extended-range fires at start, not mid-playback
-- ---------------------------------------------------------------------------

describe("extended-range ordering", function()
  it("invokes on_warning before the first on_event", function()
    local song = make_song({
      note(1, 0, 0, 20),
      note(2, 0, 0, 45),
    }, { tps = 10, vanilla = 20 })

    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local log = {}

    ccnbs.play(song, {
      speakers = { left },
      clock = vclock,
      on_warning = function(code)
        log[#log + 1] = "W:" .. code
      end,
      on_event = function()
        log[#log + 1] = "E"
      end,
    })
    clock.advance_to(vclock, 1000000)

    expect.equal(log[1], "W:extended-range")
    expect.truthy(#log >= 2)
    expect.equal(log[2], "E")
  end)
end)

-- ---------------------------------------------------------------------------
-- 8. No warning when there is nothing to warn about
-- ---------------------------------------------------------------------------

describe("silent song", function()
  it("never calls on_warning when nothing needs warning about", function()
    local song = make_song({
      note(1, 0, 0, 45),
      note(2, 0, 1, 57),
    }, { tps = 10, vanilla = 20 })

    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local warnings = 0

    ccnbs.play(song, {
      speakers = { left },
      clock = vclock,
      on_warning = function()
        warnings = warnings + 1
      end,
    })
    clock.advance_to(vclock, 1000000)

    expect.equal(warnings, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 9. Session fields are populated
-- ---------------------------------------------------------------------------

describe("session fields", function()
  it("populates analysis, plan, assignment and stats", function()
    local song = load_fixture("simple.nbs")
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")

    local session = ccnbs.play(song, {
      speakers = { left, right },
      clock = vclock,
    })

    expect.deep_equal(session.analysis, ccnbs.analyze(song))
    expect.deep_equal(session.plan, ccnbs.plan(song, session.analysis))

    local expected = fanout.assign(session.plan, session.analysis, { left, right })
    expect.equal(type(session.assignment), "table")
    expect.deep_equal(session.assignment.warning_args, expected.warning_args)

    expect.equal(type(session.stats()), "table")

    session.cancel()
  end)
end)

-- ---------------------------------------------------------------------------
-- 10. session.cancel() stops further events
-- ---------------------------------------------------------------------------

describe("session.cancel", function()
  it("stops further events and is safe to call twice", function()
    local song = load_fixture("simple.nbs")
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")
    local right = speaker.mock("right")
    local count = 0
    local session

    session = ccnbs.play(song, {
      speakers = { left, right },
      clock = vclock,
      on_event = function()
        count = count + 1
        if count == 3 then
          session.cancel()
        end
      end,
    })
    clock.advance_to(vclock, 1000000)

    expect.equal(count, 3)
    local ok = pcall(function()
      session.cancel()
    end)
    expect.equal(ok, true)
  end)
end)

-- ---------------------------------------------------------------------------
-- 11. session.is_playing()
-- ---------------------------------------------------------------------------

describe("session.is_playing", function()
  it("is true with pending events and false after cancel", function()
    local song = load_fixture("simple.nbs")
    local vclock = clock.new_virtual(0)
    local left = speaker.mock("left")

    local session = ccnbs.play(song, {
      speakers = { left },
      clock = vclock,
    })

    expect.equal(session.is_playing(), true)
    session.cancel()
    expect.equal(session.is_playing(), false)
  end)
end)

-- ---------------------------------------------------------------------------
-- 12. Default speaker seam degrades instead of raising
-- ---------------------------------------------------------------------------

describe("default speaker seam", function()
  it("drops events and warns speakers when no peripheral exists", function()
    local saved = rawget(_G, "peripheral")
    _G.peripheral = nil

    local song = make_song({ note(1, 0, 0, 45) }, { tps = 10, vanilla = 20 })
    local vclock = clock.new_virtual(0)
    local codes = {}

    local ok, err = pcall(function()
      expect.equal(#ccnbs.discover_speakers(), 0)
      ccnbs.play(song, {
        clock = vclock,
        on_warning = function(code)
          codes[#codes + 1] = code
        end,
      })
      clock.advance_to(vclock, 1000000)
    end)

    if saved ~= nil then
      _G.peripheral = saved
    end

    expect.truthy(ok or err == nil)
    expect.equal(ok, true)
    expect.equal(code_count(codes, "speakers"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- 13. docs/API.md example actually runs
-- ---------------------------------------------------------------------------

describe("docs/API.md", function()
  it("contains a fenced Lua example that executes without error", function()
    local handle = assert(io.open(API_DOC, "r"), "docs/API.md is missing")
    local text = handle:read("*a")
    handle:close()

    -- Collect every fenced ```lua block.
    local blocks = {}
    local in_lua = false
    local buffer = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
      local language = line:match("^%s*```(%a*)%s*$")
      if language ~= nil and language ~= "" and not in_lua then
        if language == "lua" then
          in_lua = true
          buffer = {}
        end
      elseif line:match("^%s*```%s*$") and in_lua then
        in_lua = false
        blocks[#blocks + 1] = table.concat(buffer, "\n")
      elseif in_lua then
        buffer[#buffer + 1] = line
      end
    end

    expect.truthy(#blocks >= 1)

    for index = 1, #blocks do
      local chunk, load_error = load(blocks[index], "docs/API.md[lua]")
      expect.truthy(chunk ~= nil)
      if chunk == nil then
        error("docs/API.md block " .. index .. " did not compile: "
          .. tostring(load_error), 0)
      end
      local ok, run_error = pcall(chunk)
      if not ok then
        error("docs/API.md block " .. index .. " failed: "
          .. tostring(run_error), 0)
      end
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- 14-18. play() accepts EITHER a song OR an already-computed plan (defect A).
-- The plan is the shape ccnbs.plan returns: an array of event tables each
-- carrying t_ms + kind; a song is a table whose header.version is numeric.
-- ---------------------------------------------------------------------------

describe("play accepts a song or a plan", function()
  it("14. the exact reproduction succeeds and matches play(song) speaker calls", function()
    local song = load_fixture("simple.nbs")
    local an = ccnbs.analyze(song)
    local events = ccnbs.plan(song, an)

    -- Baseline: play the SONG.
    local vc_song = clock.new_virtual(0)
    local left_song = speaker.mock("left")
    local right_song = speaker.mock("right")
    ccnbs.play(song, { speakers = { left_song, right_song }, clock = vc_song })
    clock.advance_to(vc_song, 1000000)

    -- The reported reproduction: play the PLAN, with the analysis supplied.
    local vc_plan = clock.new_virtual(0)
    local left_plan = speaker.mock("left")
    local right_plan = speaker.mock("right")
    local session_plan
    local ok, err = pcall(function()
      session_plan = ccnbs.play(events, {
        analysis = an,
        speakers = { left_plan, right_plan },
        clock = vc_plan,
      })
    end)
    if not ok then
      error("play(plan) raised: " .. tostring(err), 0)
    end
    clock.advance_to(vc_plan, 1000000)

    expect.equal(#left_plan.calls + #right_plan.calls,
      #left_song.calls + #right_song.calls)
    expect.deep_equal(left_plan.calls, left_song.calls)
    expect.deep_equal(right_plan.calls, right_song.calls)
    -- The supplied plan is used VERBATIM: no re-analysis, no re-planning.
    expect.equal(#session_plan.plan, #events)
    expect.equal(session_plan.plan, events)
  end)

  it("15. play(plan) with NO analysis raises a CLEAR typed error naming opts.analysis", function()
    local song = load_fixture("simple.nbs")
    local an = ccnbs.analyze(song)
    local events = ccnbs.plan(song, an)

    local ok, err = pcall(function()
      ccnbs.play(events)
    end)

    expect.equal(ok, false)
    expect.equal(type(err), "table")
    expect.equal(err.code, "E_PLAN_REQUIRES_ANALYSIS")
    expect.contains(err.msg, "opts.analysis")
    -- Crucially NOT the nil-arithmetic crash the defect reported.
    expect.equal(err.msg:find("arithmetic", 1, true), nil)
  end)

  it("16. playing a song and its plan share the SAME ordered calls and warning-code set", function()
    local song = make_song({
      note(1, 0, 0, 20),  -- key 20: below the native range -> extended-range
      note(1, 0, 20, 45), -- instrument id 20 (== vanilla) -> custom-instrument
      note(2, 0, 0, 46),
    }, { tps = 10, vanilla = 20 })
    local an = ccnbs.analyze(song)
    local events = ccnbs.plan(song, an)

    local function run(target, options)
      local vc = clock.new_virtual(0)
      local left = speaker.mock("left")
      local right = speaker.mock("right")
      local codes = {}
      local sequence = {}
      local opts = {
        speakers = { left, right },
        clock = vc,
        on_warning = function(code)
          codes[#codes + 1] = code
        end,
        on_event = function(event)
          sequence[#sequence + 1] = event.tick_index .. "/" .. event.layer_index
            .. "/" .. event.note_index .. "/" .. event.kind
        end,
      }
      for key, value in pairs(options or {}) do
        opts[key] = value
      end
      ccnbs.play(target, opts)
      clock.advance_to(vc, 1000000)
      return left.calls, right.calls, codes, sequence
    end

    local left_song, right_song, song_codes, song_sequence = run(song, nil)
    local left_plan, right_plan, plan_codes, plan_sequence =
      run(events, { analysis = an })

    expect.sequence_equal(plan_sequence, song_sequence)
    expect.deep_equal(left_plan, left_song)
    expect.deep_equal(right_plan, right_song)

    local function code_set(codes)
      local set = {}
      for index = 1, #codes do
        set[codes[index]] = true
      end
      return set
    end
    expect.deep_equal(code_set(plan_codes), code_set(song_codes))
    -- Sanity: the fixture genuinely exercises two warning classes.
    expect.truthy(code_set(song_codes)["extended-range"] == true)
    expect.truthy(code_set(song_codes)["custom-instrument"] == true)
  end)

  it("17. a plan for an empty song (zero events) plays and finishes without raising", function()
    local song = make_song({}, { tps = 10 })
    local an = ccnbs.analyze(song)
    local events = ccnbs.plan(song, an)
    expect.equal(#events, 0)

    local vc = clock.new_virtual(0)
    local session
    local ok, err = pcall(function()
      session = ccnbs.play(events, {
        analysis = an,
        speakers = { speaker.mock("left") },
        clock = vc,
      })
      clock.advance_to(vc, 1000)
    end)
    if not ok then
      error("empty plan raised: " .. tostring(err), 0)
    end
    expect.equal(session.is_playing(), false)
    expect.equal(session.stats().ticks_scheduled, 0)
  end)

  it("18. hostile inputs raise clear typed errors, never a nil-arithmetic crash", function()
    local function expect_typed_refusal(value)
      local ok, err = pcall(function()
        ccnbs.play(value)
      end)
      expect.equal(ok, false)
      expect.equal(type(err), "table")
      expect.equal(err.code, "E_BAD_PLAY_INPUT")
      expect.truthy(type(err.msg) == "string" and #err.msg > 0)
      expect.equal(err.msg:find("arithmetic", 1, true), nil)
    end

    expect_typed_refusal(nil)
    expect_typed_refusal("x")
    expect_typed_refusal(42)
    expect_typed_refusal(true)

    -- An empty table is the plan of an empty song: legitimate, but a plan still
    -- requires the caller's analysis - and says so clearly.
    local ok, err = pcall(function()
      ccnbs.play({})
    end)
    expect.equal(ok, false)
    expect.equal(type(err), "table")
    expect.equal(err.code, "E_PLAN_REQUIRES_ANALYSIS")
    expect.contains(err.msg, "opts.analysis")
  end)
end)

-- ---------------------------------------------------------------------------
-- 19-21. tempo-clamp on the PRODUCTION path (defect C).  ccnbs.play must pass
-- the authoritative analysis.tick_ms into tempo.new; otherwise the scheduler
-- infers the interval from the smallest event gap and under-reports a sparse
-- sub-granularity song.
-- ---------------------------------------------------------------------------

describe("production-path tempo clamp", function()
  local function play_and_collect(song)
    local vc = clock.new_virtual(0)
    local codes = {}
    ccnbs.play(song, {
      speakers = { speaker.mock("left") },
      clock = vc,
      on_warning = function(code)
        codes[#codes + 1] = code
      end,
    })
    clock.advance_to(vc, 1000000)
    return codes
  end

  it("19. a sub-50ms nominal tempo (20 ms) warns exactly once through play", function()
    -- Nominal tick_ms = 1000 / 50 = 20 ms, BELOW the 50 ms granularity.  The
    -- events are sparse (ticks 0/10/20 -> 0/200/400 ms), so inferring from the
    -- smallest gap saw 200 ms and the old production path never warned.
    local song = make_song({
      note(0, 0, 0, 45),
      note(10, 0, 0, 46),
      note(20, 0, 0, 47),
    }, { tps = 50 })

    local codes = play_and_collect(song)
    expect.equal(code_count(codes, "tempo-clamp"), 1)
  end)

  it("20. an ordinary 100 ms song produces NO tempo-clamp through play", function()
    local song = make_song({
      note(1, 0, 0, 45),
      note(2, 0, 0, 46),
      note(3, 0, 0, 47),
    }, { tps = 10 })

    local codes = play_and_collect(song)
    expect.equal(code_count(codes, "tempo-clamp"), 0)
  end)

  it("21. a sparse song with a legitimate slow tempo gets no spurious clamp", function()
    -- REGRESSION: 5 tps -> 200 ms nominal, sparse events.  Passing a real and
    -- legitimately slow tick_ms must not manufacture a clamp warning.
    local song = make_song({
      note(0, 0, 0, 45),
      note(10, 0, 0, 46),
      note(20, 0, 0, 47),
    }, { tps = 5 })

    local codes = play_and_collect(song)
    expect.equal(code_count(codes, "tempo-clamp"), 0)
  end)
end)
