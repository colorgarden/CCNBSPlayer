-- tests/smoke_spec.lua
--
-- The smallest possible spec: it proves that tests/run.lua discovers and runs
-- spec files and that the global `expect` module is installed.

describe("smoke", function()
  it("test harness is alive", function()
    expect.truthy(true)
    expect.equal(1 + 1, 2)
  end)
end)
