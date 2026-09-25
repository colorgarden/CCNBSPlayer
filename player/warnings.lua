-- player/warnings.lua
--
-- THE WARNING RENDERER -- the SINGLE place that turns a bare warning code into
-- a stable, machine-detectable, ONCE-PER-SONG line.
--
-- ===========================================================================
-- BARE-CODE OWNERSHIP SPLIT (deliberate -- do not "unify" it)
-- ===========================================================================
-- Several modules EMIT bare codes; NONE of them know how to present them:
--
--   player/dispatch.lua  -> dispatch.WARN_CUSTOM_INSTRUMENT = "custom-instrument"
--                           dispatch.WARN_PLAY_SOUND_PITCH  = "play-sound-pitch"
--   player/tempo.lua     -> tempo.CLAMP_WARN_CODE          = "tempo-clamp"
--   player/fanout.lua    -> assignment.warning_code        = "speakers"
--                           assignment.warning_args        = { peak, required,
--                                                              found, dropped }
--   nbs/analyze.lua      -> analysis.has_extended_range    => "extended-range"
--                           (with analysis.min_key / analysis.max_key)
--
-- ccnbs.lua already deduplicates them BY CODE and forwards each code ONCE to
-- its own callback `opts.on_warning(code, args)`.  That contract is FROZEN and
-- lives in ccnbs.lua; THIS module does not change it.  What this module owns is
-- the presentation layer:
--
--   * the STABLE marker format `WARN[<code>] <Chinese explanation>`, and
--   * the ONCE-PER-SONG rule at the presentation layer, so a line is printed at
--     most once per renderer/session even if a caller reports the same code
--     many times.
--
-- ===========================================================================
-- FROZEN PUBLIC INTERFACE
-- ===========================================================================
--   local warnings = require("player.warnings")
--
--   warnings.CODES = {
--     EXTENDED_RANGE    = "extended-range",
--     SPEAKERS          = "speakers",
--     CUSTOM_INSTRUMENT = "custom-instrument",
--     TEMPO_CLAMP       = "tempo-clamp",
--     PLAY_SOUND_PITCH  = "play-sound-pitch",
--   }
--   warnings.MARKER_PREFIX       -- "WARN"
--
--   warnings.format(code, args) -> string
--       PURE formatter: no state, never emits.  Calling it twice with the same
--       arguments returns identical strings.  An UNKNOWN code still formats
--       deterministically as `WARN[<code>] ...` instead of raising.  A missing
--       or malformed args table never raises and never renders a Lua `nil`.
--
--   warnings.new(opts) -> w
--       opts.emit   function(line) called for each NEWLY emitted line.
--                   Default: print.
--       opts.quiet  boolean.  When true nothing is passed to opts.emit, but the
--                   once-only ledger STILL records what WOULD have been emitted
--                   (so w:has()/w:lines() stay truthful under --quiet).
--
--   w:report(code, args) -> line | nil
--       Formats and emits the line for `code` AT MOST ONCE per renderer
--       instance.  Returns the emitted line, or nil when suppressed (duplicate)
--       or quiet.  A second report of the same code returns nil and does NOT
--       call opts.emit.
--   w:has(code)  -> boolean   -- whether this code has already been reported
--   w:lines()    -> array     -- emitted (or would-be emitted) lines, in order
--   w:reset()                 -- clears the ledger so a fresh song can warn again
--
--   warnings.to_callback(w) -> function(code, args)
--       The INTENDED way to wire the renderer into the existing ccnbs contract:
--           local w = warnings.new({ emit = function(line) print(line) end })
--           ccnbs.play(song, { on_warning = warnings.to_callback(w) })
--       It simply calls w:report(code, args), so ccnbs keeps forwarding BARE
--       codes and this module keeps owning the WARN[...] rendering plus the
--       once-per-song rule.
--
-- ===========================================================================
-- THE MARKER FORMAT IS A CONTRACT
-- ===========================================================================
-- Every emitted line begins with `WARN[<code>]` followed by a space and a
-- human-readable Chinese explanation, e.g.
--   WARN[extended-range] 本曲含超出原生两个八度的音符（key 27..46），...
--   WARN[speakers] 本曲峰值 9 音符/50ms，需要 2 个扬声器，...
-- The `WARN[<code>]` prefix is machine-detectable and must not change; the
-- prose after it is written in Chinese for the project owner.
--
-- Compatibility: Lua 5.2 / CC:Tweaked Cobalt.  No integer division, no bitwise
-- operators, no utf8.*, no collectgarbage, no string.dump, no os.exit.  This
-- module never prints directly -- every line goes through opts.emit.

local warnings = {}

-- The marker every line begins with.  Machine-detectable, non-negotiable.
warnings.MARKER_PREFIX = "WARN"

-- The five frozen bare codes this renderer knows.  Callers may still report an
-- unknown code -- it renders as a generic line and still obeys once-only.
warnings.CODES = {
  EXTENDED_RANGE = "extended-range",
  SPEAKERS = "speakers",
  CUSTOM_INSTRUMENT = "custom-instrument",
  TEMPO_CLAMP = "tempo-clamp",
  PLAY_SOUND_PITCH = "play-sound-pitch",
}

