-- Example spec for vibe.nvim. Demonstrates the plenary test pattern; extend
-- with real behavioural specs as features land. Keep these dependency-free so
-- they run on any headless Neovim with plenary on the runtimepath.

local vibe = require("vibe")

describe("vibe.version", function()
  it("exposes major.minor.patch components", function()
    assert.is_number(vibe.version.major)
    assert.is_number(vibe.version.minor)
    assert.is_number(vibe.version.patch)
  end)

  it("formats as semver string", function()
    local s = vibe.version:string()
    assert.truthy(string.match(s, "^%d+%.%d+%.%d+"))
  end)
end)

describe("vibe module surface", function()
  it("exposes a setup() entry point", function()
    assert.is_function(vibe.setup)
  end)

  it("exposes the documented public send actions", function()
    assert.is_function(vibe.send_file)
    assert.is_function(vibe.send_text)
    assert.is_function(vibe.send_selection)
  end)
end)
