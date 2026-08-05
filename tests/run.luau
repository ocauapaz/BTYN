--!strict
--[[
	Headless test entry point.

	    lune run tests/run

	Everything under test here is pure Luau with no Roblox globals, which is why
	the codec and compiler are deliberately kept free of them — it keeps the
	majority of the system testable in a second instead of needing Studio.
]]

local process = require("@lune/process")

local Diagnostics = require("../cli/Diagnostics")
local harness = require("./harness")

-- Golden error strings are compared as plain text.
Diagnostics.setColor(false)

require("./parser.spec")
require("./analyze.spec")
require("./codec.spec")
require("./emit.spec")
require("./channel.spec")
require("./runtime.spec")
require("./transport.spec")

process.exit(harness.run())
