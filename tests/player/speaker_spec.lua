-- tests/player/speaker_spec.lua
--
-- Tier-1 spec for player/speaker.lua -- the INJECTABLE SPEAKER SEAM.
--
-- The project verifies at three tiers: pure Lua unit tests, a CraftOS-PC
-- headless harness that wraps `peripheral.*` to record calls, and real
-- Minecraft.  All three must drive the SAME player code, so the player must
-- never reach for the global `peripheral` itself.  player/speaker.lua is the
-- only module allowed to touch it, and it must offer a recording alternative
-- (speaker.mock) so the unit-test and Tier-2 tiers can observe calls.
--
-- This spec pins the FROZEN PUBLIC INTERFACE:
--   speaker.discover()            -> array of speaker records, side-sorted asc
--   speaker.wrap(side, obj)       -> speaker record adapting camelCase methods
--   speaker.mock(side)            -> speaker record that RECORDS calls
-- A speaker record: { side, play_note(self,n,v,p)->bool, play_sound(...)->bool,
--                     stop(self) }
-- A mock record additionally exposes: .calls (array) and .drain() -> calls.
--
-- Isolation: discover() reads the global `peripheral`, so the cases that need
-- one install a fake via rawset(_G, "peripheral", ...).  Every test in this
-- file instead runs with NO `peripheral` global (see before_each) and the hook
-- restores whatever was there in after_each, so the rest of the suite is
-- unaffected.  The source guard (case 12) additionally reads the module text
-- from disk to enforce the no-hard-coded-find rule mechanically.

local speaker = require("player.speaker")

-- ---------------------------------------------------------------------------
-- Project root + file helpers (same convention as tests/player/mapping_spec.lua)
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

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a") or ""
  handle:close()
  return data
end

-- ---------------------------------------------------------------------------
-- Global isolation
--
-- before_each clears any `peripheral` global and after_each puts the previous
-- value back.  Case 9 installs a fake and relies on this teardown; case 10 uses
-- a metatable that errors on ANY key other than getNames/getType.
-- ---------------------------------------------------------------------------

local saved_peripheral = nil

before_each(function()
  saved_peripheral = rawget(_G, "peripheral")
  rawset(_G, "peripheral", nil)
end)

after_each(function()
  rawset(_G, "peripheral", saved_peripheral)
end)

-- A fake peripheral object that behaves like a CC:Tweaked speaker: camelCase
-- methods, takes `self`, and answers with a chosen boolean.
local function fake_peripheral(note_result, sound_result)
  local object = {}
  function object.playNote(self, name, volume, pitch)
    self.seen_note = { name, volume, pitch }
    return note_result
  end
  function object.playSound(self, name, volume, pitch)
    self.seen_sound = { name, volume, pitch }
    return sound_result
  end
  function object.stop(self)
    self.stopped = true
    return "stopped"
  end
  return object
end

-- ---------------------------------------------------------------------------
-- 1-4. speaker.mock -- the recording alternative
-- ---------------------------------------------------------------------------

