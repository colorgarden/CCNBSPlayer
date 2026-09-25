-- qa/ingame.lua
--
-- IN-GAME ACCEPTANCE SCRIPT -- paste this (or copy it to the computer) and run
-- it ON A REAL CC:Tweaked COMPUTER to sanity-check the player end to end,
-- including on real hardware, where the emulator's pitch restriction does NOT
-- apply.
--
--   * discovers the attached speakers and reports how many were found;
--   * asks for a `.nbs` file (or takes one as an argument);
--   * decodes it, analyses it, renders the load-time warnings;
--   * plays it on the speakers;
--   * writes a STABLE summary that a headless harness can read.
--
-- WHAT THIS IS NOT
-- ---------------------------------------------------------------------------
-- This is not the interactive player (`/lib/ccnbsplayer`); it is a single-shot
-- acceptance probe.  It needs no test scaffolding and no network.  It only
-- schedules note calls -- it never plays audio samples.
--
-- INSTALLED LAYOUT
-- ---------------------------------------------------------------------------
-- The installer places the runtime under `/lib/`.  `require` resolves relative
-- to the RUNNING PROGRAM's directory, so this script prepends `/lib/` to
-- package.path to work no matter where it lives.
--
-- HARNESS MODE (how it is verified headlessly)
-- ---------------------------------------------------------------------------
-- Passing `--harness` switches the script into a non-interactive mode that
--   * uses a VIRTUAL clock, so the whole song completes instantly;
--   * writes the `INGAME ...` summary lines to the `--result <path>` file
--     (default `ingame.txt`);
--   * calls os.shutdown(code) at the end so a CraftOS-PC run terminates.
-- The summary is a set of stable, greppable lines:
--
--     INGAME status=ok speakers=1 song=<name> notes=76 events=76 warnings=0
--     INGAME warn=<code> ...
--     INGAME status=no-speaker
--     INGAME status=missing-file path=<...>
--     INGAME status=decode-failed error=<code>
--
-- This is a program, not a module; run it with, e.g.:
--     /lib/qa/ingame.lua
--     /lib/qa/ingame.lua /songs/mysong.nbs
--     /lib/qa/ingame.lua --harness --result=ingame.txt /fixture.nbs
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No `//`, no bitwise operators,
-- no utf8.*, no os.exit, no os.execute, no collectgarbage, no string.dump.

-- ---------------------------------------------------------------------------
-- Module search path: the installed layout under /lib
-- ---------------------------------------------------------------------------
do
  local prefix = "/lib/"
  package.path = prefix .. "?.lua;" .. prefix .. "?/init.lua;" .. package.path
end

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------
local argv = { ... }
if type(arg) == "table" and #argv == 0 then
  argv = arg
end

local harness = false
local result_path = "ingame.txt"
local song_path = nil

for index = 1, #argv do
  local value = argv[index]
  if type(value) == "string" then
    if value == "--harness" then
      harness = true
    elseif value == "--result" and type(argv[index + 1]) == "string" then
      result_path = argv[index + 1]
    elseif value:sub(1, 9) == "--result=" then
      result_path = value:sub(10)
    elseif value:sub(1, 7) == "result=" then
      result_path = value:sub(8)
    elseif value:sub(1, 2) ~= "--" then
      song_path = value
    end
  end
end

-- ---------------------------------------------------------------------------
-- Reporting helpers
-- ---------------------------------------------------------------------------

-- Every line emitted here starts with "INGAME " so the harness can grep it
-- without parsing the screen.
local summary = {}

