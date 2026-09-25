-- tests/nbs/cp1252_spec.lua
--
-- Spec for nbs/cp1252.lua -- the single place where stored CP1252 bytes are
-- rendered as UTF-8 for human display.
--
-- Design notes:
--   * The module is written for stock Lua 5.2.4 (the project's local Tier-1
--     interpreter), which has NO utf8 library.  Every expected value here is
--     therefore expressed as explicit UTF-8 byte sequences, not via utf8.char.
--   * Assertions compare exact byte values with string.byte, never just string
--     length: a wrong code point must fail even if it is the same width.

local cp1252 = require("nbs.cp1252")

-- Collect a string's bytes into a sequence for exact comparison.
local function bytes_of(value)
  return { string.byte(value, 1, #value) }
end

describe("nbs.cp1252", function()

  describe("byte_to_utf8", function()

    it("leaves ASCII 0x41 as a single byte 'A'", function()
      local out = cp1252.byte_to_utf8(0x41)
      expect.equal(out, "A")
      expect.equal(#out, 1)
    end)

    it("encodes 0x93 (U+201C LEFT DOUBLE QUOTATION MARK) as bytes 226,128,156", function()
      expect.sequence_equal(bytes_of(cp1252.byte_to_utf8(0x93)), { 226, 128, 156 })
    end)

    it("encodes 0x94 (U+201D RIGHT DOUBLE QUOTATION MARK) as bytes 226,128,157", function()
      expect.sequence_equal(bytes_of(cp1252.byte_to_utf8(0x94)), { 226, 128, 157 })
    end)

    it("encodes 0x80 (U+20AC EURO SIGN) as bytes 226,130,172", function()
      expect.sequence_equal(bytes_of(cp1252.byte_to_utf8(0x80)), { 226, 130, 172 })
    end)

    it("maps the five undefined bytes to U+FFFD (bytes 239,191,189)", function()
      for _, undefined in ipairs({ 0x81, 0x8D, 0x8F, 0x90, 0x9D }) do
        expect.sequence_equal(bytes_of(cp1252.byte_to_utf8(undefined)), { 239, 191, 189 })
      end
    end)

    it("encodes 0xA9 (U+00A9 COPYRIGHT SIGN) as the 2-byte sequence 194,169", function()
      expect.sequence_equal(bytes_of(cp1252.byte_to_utf8(0xA9)), { 194, 169 })
    end)

    it("encodes 0xFF (U+00FF LATIN SMALL LETTER Y WITH DIAERESIS) as 195,191", function()
      expect.sequence_equal(bytes_of(cp1252.byte_to_utf8(0xFF)), { 195, 191 })
    end)

    it("maps every byte 0x00-0xFF without raising", function()
      for value = 0x00, 0xFF do
        local ok, err = pcall(cp1252.byte_to_utf8, value)
        if not ok then
          expect.fail("byte_to_utf8(" .. value .. ") raised: " .. tostring(err))
        end
        expect.equal(type(cp1252.byte_to_utf8(value)), "string")
      end
    end)

  end)

  describe("to_display", function()

    it("passes a plain ASCII string through unchanged", function()
      expect.equal(cp1252.to_display("abc"), "abc")
    end)

    it("returns an empty string for an empty input", function()
      expect.equal(cp1252.to_display(""), "")
    end)

    it("expands 0x93,0x94 into two 3-byte characters (length 6)", function()
      -- "\147\148" is the raw CP1252 byte pair the reader would hand us.
      local out = cp1252.to_display("\147\148")
      expect.equal(#out, 6)
      expect.sequence_equal(bytes_of(out), { 226, 128, 156, 226, 128, 157 })
    end)

    it("never mutates the input string (display-only transform)", function()
      local stored = "\147\65\255" -- 3 bytes: 0x93, 'A', 0xFF
      local rendered = cp1252.to_display(stored)

      -- The rendered value is the transformed one...
      expect.sequence_equal(bytes_of(rendered), { 226, 128, 156, 65, 195, 191 })
      -- ...but the original stays byte-exact and is still 3 bytes long.
      expect.equal(#stored, 3)
      expect.sequence_equal(bytes_of(stored), { 147, 65, 255 })
    end)

  end)

end)