describe("speaker.mock records calls", function()
  it("1. records play_note, play_sound then stop in call order with exact arguments", function()
    local record = speaker.mock("left")

    local first_return = record:play_note("harp", 1, 0)
    local second_return = record:play_sound(
      "minecraft:block.note_block.trumpet", 1, 1.0)
    record:stop()

    local calls = record:drain()
    expect.equal(#calls, 3)

    expect.equal(calls[1].method, "play_note")
    expect.deep_equal(calls[1].args, { "harp", 1, 0 })

    expect.equal(calls[2].method, "play_sound")
    expect.deep_equal(calls[2].args,
      { "minecraft:block.note_block.trumpet", 1, 1.0 })

    expect.equal(calls[3].method, "stop")
    expect.deep_equal(calls[3].args, {})

    -- The recording must not change the "never refuses" mock contract.
    expect.equal(first_return, true)
    expect.equal(second_return, true)

    io.write(string.format(
      "    CASE1 mock order: %s/%s/%s\n",
      calls[1].method, calls[2].method, calls[3].method))
  end)

  it("2. drain returns the accumulated calls and CLEARS the buffer", function()
    local record = speaker.mock("left")
    record:play_note("harp", 1, 0)

    local first = record:drain()
    expect.equal(#first, 1)

    local second = record:drain()
    expect.equal(#second, 0)          -- empty...
    expect.deep_equal(second, {})     -- ...and a genuinely empty sequence
    expect.truthy(second ~= first)    -- not the same table handed back again
    expect.equal(#record.calls, 0)
  end)

  it("3. two mocks keep independent buffers", function()
    local left = speaker.mock("left")
    local right = speaker.mock("right")

    left:play_note("harp", 1, 0)
    left:play_sound("minecraft:block.note_block.trumpet", 1, 1.0)

    expect.equal(#left.calls, 2)
    expect.equal(#right.calls, 0)     -- left's calls did NOT leak into right

    right:stop()
    expect.equal(#left.calls, 2)      -- and right's call did NOT leak into left
    expect.equal(#right.calls, 1)
    expect.equal(right.calls[1].method, "stop")
  end)

  it("4. mock never refuses: play_note and play_sound both return true", function()
    local record = speaker.mock("left")
    expect.equal(record:play_note("harp", 1, 0), true)
    expect.equal(record:play_sound("minecraft:block.note_block.trumpet", 1, 1.0), true)
  end)
end)

-- ---------------------------------------------------------------------------
-- 5-7. speaker.wrap -- adapt a real peripheral object
-- ---------------------------------------------------------------------------

describe("speaker.wrap adapts a peripheral object", function()
  it("5. forwards arguments AND the refusal return value unchanged", function()
    local fake = {
      seen = nil,
      playNote = function(self, name, volume, pitch)
        self.seen = { name, volume, pitch }
        return false
      end,
    }

    local record = speaker.wrap("back", fake)
    local result = record:play_note("harp", 2, 5)

    -- The 8-notes-per-tick budget makes a refusal normal, not an error: the
    -- caller MUST see the false, it must not be swallowed or normalised.
    expect.equal(result, false)
    expect.deep_equal(fake.seen, { "harp", 2, 5 })

    io.write(string.format(
      "    CASE5 wrap forwarded: result=%s args=%s\n",
      tostring(result), tostring(fake.seen[1]) .. "," .. tostring(fake.seen[2])
        .. "," .. tostring(fake.seen[3])))
  end)

  it("6. maps play_sound -> playSound and stop -> stop", function()
    local fake = fake_peripheral(true, true)
    local record = speaker.wrap("back", fake)

    local sound_return = record:play_sound(
      "minecraft:block.note_block.trumpet", 2, 1.5)
    expect.equal(sound_return, true)
    expect.deep_equal(fake.seen_sound,
      { "minecraft:block.note_block.trumpet", 2, 1.5 })

    local stop_return = record:stop()
    expect.equal(fake.stopped, true)
    expect.equal(stop_return, "stopped")   -- stop's return is forwarded too
  end)

  it("7. an absent method raises a clear error naming side and method, not a nil-index crash", function()
    -- A peripheral missing playSound: play_note still works, play_sound raises.
    local fake = {
      playNote = function(self, name, volume, pitch)
        return true
      end,
    }
    local record = speaker.wrap("back", fake)

    local message = expect.raises(function()
      record:play_sound("harp", 1, 1)
    end)
    expect.contains(message, "back")
    expect.contains(message, "playSound")

    -- The present method is unaffected: dispatch is per-method, not all-or-nothing.
    expect.equal(record:play_note("harp", 1, 0), true)

    io.write(string.format("    CASE7 missing-method message: %s\n", message))
  end)
end)

-- ---------------------------------------------------------------------------
-- 8-10. speaker.discover -- enumerate + filter + sort, no hard-coded find
-- ---------------------------------------------------------------------------

describe("speaker.discover", function()
  it("8. with no peripheral global at all returns an EMPTY array, never raises", function()
    expect.equal(rawget(_G, "peripheral"), nil)  -- guaranteed by before_each

    local called, result = pcall(speaker.discover)
    expect.truthy(called)
    expect.equal(type(result), "table")
    expect.equal(#speaker.discover(), 0)
  end)

  it("9. installs a fake global: filters to speakers and sorts sides ascending", function()
    local fake_peripherals = {
      back = fake_peripheral(true),
      left = fake_peripheral(true),
      bottom = fake_peripheral(true),
      top = fake_peripheral(true),
    }
    local declared = { "back", "left", "top", "bottom" }  -- deliberately unsorted
    local kinds = {
      back = "speaker",
      left = "speaker",
      top = "monitor",
      bottom = "speaker",
    }
    local fake_global = {
      getNames = function()
        return declared
      end,
      getType = function(side)
        return kinds[side]
      end,
      wrap = function(side)
        return fake_peripherals[side]
      end,
    }
    rawset(_G, "peripheral", fake_global)

    local records = speaker.discover()
    expect.equal(#records, 3)

    local sides = {}
    for index = 1, #records do
      sides[index] = records[index].side
    end
    expect.sequence_equal(sides, { "back", "bottom", "left" })

    -- `top` is a monitor, not a speaker: it must be excluded.
    for index = 1, #records do
      expect.truthy(records[index].side ~= "top")
    end

    io.write(string.format(
      "    CASE9 discover sorted sides: {%s} (top excluded=%s)\n",
      table.concat(sides, ","), tostring(#sides == 3)))
  end)

  it("10. touches ONLY getNames/getType on the peripheral global (no find, no wrap)", function()
    local access_error = nil
    local fake_global = setmetatable({
      getNames = function()
        return { "back", "left", "front" }
      end,
      getType = function(side)
        if side == "left" or side == "front" then
          return "speaker"
        end
        return "monitor"
      end,
    }, {
      __index = function(_, key)
        access_error = key
        error("speaker.discover touched an unexpected peripheral key: "
          .. tostring(key), 0)
      end,
    })
    rawset(_G, "peripheral", fake_global)

    local called, records = pcall(speaker.discover)
    if not called then
      error(string.format(
        "discover hard-codes an access beyond getNames/getType (key=%s): %s",
        tostring(access_error), tostring(records)), 2)
    end

    expect.equal(access_error, nil)     -- mechanically: no find / no wrap read
    expect.equal(#records, 2)
    expect.equal(records[1].side, "front")
    expect.equal(records[2].side, "left")

    io.write("    CASE10 discover with only getNames/getType: OK (no stray key)\n")
  end)
end)

-- ---------------------------------------------------------------------------
-- 11-12. Module isolation guards
-- ---------------------------------------------------------------------------

describe("speaker module isolation", function()
  it("11. requires with NO peripheral global present; mock/wrap/discover all work", function()
    expect.equal(rawget(_G, "peripheral"), nil)

    -- Force a fresh load with the global absent: a module-scope capture would
    -- crash here.
    local cached = package.loaded["player.speaker"]
    package.loaded["player.speaker"] = nil
    local called, fresh = pcall(require, "player.speaker")
    package.loaded["player.speaker"] = cached or fresh
    if not called then
      error("require(\"player.speaker\") raised without a peripheral global: "
        .. tostring(fresh), 2)
    end
    expect.equal(type(fresh), "table")

    -- mock works with no global.
    local record = fresh.mock("left")
    expect.equal(record:play_note("harp", 1, 0), true)

    -- wrap works with no global (the caller supplies the object).
    local object = fake_peripheral(false)
    expect.equal(fresh.wrap("back", object):play_note("harp", 1, 0), false)

    -- discover is safe with no global.
    expect.equal(#fresh.discover(), 0)

    io.write("    CASE11 no-global require + mock/wrap/discover: OK\n")
  end)

  it("12. source guard: no hard-coded find and no module-scope peripheral capture", function()
    local text = read_file(join(ROOT, "player/speaker.lua"))
    expect.truthy(text ~= nil)

    -- (a) the literal substring must never appear in the module source.
    local has_find = text:find("peripheral.find", 1, true)
    expect.falsy(has_find)

    -- (b) coarse heuristic: no `local peripheral =` capture at module scope
    -- (i.e. at column 0).  A capture inside a function body is indented.
    local has_module_capture = false
    for line in text:gmatch("[^\n]*") do
      if line:match("^local%s+peripheral%s*=") then
        has_module_capture = true
      end
    end
    expect.falsy(has_module_capture)

    io.write(string.format(
      "    CASE12 guard: peripheral.find present=%s module-scope capture=%s\n",
      tostring(has_find ~= nil), tostring(has_module_capture)))
  end)
end)