-- ---------------------------------------------------------------------------
-- Defensive arg readers -- callers vary, so nothing here may ever raise and no
-- Lua `nil` may ever reach a line.
-- ---------------------------------------------------------------------------

local function is_number(value)
  return type(value) == "number"
end

-- A number rendered for prose.  Never returns the string "nil".
local function num(value)
  return tostring(value)
end

-- Explain one code in Chinese.  `args` is already normalised to a table (or an
-- empty table); this function reads only the fields it needs and degrades
-- gracefully when a field is absent or of the wrong type.
local function explain(code, args)
  if code == warnings.CODES.EXTENDED_RANGE then
    local min_key = args.min_key
    local max_key = args.max_key
    if is_number(min_key) and is_number(max_key) then
      return "本曲含超出原生两个八度的音符（key " .. num(min_key) .. ".."
        .. num(max_key) .. "），需安装扩展音域材质包才能听到完整音色"
    elseif is_number(min_key) then
      return "本曲含超出原生两个八度的音符（最低 key " .. num(min_key)
        .. "），需安装扩展音域材质包才能听到完整音色"
    elseif is_number(max_key) then
      return "本曲含超出原生两个八度的音符（最高 key " .. num(max_key)
        .. "），需安装扩展音域材质包才能听到完整音色"
    end
    return "本曲含超出原生两个八度的音符，需安装扩展音域材质包才能听到完整音色"

  elseif code == warnings.CODES.SPEAKERS then
    local parts = {}
    if is_number(args.peak) then
      parts[#parts + 1] = "本曲峰值 " .. num(args.peak) .. " 音符/50ms"
    end
    if is_number(args.required) then
      parts[#parts + 1] = "需要 " .. num(args.required) .. " 个扬声器"
    end
    if is_number(args.found) then
      parts[#parts + 1] = "实际 " .. num(args.found) .. " 个"
    end
    if is_number(args.dropped) then
      parts[#parts + 1] = "已丢弃 " .. num(args.dropped) .. " 个音符"
    end
    if #parts == 0 then
      return "扬声器数量不足，部分音符无法播放"
    end
    return table.concat(parts, "，")

  elseif code == warnings.CODES.CUSTOM_INSTRUMENT then
    if is_number(args.count) then
      return "本曲含 " .. num(args.count) .. " 个自定义乐器，已跳过不播放"
    end
    return "本曲含自定义乐器，已跳过不播放"

  elseif code == warnings.CODES.TEMPO_CLAMP then
    return "节拍间隔低于 0.05 秒计时粒度，已钳制"

  elseif code == warnings.CODES.PLAY_SOUND_PITCH then
    return "小号音高超出可表示范围，已钳制为近似值"
  end

  -- Unknown code: deterministic generic explanation.
  return "未知警告码，已按默认方式处理"
end

-- ---------------------------------------------------------------------------
-- Pure formatter
-- ---------------------------------------------------------------------------

-- warnings.format(code, args) -> string.  Pure: no state, no ledger, no emit.
-- Total: a non-string code and a nil/non-table args never raise.
function warnings.format(code, args)
  if type(code) ~= "string" then
    code = "unknown"
  end
  if type(args) ~= "table" then
    args = {}
  end
  return warnings.MARKER_PREFIX .. "[" .. code .. "] " .. explain(code, args)
end

-- ---------------------------------------------------------------------------
-- Renderer instance: a once-only ledger plus the emit seam
-- ---------------------------------------------------------------------------

local Warn = {}
Warn.__index = Warn

-- warnings.new(opts) -> w.  Each renderer owns its OWN ledger, so two concurrent
-- songs never share once-only state.
function warnings.new(opts)
  opts = opts or {}

  local emit = opts.emit
  if type(emit) ~= "function" then
    emit = print
  end

  local self = setmetatable({}, Warn)
  self._emit = emit
  self._quiet = opts.quiet == true
  self._seen = {}
  self._lines = {}
  return self
end

-- w:report(code, args) -> line | nil
--
-- At most once per code per renderer.  Records the line in the ledger even when
-- quiet; returns nil for a duplicate or under quiet.
function Warn:report(code, args)
  if type(code) ~= "string" then
    code = "unknown"
  end
  if self._seen[code] then
    return nil
  end
  self._seen[code] = true

  local line = warnings.format(code, args)
  self._lines[#self._lines + 1] = line

  if self._quiet then
    return nil
  end
  self._emit(line)
  return line
end

-- w:has(code) -> boolean.  Whether this code has already been reported.
function Warn:has(code)
  return self._seen[code] == true
end

-- w:lines() -> array.  A COPY of the emitted (or, under quiet, would-be emitted)
-- lines, in emission order.
function Warn:lines()
  local copy = {}
  for index = 1, #self._lines do
    copy[index] = self._lines[index]
  end
  return copy
end

-- w:reset() -> clears the ledger so a fresh song can warn again.
function Warn:reset()
  self._seen = {}
  self._lines = {}
end

-- warnings.to_callback(w) -> function(code, args)
--
-- The adapter that composes this renderer with the existing (frozen) ccnbs
-- contract, which forwards BARE codes:
--     ccnbs.play(song, { on_warning = warnings.to_callback(w) })
function warnings.to_callback(w)
  return function(code, args)
    return w:report(code, args)
  end
end

return warnings