local function emit(line)
  summary[#summary + 1] = line
  print(line)
end

-- A one-line, greppable rendering of an arbitrary value.
local function token(value)
  local text = tostring(value)
  text = text:gsub("[\r\n]+", " ")
  text = text:gsub("%s+", " ")
  return text
end

-- finish(status, code): ALWAYS write the harness result (when asked) and, in
-- harness mode, shut the computer down so the headless run terminates.
local function finish(code)
  if not harness then
    return code
  end
  local handle = nil
  local ok = pcall(function()
    handle = fs.open(result_path, "w")
  end)
  if ok and handle ~= nil then
    pcall(function()
      handle.write(table.concat(summary, "\n") .. "\n")
      handle.close()
    end)
  end
  -- CraftOS-PC 2.8.3 segfaults if os.shutdown runs with queued audio; a short
  -- grace period before shutdown avoids it (see docs/COMPAT.md).
  pcall(os.sleep, 1.5)
  os.shutdown(code or 0)
  return code
end

-- ---------------------------------------------------------------------------
-- Load the player
-- ---------------------------------------------------------------------------
local ok_ccnbs, ccnbs = pcall(require, "ccnbs")
if not ok_ccnbs or type(ccnbs) ~= "table" then
  emit("INGAME status=no-library error=" .. token(ccnbs))
  print("未找到 ccnbs 模块。请先运行安装器（installer.lua）完成安装。")
  finish(2)
  return
end

emit("INGAME version=" .. tostring(ccnbs.version))

-- Attach a speaker under the headless harness (CC:T hardware does not need
-- this).  Guarded so an environment without `periphemu` is unaffected.
if harness and type(periphemu) == "table" and type(periphemu.create) == "function" then
  pcall(periphemu.create, "back", "speaker")
end

-- ---------------------------------------------------------------------------
-- 1. Discover speakers
-- ---------------------------------------------------------------------------
local speakers = ccnbs.discover_speakers()
local speaker_count = #speakers
emit("INGAME speakers=" .. tostring(speaker_count))
print("检测到扬声器：" .. tostring(speaker_count) .. " 个。")

if speaker_count == 0 then
  emit("INGAME status=no-speaker")
  print("未检测到扬声器外设：请把扬声器贴在电脑的某一侧（如 back/left/right），")
  print("用 `peripheral.getNames()` 能看到它之后再重试。")
  finish(1)
  return
end

-- ---------------------------------------------------------------------------
-- 2. Choose a song
-- ---------------------------------------------------------------------------
if song_path == nil then
  if type(read) == "function" then
    write("请输入 .nbs 文件路径（例如 /songs/mysong.nbs）：")
    local answer = read()
    if type(answer) == "string" and answer ~= "" then
      song_path = answer
    end
  end
end

if song_path == nil then
  emit("INGAME status=missing-argument")
  print("未提供歌曲路径。用法：ingame.lua [--harness] [--result=文件] <歌曲.nbs>")
  finish(1)
  return
end

emit("INGAME file=" .. token(song_path))

-- ---------------------------------------------------------------------------
-- 3. Read + decode
-- ---------------------------------------------------------------------------
local bytes = nil
do
  local handle = nil
  local ok = pcall(function()
    handle = fs.open(song_path, "rb")
  end)
  if ok and handle ~= nil then
    local ok_read = pcall(function()
      bytes = handle.readAll and handle.readAll() or handle.read()
      handle.close()
    end)
    if not ok_read then
      bytes = nil
    end
  end
end

if type(bytes) ~= "string" or bytes == "" then
  emit("INGAME status=missing-file path=" .. token(song_path))
  print("找不到或无法读取文件：" .. token(song_path))
  finish(1)
  return
end

local decoded = ccnbs.decode(bytes)
if not decoded.ok then
  local code = "unknown"
  if decoded.error ~= nil then
    code = tostring(decoded.error.code)
  end
  emit("INGAME status=decode-failed error=" .. token(code))
  print("解码失败，错误码：" .. token(code))
  finish(2)
  return
end

local song = decoded.song
local analysis = ccnbs.analyze(song)

local title = song.header and song.header.name or nil
if title == nil or title == "" then
  title = song_path
end
title = token(title)

emit("INGAME song=" .. title
  .. " notes=" .. tostring(analysis.total_notes)
  .. " peak=" .. tostring(analysis.peak_concurrent)
  .. " tick_ms=" .. tostring(analysis.tick_ms))

-- ---------------------------------------------------------------------------
-- 4. Warnings -- prefer the real renderer
-- ---------------------------------------------------------------------------
local warn_codes = {}
local on_warning = function(code, args)
  if code == nil then
    return
  end
  warn_codes[#warn_codes + 1] = tostring(code)
  local line = tostring(code)
  local ok_w, warnings = pcall(require, "player.warnings")
  if ok_w and type(warnings) == "table" and type(warnings.format) == "function" then
    line = warnings.format(code, args)
  end
  emit("INGAME warn=" .. token(line))
end

-- ---------------------------------------------------------------------------
-- 5. Play
-- ---------------------------------------------------------------------------
local clock_module = nil
do
  local ok_clock, mod = pcall(require, "player.clock")
  if ok_clock and type(mod) == "table" then
    clock_module = mod
  end
end

local session = nil
local virtual_clock = nil

local ok_play, play_error = pcall(function()
  local options = {
    speakers = speakers,
    on_warning = on_warning,
  }
  if harness and clock_module ~= nil then
    virtual_clock = clock_module.new_virtual(0)
    options.clock = virtual_clock
  end
  session = ccnbs.play(song, options)
  return session
end)

if not ok_play or session == nil then
  emit("INGAME status=play-error error=" .. token(play_error))
  print("播放失败：" .. token(play_error))
  finish(3)
  return
end

if harness and virtual_clock ~= nil then
  -- Drive the virtual clock past the last event: instant and deterministic.
  local end_ms = 0
  for index = 1, #session.plan do
    if session.plan[index].t_ms > end_ms then
      end_ms = session.plan[index].t_ms
    end
  end
  clock_module.advance_to(virtual_clock, end_ms + 1)
else
  -- Real hardware: wait for the real-time playback to finish.
  local guard = 0
  while session.is_playing() and guard < 1000000 do
    guard = guard + 1
    os.sleep(0.05)
  end
end

local event_count = 0
if type(session.plan) == "table" then
  event_count = #session.plan
end

emit("INGAME status=ok speakers=" .. tostring(speaker_count)
  .. " song=" .. title
  .. " notes=" .. tostring(analysis.total_notes)
  .. " events=" .. tostring(event_count)
  .. " warnings=" .. tostring(#warn_codes))

for index = 1, #warn_codes do
  emit("INGAME warncode=" .. token(warn_codes[index]))
end

print("验收探针完成。")
finish(0)
