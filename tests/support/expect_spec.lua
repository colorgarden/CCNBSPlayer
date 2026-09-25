-- tests/support/expect_spec.lua
--
-- Self-test for tests/support/expect.lua. Every assertion gets a happy path and
-- a failure path; the failure paths wrap the assertion in expect.raises to prove
-- that a failing assertion really raises.

local expect = require("tests.support.expect")

describe("expect.equal", function()
  it("passes for equal scalars", function()
    expect.equal(1, 1)
    expect.equal("a", "a")
    expect.equal(true, true)
    expect.equal(nil, nil)
  end)

  it("raises with a readable diff on unequal scalars", function()
    local message = expect.raises(function()
      expect.equal(1, 2)
    end, "expect.equal")
    expect.contains(message, "expected")
    expect.contains(message, "actual")
  end)
end)

describe("expect.deep_equal", function()
  it("passes for nested tables with arrays and hash parts", function()
    expect.deep_equal(
      { name = "song", layers = { { volume = 100 }, { volume = 50 } }, tempo = 10 },
      { name = "song", layers = { { volume = 100 }, { volume = 50 } }, tempo = 10 })
  end)

  it("passes when hash keys were inserted in a different order", function()
    local actual = {}
    actual.alpha = 1
    actual.beta = { x = 1, y = 2 }
    actual.gamma = "g"

    local expected = {}
    expected.gamma = "g"
    expected.beta = { y = 2, x = 1 }
    expected.alpha = 1

    expect.deep_equal(actual, expected)
  end)

  it("reports the first differing path with both values", function()
    local message = expect.raises(function()
      expect.deep_equal(
        { layers = { { volume = 100 }, { volume = 50 } } },
        { layers = { { volume = 100 }, { volume = 99 } } })
    end, "expect.deep_equal")
    expect.contains(message, "$.layers[2].volume")
    expect.contains(message, "expected")
    expect.contains(message, "actual")
  end)

  it("detects a key present on only one side", function()
    expect.raises(function()
      expect.deep_equal({ a = 1 }, { a = 1, b = 2 })
    end, "expect.deep_equal")
  end)
end)

describe("expect.sequence_equal", function()
  it("passes for identical ordered lists", function()
    expect.sequence_equal({ "a", "b", "c" }, { "a", "b", "c" })
    expect.sequence_equal(
      { { "back", "playNote" }, { "left", "playNote" } },
      { { "back", "playNote" }, { "left", "playNote" } })
  end)

  it("fails on swapped elements and reports the first index", function()
    local message = expect.raises(function()
      expect.sequence_equal({ "b", "a", "c" }, { "a", "b", "c" })
    end, "expect.sequence_equal")
    expect.contains(message, "index 1")
    expect.contains(message, "expected")
    expect.contains(message, "actual")
  end)

  it("fails on a length mismatch", function()
    local message = expect.raises(function()
      expect.sequence_equal({ "a" }, { "a", "b" })
    end, "expect.sequence_equal")
    expect.contains(message, "length mismatch")
    expect.contains(message, "expected 2 element(s) actual 1 element(s)")
  end)
end)

describe("expect.truthy / expect.falsy", function()
  it("passes for truthy values", function()
    expect.truthy(true)
    expect.truthy(1)
    expect.truthy("x")
    expect.truthy({})
  end)

  it("fails for falsy values with a named message", function()
    local message = expect.raises(function()
      expect.truthy(false)
    end, "expect.truthy")
    expect.contains(message, "actual")
    expect.raises(function()
      expect.truthy(nil)
    end, "expect.truthy")
  end)

  it("passes for falsy values", function()
    expect.falsy(false)
    expect.falsy(nil)
  end)

  it("fails for truthy values", function()
    expect.raises(function()
      expect.falsy(1)
    end, "expect.falsy")
  end)
end)

describe("expect.contains", function()
  it("passes when the needle is present", function()
    expect.contains("hello world", "lo wo")
    expect.contains("WARN[custom-instrument]", "[custom-instrument]")
  end)

  it("fails when the needle is absent", function()
    local message = expect.raises(function()
      expect.contains("hello world", "xyz")
    end, "expect.contains")
    expect.contains(message, "actual")
  end)

  it("rejects non-string input", function()
    expect.raises(function()
      expect.contains("hello", 5)
    end, "expect.contains")
  end)
end)

describe("expect.matches", function()
  it("passes on a Lua pattern match", function()
    expect.matches("PASS smoke", "^PASS")
    expect.matches("player/plan.lua", "plan%.lua$")
  end)

  it("fails when the pattern does not match", function()
    local message = expect.raises(function()
      expect.matches("abc", "^z")
    end, "expect.matches")
    expect.contains(message, "actual")
  end)
end)

describe("expect.raises", function()
  it("passes when the function raises", function()
    local message = expect.raises(function()
      error("boom")
    end)
    expect.contains(message, "boom")
  end)

  it("passes when the expected substring is present", function()
    expect.raises(function()
      error("specific failure")
    end, "specific")
  end)

  it("fails when the function returns normally", function()
    local message = expect.raises(function()
      expect.raises(function()
        return 1
      end, "whatever")
    end, "expect.raises")
    expect.contains(message, "returned normally")
  end)

  it("fails when the message lacks the expected substring", function()
    local message = expect.raises(function()
      expect.raises(function()
        error("boom")
      end, "not-there")
    end, "expect.raises")
    expect.contains(message, "boom")
  end)
end)

describe("expect.near", function()
  it("passes within tolerance", function()
    expect.near(1.0, 1.05, 0.1)
    expect.near(1000, 1001, 2)
  end)

  it("fails outside tolerance", function()
    local message = expect.raises(function()
      expect.near(1.0, 2.0, 0.1)
    end, "expect.near")
    expect.contains(message, "actual")
  end)
end)

describe("expect.fail", function()
  it("always raises with the given message", function()
    local message = expect.raises(function()
      expect.fail("boom")
    end, "expect.fail")
    expect.contains(message, "boom")
  end)
end)
