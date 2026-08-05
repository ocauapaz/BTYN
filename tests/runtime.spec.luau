--!strict
--[[
	Tests for the runtime modules that carry no Roblox dependency of their own.

	`Channel` reaches for `script.Parent`, which does not exist outside Roblox,
	so its two requires are rewritten to parameters and fed stubs. Everything
	below them — the delta bookkeeping, the removal queue, the per-player budget
	— is plain Luau, and is where the interesting bugs live. The transport half
	is covered by the Studio integration test.
]]

local fs = require("@lune/fs")

local t = require("./harness")

--[[
	`task` is a Roblox global with no Lune equivalent. Only `spawn` is reached
	from the modules under test, and only ever to resume a parked thread.
]]
local TASK_SHIM = [[
local task = {
	spawn = function(target, ...)
		if type(target) == "thread" then
			coroutine.resume(target, ...)
		else
			coroutine.wrap(target)(...)
		end
	end,
}
]]

--[[
	Loads a runtime module with its `require(script.Parent.X)` calls replaced by
	injected stubs.
]]
local function loadRuntime(name: string, stubs: { [string]: any }): any
	local source = fs.readFile(`src/{name}.luau`)
	local names = {}

	for dependency in stubs do
		table.insert(names, dependency)
	end
	table.sort(names)

	local arguments = {}
	for index, dependency in names do
		source = string.gsub(source, `require%(script%.Parent%.{dependency}%)`, `STUB_{dependency}`)
		arguments[index] = stubs[dependency]
	end

	local header = if #names > 0 then `local STUB_{table.concat(names, ", STUB_")} = ...\n` else ""
	local chunk = assert(loadstring(TASK_SHIM .. header .. source, name))
	return (chunk :: any)(table.unpack(arguments, 1, #names))
end

--[[
	A channel set whose writes go nowhere. What is being checked here is who is
	told what, not the bytes — those are the codec suite's problem.
]]
local function newChannel(): (any, any)
	local Channel = loadRuntime("Channel", {
		Stream = { finish = function() end },
		Transport = {
			reserve = function(): (buffer, number, any)
				return buffer.create(64), 0, { refs = {} }
			end,
		},
	})

	local set = Channel.new({
		endpoint = {},
		opcode = 1,
		removeOpcode = 2,
		opcodeBytes = 1,
		maxSize = 8,
		priority = "normal",
		fields = { "hp", "downed" },
		write = function(): number
			return 1
		end,
	})

	return Channel, set
end

t.suite("Channel — handles")

t.test("destroying an id frees it for immediate reuse", function()
	-- Destroy used to only mark the handle, leaving it in the set until the next
	-- flush swept it. Re-creating the id in the same frame handed back the
	-- corpse, and everything written to it was dropped when the sweep ran.
	local Channel, set = newChannel()

	local first = Channel.of(set, 7)
	Channel.set(set, first, { hp = 50 })
	Channel.destroy(set, first)

	local second = Channel.of(set, 7)
	t.ok(second ~= first, "a destroyed id should hand back a fresh handle")

	Channel.set(set, second, { hp = 90 })
	t.eq(set.handles[7], second, "the new handle should own the id")
	t.eq(second.state.hp, 90)
end)

t.test("destroying twice queues one removal", function()
	local Channel, set = newChannel()

	local handle = Channel.of(set, 3)
	Channel.destroy(set, handle)
	Channel.destroy(set, handle)

	t.eq(#set.removed, 1, "a repeated destroy should be a no-op")
end)

t.test("a queued removal drains on the next flush", function()
	local Channel, set = newChannel()
	local player = { Name = "tester" } :: any

	local handle = Channel.of(set, 12)
	Channel.set(set, handle, { hp = 10 })
	Channel.audience(handle, { player })

	Channel.flushAll({ set }, 1000)
	t.ok(handle.known[player], "the audience should have been sent a keyframe")

	Channel.destroy(set, handle)
	Channel.flushAll({ set }, 1000)

	t.eq(#set.removed, 0, "the removal queue should be empty again")
	t.eq(set.handles[12], nil, "and the handle forgotten")
end)

t.test("leaving the audience drops what the player was owed", function()
	local Channel, set = newChannel()
	local player = { Name = "tester" } :: any

	local handle = Channel.of(set, 4)
	Channel.audience(handle, { player })
	Channel.flushAll({ set }, 1000)

	Channel.audience(handle, {})
	Channel.flushAll({ set }, 1000)

	t.eq(handle.known[player], nil, "the player should no longer be known")
	t.eq(handle.carry[player], nil, "and should carry nothing")
end)

t.test("an over-budget update is carried, not lost", function()
	local Channel, set = newChannel()
	local player = { Name = "tester" } :: any

	local handle = Channel.of(set, 5)
	Channel.audience(handle, { player })
	Channel.flushAll({ set }, 1000)

	-- A zero budget defers everything below high priority.
	Channel.set(set, handle, { hp = 1 })
	Channel.flushAll({ set }, 0)
	t.ok(handle.carry[player] ~= nil, "the deferred bits should be remembered")

	Channel.flushAll({ set }, 1000)
	t.eq(handle.carry[player], nil, "and go out on the next affordable frame")
end)

t.test("a table field set to the same reference still dirties", function()
	-- Tables compare by reference, so a caller mutating the same table in
	-- place would otherwise never be detected as a change and the update would
	-- silently never go out.
	local Channel, set = newChannel()
	local handle = Channel.of(set, 9)

	local box = { 1 }
	Channel.set(set, handle, { hp = box })
	handle.mask = 0

	box[1] = 2
	Channel.set(set, handle, { hp = box })
	t.ok(handle.mask ~= 0, "a re-set table must dirty its field")
end)

t.test("an unchanged scalar does not dirty", function()
	local Channel, set = newChannel()
	local handle = Channel.of(set, 10)

	Channel.set(set, handle, { downed = true })
	handle.mask = 0

	Channel.set(set, handle, { downed = true })
	t.eq(handle.mask, 0, "re-setting the same scalar must stay clean")
end)

t.suite("RateLimiter")

t.test("a bucket refuses once its burst is spent", function()
	local RateLimiter = loadRuntime("RateLimiter", {})
	local player = { Name = "tester" } :: any

	local bucket = RateLimiter.new(2)
	t.ok(RateLimiter.allow(bucket, player), "the first call is within the burst")
	t.ok(RateLimiter.allow(bucket, player), "and so is the second")
	t.ok(not RateLimiter.allow(bucket, player), "the third exceeds it")
end)

t.suite("Request")

t.test("an id in flight is skipped", function()
	local Request = loadRuntime("Request", {})
	local registry = Request.new(10)

	local first = Request.allocate(registry)
	registry.pending[first] = { thread = coroutine.running(), deadline = math.huge }

	t.ok(Request.allocate(registry) ~= first, "an id in flight should be skipped")
end)

-- A tombstone is what sweep leaves behind after a timeout: an entry with no
-- thread, holding the id for one more timeout period so a late reply cannot
-- land on a fresh request that reused it.

t.test("a timed-out id is not handed out while its tombstone lives", function()
	local Request = loadRuntime("Request", {})
	local registry = Request.new(10)

	registry.pending[1] = { deadline = math.huge }
	registry.nextId = 1

	t.eq(Request.allocate(registry), 2, "the tombstoned id should be skipped")
end)

t.test("a late reply consumes the tombstone silently", function()
	local Request = loadRuntime("Request", {})
	local registry = Request.new(10)

	registry.pending[5] = { deadline = math.huge }
	Request.resolve(registry, 5, true, "stale")

	t.eq(registry.pending[5], nil, "the late reply should free the id")
end)

t.test("a reply from the wrong peer is refused", function()
	-- The server's registry is shared across every player and ids are
	-- sequential, so without a peer check any client could answer — or
	-- blind-scan and answer — a request the server sent to somebody else.
	local Request = loadRuntime("Request", {})
	local registry = Request.new(10)

	local target = { Name = "target" } :: any
	local attacker = { Name = "attacker" } :: any
	local resumed = false

	local thread = coroutine.create(function()
		resumed = true
	end)
	registry.pending[1] = { thread = thread, deadline = math.huge, peer = target }

	Request.resolve(registry, 1, true, "forged", attacker)
	t.ok(not resumed, "a reply from another player must not resolve the request")
	t.ok(registry.pending[1] ~= nil, "and must not consume the pending entry")

	Request.resolve(registry, 1, true, "genuine", target)
	t.ok(resumed, "the real peer still resolves it")
end)

t.test("the client accepts a reply with no peer", function()
	-- On the client the only possible peer is the server, so both sides are
	-- nil and the check has to pass rather than reject everything.
	local Request = loadRuntime("Request", {})
	local registry = Request.new(10)
	local resumed = false

	registry.pending[1] = {
		thread = coroutine.create(function()
			resumed = true
		end),
		deadline = math.huge,
		peer = nil,
	}

	Request.resolve(registry, 1, true, "ok", nil)
	t.ok(resumed, "a server reply should resolve a client request")
end)

t.test("sweep clears an expired tombstone", function()
	local Request = loadRuntime("Request", {})
	local registry = Request.new(10)

	registry.pending[3] = { deadline = 0 }
	Request.sweep(registry)

	t.eq(registry.pending[3], nil, "the grace period should end")
end)
