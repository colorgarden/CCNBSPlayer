-- tests/nbs/decode_spec.lua
--
-- Tier-1 spec for nbs/decode.lua -- the WHOLE-FILE decode boundary.
--
-- FROZEN INTERFACE UNDER TEST
-- ---------------------------
--   local decode = require("nbs.decode")
--   decode.decode(bytes) -> { ok = true,  song = <song> }
--                        | { ok = false, error = { code = <string>, msg = <string>, ... } }
--
--   decode.decode must NEVER raise and must NEVER hang.  Any internal failure
--   becomes ok = false with a normalised error table.  The boundary pcall()s
--   the section parsers, which raise typed TABLES via error(tbl, 0), and passes
--   those tables through, preserving `.code`, `.msg` and extra fields such as
--   `.offset`; a non-table error becomes { code = "E_INTERNAL", msg = ... }.
--
--   song = {
--     header             = <nbs.header.parse result>
--     layers             = <nbs.layers.parse result>
--     notes              = <bare array>
--     custom_instruments = <nbs.instruments_custom.parse result>
--     song_length        = <integer effective length>
--     song_length_source = "header" | "notes" | "empty"
--   }
--
-- Fixture byte builders mirror tests/nbs/header_spec.lua.  Valid files are
-- built here in code; the malformed corpus is read from tests/corpus/malformed
-- (produced by tests/corpus/generate_malformed.lua).

local decode = require("nbs.decode")

-- ---------------------------------------------------------------------------
-- Project root (run.lua seeds package.path with "<root>/?.lua" first)
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

local CORPUS_DIR = join(ROOT, "tests/corpus/malformed")

-- ---------------------------------------------------------------------------
-- Byte builders
-- ---------------------------------------------------------------------------

local function s(...)
  return string.char(...)
end

local function i16(n)
  if n < 0 then
    n = n + 65536
  end
  return s(n % 256, math.floor(n / 256) % 256)
end

local function i32(n)
  if n < 0 then
    n = n + 4294967296
  end
  return s(n % 256,
           math.floor(n / 256) % 256,
           math.floor(n / 65536) % 256,
           math.floor(n / 16777216) % 256)
end

