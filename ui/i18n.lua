-- ui/i18n.lua
--
-- THE INTERNATIONALISATION LAYER -- the SINGLE place user-facing prose lives.
--
-- ===========================================================================
-- WHY THE DEFAULT IS ENGLISH (do not "fix" it to Chinese)
-- ===========================================================================
-- A stock CC:Tweaked terminal ships NO CJK font, so Chinese prose renders as
-- garbage on screen.  English therefore works on ANY computer with ZERO extra
-- dependencies, and is the DEFAULT.  Chinese is opt-in: it is only usable once
-- a runtime-fetched pixel-font renderer is available.  Both languages are
-- present in this module from the start, so a machine without that renderer
-- still works perfectly in English.  Do NOT hard-code user-facing prose in a
-- renderer again -- add a key to BOTH tables below and call i18n.t().
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local i18n = require("ui.i18n")
--
--   i18n.DEFAULT_LANGUAGE      -- "en"
--   i18n.languages()           -- <array of supported codes, sorted, e.g. {"en","zh"}>
--   i18n.set_language(code)    -- true, or false + reason for an unknown code
--   i18n.get_language()        -- the active code
--   i18n.t(key, args)          -- the translated string, placeholders substituted
--   i18n.has(key)              -- true when the key exists in the ACTIVE language
--   i18n.missing_keys()        -- <array of keys present in "en" but absent in the
--                                 active language>
--
--   i18n.translations(code)    -- DIAGNOSTICS ONLY: the raw string table for a
--                                 language code, or nil.  Do not mutate it in
--                                 production code; it exists so tooling and
--                                 tests can inspect language completeness.
--
-- ===========================================================================
-- NAMED PLACEHOLDERS -- not positional
-- ===========================================================================
-- Sentences use NAMED placeholders such as "{min_key}" / "{count}", NOT the
-- positional "%s".  Chinese word order differs from English, so a translator
-- must be able to MOVE a placeholder within the sentence.  Substitution is
-- done here with string.gsub against `args`; string.format with positional
-- specifiers is never used.
--
--   * A placeholder with no matching arg keeps its literal "{name}" text -- so
--     a Lua `nil` can NEVER reach a rendered string.
--   * i18n.t NEVER raises, whatever it is handed.
--   * A MISSING key returns the KEY itself, so a gap is visible and greppable
--     rather than silent.  (There is deliberately NO English fallback at
--     render time: a gap in the active language must be seen.  Use
--     i18n.missing_keys() to find gaps in bulk.)
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no math.maxinteger, no collectgarbage, no string.dump, no os.exit
-- and no utf8.* -- the tables are plain Lua byte strings.

local i18n = {}

-- The language a fresh computer runs in.  English works everywhere; Chinese
-- needs a runtime-fetched CJK pixel-font renderer.
i18n.DEFAULT_LANGUAGE = "en"

-- ---------------------------------------------------------------------------
-- Translation tables.  ONE key set, one entry per supported language.
-- ---------------------------------------------------------------------------

local TRANSLATIONS = {}

-- English -- the default.  Plain ASCII so it renders on a stock terminal.
TRANSLATIONS.en = {
  -- extended-range: notes outside the native two octaves.
  ["warn.extended_range.both"] =
    "this song has notes outside the native two octaves (key {min_key}..{max_key}); "
    .. "install an extended-range resource pack to hear the full timbre",
  ["warn.extended_range.min"] =
    "this song has notes outside the native two octaves (lowest key {min_key}); "
    .. "install an extended-range resource pack to hear the full timbre",
  ["warn.extended_range.max"] =
    "this song has notes outside the native two octaves (highest key {max_key}); "
    .. "install an extended-range resource pack to hear the full timbre",
  ["warn.extended_range.none"] =
    "this song has notes outside the native two octaves; install an "
    .. "extended-range resource pack to hear the full timbre",

  -- speakers: peak concurrency vs. the speakers actually attached.  These are
  -- FRAGMENTS joined with a localised separator, because the renderer includes
  -- only the fields that are actually present.
  ["warn.speakers.peak"] = "this song peaks at {peak} notes/50ms",
  ["warn.speakers.required"] = "needs {required} speakers",
  ["warn.speakers.found"] = "found {found}",
  ["warn.speakers.dropped"] = "dropped {dropped} notes",
  ["warn.speakers.separator"] = ", ",
  ["warn.speakers.none"] = "not enough speakers; some notes cannot be played",

  -- custom-instrument: .nbs custom instruments are refused and skipped.
  ["warn.custom_instrument.count"] =
    "this song has {count} custom instruments; skipped (not played)",
  ["warn.custom_instrument.none"] =
    "this song has custom instruments; skipped (not played)",

  -- tempo-clamp: the SONG'S OWN tick interval is finer than the 50 ms timer
  -- granularity.  It is not about ordinary chords or the first note.
  ["warn.tempo_clamp"] =
    "tick interval is finer than the 0.05 s timer granularity; clamped",

  -- play-sound-pitch: a v6 trumpet pitch was clamped to an approximation.
  ["warn.play_sound_pitch"] =
    "a trumpet pitch was outside the representable range; clamped to an approximation",

  -- The generic fallback for an unknown warning code.
  ["warn.unknown"] = "unknown warning code; handled by the default policy",
}

