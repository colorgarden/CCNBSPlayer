-- tests/tier2/pitch_probe.lua
--
-- STANDALONE PITCH-RANGE PROBE for the CC:Tweaked `speaker` peripheral, run
-- INSIDE CraftOS-PC.  It is deliberately independent of the player modules: it
-- only needs a speaker peripheral, so it can be re-run on demand to re-check how
-- a given emulator (or, by copy-paste, a real computer) treats out-of-range
-- pitch arguments.
--
-- HOW TO RUN (Windows host, from the repository root):
--
--   $tmp = "$env:TEMP\ccnbs-pitch-probe"
--   Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
--   New-Item -ItemType Directory -Path "$tmp\computer\0" -Force | Out-Null
--   $env:SDL_AUDIODRIVER = "dummy"
--   & "D:\tools\CraftOS-PC\CraftOS-PC_console.exe" --headless `
--       --directory "$tmp" --id 0 `
--       --script "<abs path>\tests\tier2\pitch_probe.lua" `
--       -o standardsMode=true -o maxNotesPerTick=8 -o http_enable=true
--   Get-Content "$tmp\computer\0\result.txt"
--
-- The findings land in `result.txt` in the file-result channel (never stdout:
-- the headless renderer emits an unparseable screen-diff stream).  The last line
-- is `STATUS ok` on success or `STATUS fail:<reason>` if the probe itself broke.
--
-- WHY THE FIXED os.sleep BEFORE os.shutdown
--   CraftOS-PC 2.8.3 crashes (0xC0000005) at teardown if the emulated speaker
--   still has queued audio; every path here therefore sleeps a fixed teardown
--   grace before shutting down.  This is not waiting for a song -- it is teardown
--   (see tests/tier2/README.md section 2 and evidence task-28 F1).
--
-- CALL CONVENTION
--   CraftOS-PC's peripheral.wrap(side) object methods are called WITHOUT an
--   explicit self: `obj.playNote("harp", 1, 12)`.  Calling with `:` fails with
--   `bad argument #1 (expected string, got peripheral)`.  This probe uses the
--   dot form; SECTION A re-checks that convention so the result is self-evident.
--
-- TICK BUDGET
--   Under `-o maxNotesPerTick=8` a speaker accepts a bounded number of playNote
--   calls per game tick; a call past the budget returns false.  A pitch sweep
--   therefore SPACES its probes by more than one 50 ms game tick so a budget
--   refusal can never be mistaken for a pitch refusal.  SECTION B measures the
--   budget itself, unslept, so the spacing is justified by evidence.
--
-- Compatibility: runs under Cobalt (Lua 5.2), so no `//`, no bitwise operators,
-- no utf8.*, no goto, no string.dump, no os.exit.  It must stay clean under
-- tests/lint.lua, which scans tests/ recursively.

local SIDE = "back"
local TEARDOWN_GRACE_SECONDS = 1.5
-- Slightly more than one 50 ms Minecraft game tick, used to isolate each probe
-- from the per-tick note budget.
local TICK_GAP_SECONDS = 0.07

-- The playNote instrument names are the 16 legacy note-block instrument names
-- from nbs/instrument_table.lua; "harp" (id 0) is used throughout.
local NOTE_INSTRUMENT = "harp"
-- playSound names are full sound-event ids; these are the v6 trumpet events the
-- player maps.  playSound is only meaningful on a runner whose sound bank is
-- populated, so SECTION G discovers a usable name instead of assuming one.
local SOUND_CANDIDATES = {
  "minecraft:block.note_block.harp",
  "minecraft:block.note_block.bell",
  "minecraft:block.note_block.trumpet",
  "minecraft:block.note.harp",
  "block.note_block.harp",
  "harp",
}

-- ---------------------------------------------------------------------------
-- Result channel
-- ---------------------------------------------------------------------------

local findings = {}