local function lstr(text)
  return i32(#text) .. text
end

-- A complete NEW-format header (v1..v6).
local function new_header(opts)
  opts = opts or {}
  local version = opts.version
  local parts = {
    s(0, 0),
    s(version),
    s(opts.vanilla_instrument_count or 16),
  }
  if version >= 3 then
    parts[#parts + 1] = opts.song_length_bytes or i16(opts.song_length or 0)
  end
  parts[#parts + 1] = i16(opts.layer_count or 1)
  parts[#parts + 1] = lstr(opts.name or "")
  parts[#parts + 1] = lstr(opts.author or "")
  parts[#parts + 1] = lstr(opts.original_author or "")
  parts[#parts + 1] = lstr(opts.description or "")
  parts[#parts + 1] = opts.tempo_bytes or i16(opts.tempo_raw or 1000)
  parts[#parts + 1] = s(opts.autosave or 0)
  parts[#parts + 1] = s(opts.autosave_duration or 10)
  parts[#parts + 1] = s(opts.time_signature or 4)
  parts[#parts + 1] = i32(opts.minutes_spent or 0)
  parts[#parts + 1] = i32(opts.left_clicks or 0)
  parts[#parts + 1] = i32(opts.right_clicks or 0)
  parts[#parts + 1] = i32(opts.blocks_added or 0)
  parts[#parts + 1] = i32(opts.blocks_removed or 0)
  parts[#parts + 1] = lstr(opts.midi_filename or "")
  if version >= 4 then
    parts[#parts + 1] = s(opts.loop or 0)
    parts[#parts + 1] = s(opts.max_loop_count or 0)
    parts[#parts + 1] = i16(opts.loop_start_tick or 0)
  end
  return table.concat(parts)
end

-- A complete LEGACY v0 header.
local function legacy_header(opts)
  opts = opts or {}
  return table.concat({
    opts.song_length_bytes or i16(opts.song_length or 0),
    i16(opts.layer_count or 1),
    lstr(opts.name or ""),
    lstr(opts.author or ""),
    lstr(opts.original_author or ""),
    lstr(opts.description or ""),
    opts.tempo_bytes or i16(opts.tempo_raw or 1000),
    s(opts.autosave or 0),
    s(opts.autosave_duration or 10),
    s(opts.time_signature or 4),
    i32(0), i32(0), i32(0), i32(0), i32(0),
    lstr(opts.midi_filename or ""),
  })
end

-- One note record: tick jump, layer jump, then the version-appropriate fields
-- and the end-of-layer terminator.
local function note(version, tick_jump, layer_jump, instrument, key)
  local parts = { i16(tick_jump), i16(layer_jump), s(instrument), s(key) }
  if version >= 4 then
    parts[#parts + 1] = s(100) -- velocity
    parts[#parts + 1] = s(100) -- panning
    parts[#parts + 1] = i16(0) -- pitch
  end
  parts[#parts + 1] = i16(0) -- end of layers for this tick
  return table.concat(parts)
end

-- A whole notes section: the given note chunks, then the i16(0) terminator.
local function notes_section(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    parts[#parts + 1] = chunk
  end
  parts[#parts + 1] = i16(0)
  return table.concat(parts)
end

-- One layer record for the given version.
local function layer_record(version, name, opts)
  opts = opts or {}
  local parts = { lstr(name) }
  if version >= 4 then
    parts[#parts + 1] = s(opts.lock or 0)
  end
  parts[#parts + 1] = s(opts.volume or 100)
  if version >= 2 then
    parts[#parts + 1] = s(opts.panning or 100)
  end
  return table.concat(parts)
end

-- File assemblies --------------------------------------------------------

local function v5_minimal()
  return new_header({ version = 5, song_length = 100, layer_count = 1 })
    .. notes_section({ note(5, 1, 1, 1, 45) })
    .. layer_record(5, "L0", { volume = 80 })
end

local function legacy_minimal()
  return legacy_header({ song_length = 456, layer_count = 1 })
    .. notes_section({ note(0, 1, 1, 1, 45) })
    .. layer_record(0, "L0", { volume = 80 })
end

local function v1_two_ticks()
  return new_header({ version = 1, layer_count = 1 })
    .. notes_section({
      note(1, 1, 1, 1, 45), -- tick 0
      note(1, 4, 1, 1, 50), -- tick 4
    })
    .. layer_record(1, "L0", { volume = 80 })
end

local function v3_stored_length(song_length, tick_jump)
  return new_header({ version = 3, song_length = song_length, layer_count = 0 })
    .. notes_section({ note(3, tick_jump, 1, 1, 45) })
end

-- POSITIVE CONTROL for the signed-wrap fix: layer_count 200 is the practical
-- maximum (the format docs warn above 200) and must keep decoding.  200 layer
-- records follow the notes section, so layers.parse's byte-budget guard is
-- satisfied honestly.
local function v5_200_layers()
  local chunks = {}
  for index = 1, 200 do
    chunks[#chunks + 1] = layer_record(5, "L" .. index, { volume = 100 })
  end
  return new_header({ version = 5, song_length = 100, layer_count = 200 })
    .. notes_section({ note(5, 1, 1, 1, 45) })
    .. table.concat(chunks)
end

-- ---------------------------------------------------------------------------
-- File helpers
-- ---------------------------------------------------------------------------

local function read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil
  end
  local data = handle:read("*a") or ""
  handle:close()
  return data
end

local function list_corpus(dir)
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
  return names
end

-- ---------------------------------------------------------------------------
-- The expected malformed corpus (see tests/corpus/generate_malformed.lua).
-- ---------------------------------------------------------------------------

local CORPUS = {
  { name = "empty.nbs",                  code = "E_TRUNCATED" },
  { name = "one_byte.nbs",               code = "E_TRUNCATED" },
  { name = "truncated_header.nbs",       code = "E_TRUNCATED" },
  { name = "version_9.nbs",              code = "E_UNSUPPORTED_VERSION" },
  { name = "negative_tick_jump.nbs",     code = "E_BAD_JUMP" },
  { name = "layer_overflow.nbs",         code = "E_LAYER_OVERFLOW" },
  { name = "absurd_layer_count.nbs",     code = "E_BAD_LAYER_COUNT" },
  { name = "negative_layer_count.nbs",   code = "E_BAD_LAYER_COUNT" },
  { name = "max_unsigned_layer_count.nbs", code = "E_BAD_LAYER_COUNT" },
  { name = "absurd_instrument_count.nbs", code = "E_BAD_INSTRUMENT_COUNT" },
  { name = "truncated_notes.nbs",        code = "E_TRUNCATED" },
  { name = "cyclic_jumps.nbs",           code = "E_TOO_MANY_TICKS" },
  { name = "truncated_layers.nbs",       code = "E_TRUNCATED" },
  { name = "huge_declared_string.nbs",   code = "E_TRUNCATED" },
  { name = "tempo_zero.nbs",             code = "E_BAD_TEMPO" },
  { name = "tempo_negative.nbs",         code = "E_BAD_TEMPO" },
}

local TIME_BOUND_SECONDS = 1.0

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("nbs.decode valid files", function()
  it("1. a minimal valid v5 file decodes with header/format/layers/notes", function()
    local result = decode.decode(v5_minimal())

    expect.equal(result.ok, true)
    expect.equal(result.song.header.version, 5)
    expect.equal(result.song.header.format, "new")

    expect.equal(type(result.song.layers), "table")
    expect.equal(#result.song.layers, 1)
    expect.equal(result.song.layers[1].name, "L0")
    expect.equal(result.song.layers[1].volume, 80)
    expect.equal(result.song.layers[1].panning, 100)

    expect.equal(type(result.song.notes), "table")
    expect.equal(#result.song.notes, 1)
    expect.equal(result.song.notes[1].tick, 0)
    expect.equal(result.song.notes[1].layer, 0)
    expect.equal(result.song.notes[1].instrument, 1)
    expect.equal(result.song.notes[1].key, 45)

    expect.equal(result.song.song_length, 100)
    expect.equal(result.song.song_length_source, "header")
  end)

  it("2. a minimal valid legacy v0 file decodes as format == legacy", function()
    local result = decode.decode(legacy_minimal())

    expect.equal(result.ok, true)
    expect.equal(result.song.header.version, 0)
    expect.equal(result.song.header.format, "legacy")
    expect.equal(result.song.header.song_length, 456)
    expect.equal(#result.song.layers, 1)
    expect.equal(#result.song.notes, 1)
    expect.equal(result.song.song_length, 456)
    expect.equal(result.song.song_length_source, "header")
  end)

  it("3. a v1 file (no stored length) derives its length from the notes", function()
    local result = decode.decode(v1_two_ticks())

    expect.equal(result.ok, true)
    expect.equal(result.song.header.version, 1)
    expect.equal(result.song.header.song_length, nil)
    expect.equal(result.song.song_length_source, "notes")
    expect.equal(result.song.song_length, 5) -- highest tick 4, plus one
  end)

  it("4. a v3 file uses its stored length", function()
    local result = decode.decode(v3_stored_length(8, 1)) -- note at tick 0

    expect.equal(result.ok, true)
    expect.equal(result.song.header.version, 3)
    expect.equal(result.song.song_length, 8)
    expect.equal(result.song.song_length_source, "header")
  end)

  it("8. effective length prefers the larger notes-derived value", function()
    -- Header claims 2, but the notes run to tick 9 (length 10).
    local result = decode.decode(v3_stored_length(2, 10))

    expect.equal(result.ok, true)
    expect.equal(result.song.song_length, 10)
    expect.equal(result.song.song_length_source, "notes")
  end)

  it("9. an absent custom-instrument section decodes as an empty array", function()
    local result = decode.decode(v5_minimal())

    expect.equal(result.ok, true)
    expect.equal(type(result.song.custom_instruments), "table")
    expect.equal(#result.song.custom_instruments, 0)
    expect.sequence_equal(result.song.custom_instruments, {})
  end)

  it("11. POSITIVE CONTROL: a valid file with layer_count 200 still decodes", function()
    -- Regression guard for the signed-wrap fix: 200 is a legitimate (practical
    -- maximum) count and must not be over-rejected by the new header guard.
    local result = decode.decode(v5_200_layers())

    expect.equal(result.ok, true)
    expect.equal(result.song.header.layer_count, 200)
    expect.equal(type(result.song.layers), "table")
    expect.equal(#result.song.layers, 200)
    expect.equal(result.song.layers[1].name, "L1")
    expect.equal(result.song.layers[200].name, "L200")
  end)
end)

describe("nbs.decode malformed corpus", function()
  it("the corpus directory holds exactly the expected files", function()
    for _, entry in ipairs(CORPUS) do
      local path = join(CORPUS_DIR, entry.name)
      local bytes = read_file(path)
      expect.truthy(bytes ~= nil)
    end

    local present = list_corpus(CORPUS_DIR)
    if #present > 0 then
      local seen = {}
      for _, name in ipairs(present) do
        seen[name] = true
      end
      for _, entry in ipairs(CORPUS) do
        expect.truthy(seen[entry.name])
      end
      expect.equal(#present, #CORPUS)
    end
  end)

  it("6. decode never raises on any corpus file (pcall itself succeeds)", function()
    for _, entry in ipairs(CORPUS) do
      local bytes = read_file(join(CORPUS_DIR, entry.name))
      local called, result = pcall(decode.decode, bytes)
      expect.truthy(called)
      expect.equal(type(result), "table")
    end
  end)

  it("6b. DECODE-LEVEL: signed-wrap layer_count files return ok == false, pcall succeeds", function()
    -- The raw counts 60000 (-> -5536) and 65535 (-> -1) wrap negative as a
    -- signed i16.  Before the header fix these decoded as ok == true (a silent
    -- success); they must now fail with E_BAD_LAYER_COUNT and the boundary
    -- pcall itself must succeed (no error escapes decode).
    for _, name in ipairs({
      "negative_layer_count.nbs",
      "max_unsigned_layer_count.nbs",
    }) do
      local bytes = read_file(join(CORPUS_DIR, name))
      expect.truthy(bytes ~= nil)

      local called, result = pcall(decode.decode, bytes)
      expect.truthy(called)
      expect.equal(type(result), "table")
      expect.equal(result.ok, false)
      expect.equal(type(result.error), "table")
      expect.equal(result.error.code, "E_BAD_LAYER_COUNT")
      expect.truthy(type(result.error.code) == "string" and #result.error.code > 0)
      expect.truthy(type(result.error.msg) == "string" and #result.error.msg > 0)
    end
  end)

  it("6c. DECODE-LEVEL (B4): tempo 0 / negative -> ok == false E_BAD_TEMPO, no raise, well under 1s", function()
    -- A structurally valid v5 file whose stored tempo is 0 (or negative) used
    -- to decode as a SUCCESS.  Downstream that produced tick_ms = inf and a
    -- NaN event deadline, so the session could never end.  The header guard
    -- rejects it; the boundary must surface the typed table unchanged.
    for _, name in ipairs({ "tempo_zero.nbs", "tempo_negative.nbs" }) do
      local bytes = read_file(join(CORPUS_DIR, name))
      expect.truthy(bytes ~= nil)

      local started = os.clock()
      local called, result = pcall(decode.decode, bytes)
      local elapsed = os.clock() - started

      expect.truthy(called) -- decode never raises
      expect.equal(type(result), "table")
      expect.equal(result.ok, false)
      expect.equal(type(result.error), "table")
      expect.equal(result.error.code, "E_BAD_TEMPO")
      expect.truthy(type(result.error.msg) == "string" and #result.error.msg > 0)
      expect.truthy(elapsed < TIME_BOUND_SECONDS)

      io.write(string.format("    B4 %-20s code=%-12s elapsed=%.4fs\n",
        name, result.error.code, elapsed))
    end
  end)

  it("6d. REGRESSION (B4): the CALLER path returns a clean error instead of a never-ending session", function()
    -- The hang was reachable through the public library: decode() succeeded,
    -- analyze() reported tick_ms = inf, the first event's t_ms was NaN and the
    -- tempo scheduler queued a deadline the clock could never satisfy.  With
    -- the guard the caller never obtains a song at all -- decode returns a
    -- typed error and `.song` stays nil, so analyze/plan/tempo are unreachable.
    local ccnbs = require("ccnbs")
    local bytes = read_file(join(CORPUS_DIR, "tempo_zero.nbs"))
    expect.truthy(bytes ~= nil)

    local started = os.clock()
    local called, result = pcall(ccnbs.decode, bytes)
    local elapsed = os.clock() - started

    expect.truthy(called)
    expect.equal(type(result), "table")
    expect.equal(result.ok, false)
    expect.equal(result.error.code, "E_BAD_TEMPO")
    expect.equal(result.song, nil)
    expect.truthy(elapsed < TIME_BOUND_SECONDS)

    io.write(string.format(
      "    B4-CALLER ok=%s code=%s song=%s elapsed=%.4fs\n",
      tostring(result.ok), tostring(result.error.code),
      tostring(result.song), elapsed))
  end)

  it("7. a truncated-but-parseable file fails with a precise code", function()
    local bytes = read_file(join(CORPUS_DIR, "truncated_notes.nbs"))
    local result = decode.decode(bytes)
    expect.equal(result.ok, false)
    expect.equal(result.error.code, "E_TRUNCATED")
    expect.truthy(type(result.error.msg) == "string" and #result.error.msg > 0)
  end)

  it("10. 32 bytes of assorted garbage returns ok == false with a string code", function()
    local parts = {}
    for index = 1, 32 do
      -- Deterministic assorted values spanning 0..255.
      parts[#parts + 1] = s((index * 37 + 11) % 256)
    end
    local garbage = table.concat(parts)

    local started = os.clock()
    local result = decode.decode(garbage)
    local elapsed = os.clock() - started

    expect.equal(type(result), "table")
    expect.equal(result.ok, false)
    expect.equal(type(result.error), "table")
    expect.truthy(type(result.error.code) == "string" and #result.error.code > 0)
    expect.truthy(elapsed < TIME_BOUND_SECONDS)

    io.write(string.format("    GARBAGE-32 code=%s elapsed=%.4fs\n",
      result.error.code, elapsed))
  end)

  it("10b. a longer garbage buffer is also rejected without raising", function()
    local parts = {}
    for index = 1, 256 do
      parts[#parts + 1] = s((index * 91 + 7) % 256)
    end
    local garbage = table.concat(parts)

    local started = os.clock()
    local called, result = pcall(decode.decode, garbage)
    local elapsed = os.clock() - started

    expect.truthy(called)
    expect.equal(result.ok, false)
    expect.truthy(type(result.error.code) == "string" and #result.error.code > 0)
    expect.truthy(elapsed < TIME_BOUND_SECONDS)

    io.write(string.format("    GARBAGE-256 code=%s elapsed=%.4fs\n",
      result.error.code, elapsed))
  end)
end)

-- Per-file corpus assertions: one test per file, reporting code and elapsed.
for _, entry in ipairs(CORPUS) do
  it("5. corpus " .. entry.name .. " -> " .. entry.code, function()
    local bytes = read_file(join(CORPUS_DIR, entry.name))
    expect.truthy(bytes ~= nil)

    local started = os.clock()
    local called, result = pcall(decode.decode, bytes)
    local elapsed = os.clock() - started

    expect.truthy(called) -- decode never raises
    expect.equal(type(result), "table")
    expect.equal(result.ok, false)
    expect.equal(type(result.error), "table")
    expect.equal(result.error.code, entry.code)
    expect.truthy(type(result.error.msg) == "string" and #result.error.msg > 0)

    io.write(string.format("    CORPUS %-26s code=%-24s elapsed=%.4fs\n",
      entry.name, result.error.code, elapsed))

    expect.truthy(elapsed < TIME_BOUND_SECONDS)
  end)
end
