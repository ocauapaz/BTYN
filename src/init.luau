--!strict
--[[
	BTYN runtime.

	Generated code requires this module; you normally never touch it directly.
	The compiler emits everything schema-specific, and what lives here is only
	the part that cannot be specialised: the two remotes, the per-player
	batches, and the frame loop that flushes them.
]]

local BTYN = {}

BTYN.Stream = require(script.Stream)
BTYN.Transport = require(script.Transport)
BTYN.Channel = require(script.Channel)
BTYN.RateLimiter = require(script.RateLimiter)
BTYN.Request = require(script.Request)

return BTYN