local function emit(text)
  findings[#findings + 1] = text
end

-- fmt(value) -> a stable token for one value: strings verbatim, booleans as
-- true/false, integral numbers without a trailing ".0", other numbers to six
-- decimal places.  Keeps the recording byte-identical across runs.
local function fmt(value)
  local kind = type(value)
  if kind == "string" then
    return value
  end
  if kind == "boolean" then
    return tostring(value)
  end
  if kind == "number" then
    if value == math.floor(value) and math.abs(value) < 1000000000000000 then
      return string.format("%d", value)
    end
    return string.format("%.6f", value)
  end
  if value == nil then
    return "nil"
  end
  return kind
end

-- one_line(text): fold any embedded newlines so a line stays greppable.
local function one_line(text)
  return (tostring(text):gsub("[\r\n]+", " / "))
end

-- write_result() -> boolean.  Always writes result.txt, success or failure.
local function write_result(status)
  local handle = fs.open("result.txt", "w")
  if handle == nil then
    return false
  end
  handle.write(table.concat(findings, "\n"))
  if #findings > 0 then
    handle.write("\n")
  end
  handle.write("STATUS " .. one_line(status) .. "\n")
  handle.close()
  return true
end

-- ---------------------------------------------------------------------------
-- Probing helpers
-- ---------------------------------------------------------------------------

-- probe_note(obj, label, name, volume, pitch): call playNote and record whether
-- it RAISED (ok=false, message) or RETURNED (ok=true, boolean).
local function probe_note(obj, label, name, volume, pitch)
  local ok, ret = pcall(obj.playNote, name, volume, pitch)
  if ok then
    emit(string.format("NOTE %s => ok=true ret=%s", label, fmt(ret)))
    return true
  end
  emit(string.format("NOTE %s => ok=false raised=%s", label, one_line(ret)))
  return false
end

-- probe_sound(obj, label, name, volume, ratio): the playSound analogue.
local function probe_sound(obj, label, name, volume, ratio)
  local ok, ret = pcall(obj.playSound, name, volume, ratio)
  if ok then
    emit(string.format("SOUND %s => ok=true ret=%s", label, fmt(ret)))
    return true
  end
  emit(string.format("SOUND %s => ok=false raised=%s", label, one_line(ret)))
  return false
end

-- attach_speaker() -> the wrapped speaker object, or nil on failure.
local function attach_speaker()
  if type(periphemu) == "table" and type(periphemu.create) == "function" then
    periphemu.create(SIDE, "speaker")
  end
  local object = peripheral.wrap(SIDE)
  if type(object) ~= "table" then
    return nil
  end
  return object
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

local function section_environment(obj)
  emit("== ENVIRONMENT ==")
  emit("PROBE version=1 side=" .. SIDE)
  local ok, version = pcall(os.version)
  if ok then
    emit("PROBE craftos_version=" .. fmt(version))
  else
    emit("PROBE craftos_version=unavailable")
  end

  -- Report which option-bearing methods this build exposes, so an unexpected
  -- result can be attributed to a different build.
  local names = {}
  for key, value in pairs(obj) do
    if type(value) == "function" then
      names[#names + 1] = key
    end
  end
  table.sort(names)
  emit("PROBE methods=" .. table.concat(names, ","))
end

local function section_call_convention(obj)
  emit("== A. CALL CONVENTION ==")
  local dot_ok, dot_ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
  emit(string.format("CALL dot playNote => ok=%s ret=%s",
    tostring(dot_ok), fmt(dot_ret)))
  local colon_ok, colon_ret = pcall(function()
    return obj:playNote(NOTE_INSTRUMENT, 1, 12)
  end)
  emit(string.format("CALL colon playNote => ok=%s ret=%s",
    tostring(colon_ok), one_line(colon_ret)))
end

local function section_tick_budget(obj)
  emit("== B. PER-TICK BUDGET ==")

  -- Unslept burst: count how many consecutive playNote calls return true
  -- before the budget refuses.  Every pitch here is IN range (12), so a false
  -- is a budget refusal, never a pitch refusal.
  os.sleep(TICK_GAP_SECONDS)
  local burst_true = 0
  local burst_total = 12
  local burst_line = {}
  for index = 1, burst_total do
    local ok, ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
    if ok and ret == true then
      burst_true = burst_true + 1
      burst_line[index] = "t"
    elseif ok then
      burst_line[index] = "f"
    else
      burst_line[index] = "E"
    end
  end
  emit(string.format("BUDGET unslept burst12 => true_count=%d pattern=%s",
    burst_true, table.concat(burst_line, "")))

  -- Slept burst: the same call count, one game tick apart.  If the budget
  -- resets per tick these should all succeed.
  local slept_true = 0
  local slept_total = 12
  local slept_line = {}
  for index = 1, slept_total do
    os.sleep(TICK_GAP_SECONDS)
    local ok, ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
    if ok and ret == true then
      slept_true = slept_true + 1
      slept_line[index] = "t"
    elseif ok then
      slept_line[index] = "f"
    else
      slept_line[index] = "E"
    end
  end
  emit(string.format("BUDGET slept burst12 => true_count=%d pattern=%s",
    slept_true, table.concat(slept_line, "")))

  -- Same-tick coexistence of a note and a sound: one playNote then one
  -- playSound back to back, then the reverse order.  Recorded raw; whether both
  -- can coexist is read off the returned booleans.
  local sound_name = SOUND_CANDIDATES[1]
  os.sleep(TICK_GAP_SECONDS)
  local n_ok, n_ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
  local s_ok, s_ret = pcall(obj.playSound, sound_name, 1, 1)
  emit(string.format("BUDGET same_tick note_then_sound => note=%s sound=%s",
    (n_ok and fmt(n_ret) or ("E:" .. one_line(n_ret))),
    (s_ok and fmt(s_ret) or ("E:" .. one_line(s_ret)))))

  os.sleep(TICK_GAP_SECONDS)
  s_ok, s_ret = pcall(obj.playSound, sound_name, 1, 1)
  n_ok, n_ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
  emit(string.format("BUDGET same_tick sound_then_note => sound=%s note=%s",
    (s_ok and fmt(s_ret) or ("E:" .. one_line(s_ret))),
    (n_ok and fmt(n_ret) or ("E:" .. one_line(n_ret)))))
end

-- section_pitch_scan: walk a pitch range one game tick apart and summarise the
-- exact accepted set.  -3..27 is wide enough to show the boundary and one step
-- beyond it on both sides.
local function section_pitch_scan(obj)
  emit("== C. playNote PITCH SCAN (one probe per game tick) ==")
  local low = -3
  local high = 27
  local accepted = {}
  local rejected = {}
  local raised = {}
  for pitch = low, high do
    os.sleep(TICK_GAP_SECONDS)
    local ok, ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, pitch)
    if not ok then
      raised[#raised + 1] = pitch
      emit(string.format("SCAN pitch=%d => RAISED %s", pitch, one_line(ret)))
    elseif ret == true then
      accepted[#accepted + 1] = pitch
      emit(string.format("SCAN pitch=%d => ok=true", pitch))
    else
      rejected[#rejected + 1] = pitch
      emit(string.format("SCAN pitch=%d => ok=true ret=false", pitch))
    end
  end

  local function join(list)
    local parts = {}
    for index = 1, #list do
      parts[index] = tostring(list[index])
    end
    if #parts == 0 then
      return "(none)"
    end
    return table.concat(parts, ",")
  end
  emit("SCAN summary accepted={" .. join(accepted) .. "}")
  emit("SCAN summary rejected_false={" .. join(rejected) .. "}")
  emit("SCAN summary raised={" .. join(raised) .. "}")
end

-- section_non_integer_pitch: are non-integers accepted, and if so how are they
-- converted?  -0.9 and 24.6 are the DISCRIMINATORS: truncation toward zero maps
-- them to 0 and 24 (accepted), while rounding maps them to -1 and 25 (rejected).
local function section_non_integer_pitch(obj)
  emit("== D. playNote NON-INTEGER PITCH ==")
  local probes = { 12.5, 0.5, -0.5, -0.4, -0.9, 24.5, 24.6, 24.9, 25.0 }
  for index = 1, #probes do
    os.sleep(TICK_GAP_SECONDS)
    probe_note(obj, "pitch=" .. fmt(probes[index]), NOTE_INSTRUMENT, 1, probes[index])
  end
end

local function section_volume(obj)
  emit("== E. playNote VOLUME (pitch 12) ==")
  local probes = { -0.1, 0, 1.5, 3, 3.1 }
  for index = 1, #probes do
    os.sleep(TICK_GAP_SECONDS)
    probe_note(obj, "volume=" .. fmt(probes[index]), NOTE_INSTRUMENT, probes[index], 12)
  end
end

local function section_instrument(obj)
  emit("== F. playNote INSTRUMENT NAME ==")
  os.sleep(TICK_GAP_SECONDS)
  probe_note(obj, "name=notreal", "notreal", 1, 12)
  os.sleep(TICK_GAP_SECONDS)
  probe_note(obj, "name=bass", "bass", 1, 12)
end

-- section_play_sound: discover a usable sound-event name, then sweep the ratio.
-- On a headless runner with no loaded sound bank (obj.listSounds() is empty)
-- playSound returns false without raising, and the ratio sweep can then only
-- report "returned false", never an accepted range.  That limitation is stated
-- in the emitted lines rather than papered over.
local function section_play_sound(obj)
  emit("== G. playSound NAME + RATIO ==")

  if type(obj.listSounds) == "function" then
    local ok, sounds = pcall(obj.listSounds)
    if ok and type(sounds) == "table" then
      emit(string.format("SOUND listSounds => ok=true count=%d", #sounds))
    else
      emit("SOUND listSounds => ok=false " .. one_line(sounds))
    end
  else
    emit("SOUND listSounds => absent")
  end

  -- Discover a name: the first candidate playSound does not raise on.
  local chosen = nil
  local chosen_source = "none"
  if type(obj.listSounds) == "function" then
    local ok, sounds = pcall(obj.listSounds)
    if ok and type(sounds) == "table" and #sounds > 0 then
      chosen = sounds[1]
      chosen_source = "listSounds"
    end
  end
  if chosen == nil then
    for index = 1, #SOUND_CANDIDATES do
      local ok = pcall(obj.playSound, SOUND_CANDIDATES[index], 1, 1)
      if ok then
        chosen = SOUND_CANDIDATES[index]
        chosen_source = "candidate"
        break
      end
    end
  end
  emit("SOUND chosen_name=" .. fmt(chosen) .. " source=" .. chosen_source)

  local ratios = { 0.4, 0.5, 1.0, 1.999, 2.0, 2.001, 2.1, 0.01, 0.0, -0.01, -0.5, -1.0 }
  if chosen == nil then
    emit("SOUND ratio_sweep => SKIPPED (no non-raising sound name found)")
    return
  end
  for index = 1, #ratios do
    os.sleep(TICK_GAP_SECONDS)
    probe_sound(obj, "ratio=" .. fmt(ratios[index]), chosen, 1, ratios[index])
  end
end

-- section_coexistence: repeat the note-vs-sound same-tick trials so a single
-- observation is not mistaken for a rule.  This build has an EMPTY sound bank
-- (listSounds count 0), so playSound never actually produces sound here; all
-- this section can show is whether a playSound ATTEMPT in a tick affects a
-- following playNote in the same tick.
local function section_coexistence(obj)
  emit("== H. SAME-TICK NOTE vs SOUND (3 trials each) ==")
  local sound_name = SOUND_CANDIDATES[1]
  for trial = 1, 3 do
    os.sleep(TICK_GAP_SECONDS)
    local n_ok, n_ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
    local s_ok, s_ret = pcall(obj.playSound, sound_name, 1, 1)
    emit(string.format("COEXIST trial=%d order=note_then_sound note=%s sound=%s",
      trial, (n_ok and fmt(n_ret) or ("E:" .. one_line(n_ret))),
      (s_ok and fmt(s_ret) or ("E:" .. one_line(s_ret)))))

    os.sleep(TICK_GAP_SECONDS)
    s_ok, s_ret = pcall(obj.playSound, sound_name, 1, 1)
    n_ok, n_ret = pcall(obj.playNote, NOTE_INSTRUMENT, 1, 12)
    emit(string.format("COEXIST trial=%d order=sound_then_note sound=%s note=%s",
      trial, (s_ok and fmt(s_ret) or ("E:" .. one_line(s_ret))),
      (n_ok and fmt(n_ret) or ("E:" .. one_line(n_ret)))))
  end
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

local function main()
  local obj = attach_speaker()
  if obj == nil then
    error("no speaker peripheral on side " .. SIDE, 0)
  end

  section_environment(obj)
  section_call_convention(obj)
  section_tick_budget(obj)
  section_pitch_scan(obj)
  section_non_integer_pitch(obj)
  section_volume(obj)
  section_instrument(obj)
  section_play_sound(obj)
  section_coexistence(obj)
end

local ok, failure = pcall(main)

-- Fixed teardown grace on EVERY path -- see the header.
os.sleep(TEARDOWN_GRACE_SECONDS)

if ok then
  if not write_result("ok") then
    os.shutdown(1)
    return
  end
  os.shutdown(0)
  return
end

write_result("fail:" .. one_line(failure))
os.shutdown(1)