-- Chinese -- opt-in, only usable when a CJK pixel-font renderer is loaded.
TRANSLATIONS.zh = {
  ["warn.extended_range.both"] =
    "本曲含超出原生两个八度的音符（key {min_key}..{max_key}），"
    .. "需安装扩展音域材质包才能听到完整音色",
  ["warn.extended_range.min"] =
    "本曲含超出原生两个八度的音符（最低 key {min_key}），"
    .. "需安装扩展音域材质包才能听到完整音色",
  ["warn.extended_range.max"] =
    "本曲含超出原生两个八度的音符（最高 key {max_key}），"
    .. "需安装扩展音域材质包才能听到完整音色",
  ["warn.extended_range.none"] =
    "本曲含超出原生两个八度的音符，需安装扩展音域材质包才能听到完整音色",

  ["warn.speakers.peak"] = "本曲峰值 {peak} 音符/50ms",
  ["warn.speakers.required"] = "需要 {required} 个扬声器",
  ["warn.speakers.found"] = "实际 {found} 个",
  ["warn.speakers.dropped"] = "已丢弃 {dropped} 个音符",
  ["warn.speakers.separator"] = "，",
  ["warn.speakers.none"] = "扬声器数量不足，部分音符无法播放",

  ["warn.custom_instrument.count"] = "本曲含 {count} 个自定义乐器，已跳过不播放",
  ["warn.custom_instrument.none"] = "本曲含自定义乐器，已跳过不播放",

  -- Corrected semantics: the SONG'S OWN tick interval is below the 50 ms timer
  -- granularity -- not an ordinary chord and not the first note.
  ["warn.tempo_clamp"] = "歌曲自身的节拍间隔低于 0.05 秒计时粒度，已钳制",

  ["warn.play_sound_pitch"] = "小号音高超出可表示范围，已钳制为近似值",

  ["warn.unknown"] = "未知警告码，已按默认方式处理",
}

-- The active language.  Module-level state, deliberately: the whole program
-- shares one UI language.
local active = i18n.DEFAULT_LANGUAGE

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Replace "{name}" placeholders in `text` with args[name].  A placeholder with
-- no matching arg is left verbatim -- never the Lua nil.  The outer parentheses
-- keep only string.gsub's first return value.
local function substitute(text, args)
  if type(text) ~= "string" then
    return text
  end
  -- Placeholder names may contain letters, digits and underscores
  -- (e.g. {min_key}); `%w` alone would miss the underscore.
  return (text:gsub("{([%w_]+)}", function(name)
    local value = args[name]
    if value == nil then
      return "{" .. name .. "}"
    end
    return tostring(value)
  end))
end

-- ---------------------------------------------------------------------------
-- Language registry
-- ---------------------------------------------------------------------------

-- i18n.languages() -> a FRESH, sorted array of supported codes.
function i18n.languages()
  local codes = {}
  for code in pairs(TRANSLATIONS) do
    codes[#codes + 1] = code
  end
  table.sort(codes)
  return codes
end

-- i18n.set_language(code) -> true | false, reason.  Never raises.
function i18n.set_language(code)
  if type(code) ~= "string" then
    return false, "language code must be a string, got " .. type(code)
  end
  if TRANSLATIONS[code] == nil then
    return false, "unsupported language '" .. code .. "' (supported: "
      .. table.concat(i18n.languages(), ", ") .. ")"
  end
  active = code
  return true
end

-- i18n.get_language() -> the active code.
function i18n.get_language()
  return active
end

-- i18n.translations(code) -> the raw table for a language, or nil.
-- DIAGNOSTICS ONLY: do not mutate in production code.
function i18n.translations(code)
  if type(code) ~= "string" then
    return nil
  end
  return TRANSLATIONS[code]
end

-- ---------------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------------

-- i18n.has(key) -> true when `key` exists in the ACTIVE language.
function i18n.has(key)
  if type(key) ~= "string" then
    return false
  end
  local table_for_language = TRANSLATIONS[active]
  return table_for_language ~= nil and table_for_language[key] ~= nil
end

-- i18n.t(key, args) -> translated, placeholder-substituted string.
--
-- Never raises and never returns nil.  A key absent from the ACTIVE language
-- returns the key itself, so a gap is visible and greppable.
function i18n.t(key, args)
  if type(key) ~= "string" then
    return ""
  end

  local table_for_language = TRANSLATIONS[active]
  local text = nil
  if table_for_language ~= nil then
    text = table_for_language[key]
  end
  if type(text) ~= "string" then
    return key
  end

  if type(args) ~= "table" then
    args = {}
  end
  return substitute(text, args)
end

-- i18n.missing_keys() -> a FRESH, sorted array of keys present in the DEFAULT
-- (English) language but absent from the ACTIVE language.
function i18n.missing_keys()
  local baseline = TRANSLATIONS[i18n.DEFAULT_LANGUAGE] or {}
  local table_for_language = TRANSLATIONS[active] or {}

  local missing = {}
  for key in pairs(baseline) do
    if table_for_language[key] == nil then
      missing[#missing + 1] = key
    end
  end
  table.sort(missing)
  return missing
end

return i18n
