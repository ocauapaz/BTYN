--!strict
--[[
	Tests for the transport, against stand-ins for the Roblox globals.

	This is the code an attacker actually reaches: `consume` walks a buffer the
	sender controls, and everything it refuses is refused here rather than in a
	handler. The Studio script covers the same ground over a real wire, but only
	when somebody remembers to run it — these run in CI.

	The stand-ins are deliberately thin. Signals record their handlers so a test
	can fire them, remotes record what they were asked to send, and nothing else
	is modelled.
]]

local Stream = require("../src/Stream")
local loader = require("./loader")
local t = require("./harness")

type Signal = { handlers: { (...any) -> () }, Connect: (Signal, (...any) -> ()) -> any, fire: (Signal, ...any) -> () }

local function newSignal(): any
	local signal = { handlers = {} }

	function signal.Connect(self: any, fn: (...any) -> ()): any
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end

	function signal.fire(self: any, ...: any)
		for _, fn in self.handlers do
			fn(...)
		end
	end

	return signal
end

local function newRemote(name: string): any
	local remote = { Name = name, sent = {} }

	remote.OnServerEvent = newSignal()
	remote.OnClientEvent = newSignal()

	-- Mirrors the engine: firing at a player who has left throws. That throw is
	-- the whole reason the flush guards on `Parent`, so a fixture that quietly
	-- accepted it would let the regression back in unnoticed.
	function remote.FireClient(self: any, player: any, payload: buffer, refs: any)
		if player.Parent == nil then
			error(`{player.Name} is not a descendant of Players`, 0)
		end
		table.insert(self.sent, { player = player, payload = payload, refs = refs })
	end

	function remote.FireServer(self: any, payload: buffer, refs: any)
		table.insert(self.sent, { payload = payload, refs = refs })
	end

	return remote
end

export type Fixture = {
	Transport: any,
	endpoint: any,
	reliable: any,
	unreliable: any,
	players: any,
	abuse: { string },
	world: any,
}

--[[
	Builds an endpoint wired to stand-in remotes.

	`manual` is always on: an automatic Heartbeat flush would make every
	assertion about what was sent depend on timing.
]]
local function fixture(isServer: boolean, overrides: { [string]: any }?): Fixture
	local reliable = newRemote("R")
	local unreliable = newRemote("U")

	local function container(children: { [string]: any }): any
		local node = { children = children }
		function node.FindFirstChild(self: any, name: string): any
			return self.children[name]
		end
		node.WaitForChild = node.FindFirstChild
		return node
	end

	local folder = container({ R = reliable, U = unreliable })

	-- The remotes hang off the last segment of the configured path, so a nested
	-- `remotes` gets a nested fixture and the walk has something to walk.
	local segments = {}
	for segment in string.gmatch((overrides and overrides.remotes) or "BTYN", "[^/]+") do
		table.insert(segments, segment)
	end
	local node = folder
	for i = #segments, 2, -1 do
		node = container({ [segments[i]] = node })
	end
	local replicatedStorage = container({ [segments[1]] = node })

	local players = { list = {}, PlayerRemoving = newSignal() }
	function players.GetPlayers(self: any): { any }
		return self.list
	end

	local runService = { Heartbeat = newSignal() }
	function runService.IsServer(): boolean
		return isServer
	end

	local services: { [string]: any } = {
		Players = players,
		RunService = runService,
		ReplicatedStorage = replicatedStorage,
	}

	local world = {}
	function world.GetService(_: any, name: string): any
		local service = services[name]
		if service == nil then
			error(`the fixture does not model {name}`, 0)
		end
		return service
	end

	local Transport = loader.load("Transport", { Stream = Stream }, {
		game = world,
		-- Every remote the fixture needs already exists, so this is only here
		-- to fail loudly if the module ever starts creating its own.
		Instance = {
			new = function(className: string)
				error(`the fixture does not create instances ({className})`, 0)
			end,
		},
	})

	local config = {
		opcodeBytes = 1,
		unreliableCap = 800,
		budget = 40000,
		manual = true,
		maxPacketsPerBatch = 4,
	}
	for key, value in overrides or {} do
		config[key] = value
	end

	local endpoint = Transport.new(config)

	local abuse: { string } = {}
	endpoint.onAbuse = function(_: any, reason: string)
		table.insert(abuse, reason)
	end

	Transport.start(endpoint)

	return {
		Transport = Transport,
		endpoint = endpoint,
		reliable = reliable,
		unreliable = unreliable,
		players = players,
		abuse = abuse,
		world = world,
	}
end

--[[
	A payload of `count` empty packets: the smallest thing a batch can carry,
	and so the shape of the amplification the ceiling exists to stop.
]]
local function emptyPackets(count: number): buffer
	-- Opcode 0 with a zero-length body, so every byte is one whole packet.
	return buffer.create(count)
end

--[[
	Registers a handler that consumes nothing and counts its calls.
]]
local function countingHandler(f: Fixture, opcode: number, reliable: boolean): () -> number
	local calls = 0
	f.Transport.setHandler(f.endpoint, opcode, function(): number
		calls += 1
		return 0
	end, reliable)
	return function()
		return calls
	end
end

t.suite("Transport — remote location")

t.test("a nested `remotes` path is walked segment by segment", function()
	-- A project that keeps its framework under one folder configures the path
	-- rather than accepting a stray instance at the root. The fixture creates
	-- no instances, so reaching the remotes at all proves the walk.
	local f = fixture(true, { remotes = "NDF/BTYN" })
	local calls = countingHandler(f, 0, true)

	f.reliable.OnServerEvent:fire({ Name = "honest" }, emptyPackets(1))

	t.eq(calls(), 1, "the endpoint should be wired to the nested remotes")
end)

t.test("the client walks the same nested path", function()
	local f = fixture(false, { remotes = "NDF/BTYN" })
	local calls = countingHandler(f, 0, true)

	f.reliable.OnClientEvent:fire(emptyPackets(1))

	t.eq(calls(), 1, "the client resolves through WaitForChild on every segment")
end)

t.suite("Transport — batch ceiling")

t.test("a batch over the ceiling is refused and reported", function()
	-- The smallest packet is one opcode byte, so without a ceiling a payload
	-- of a few tens of kilobytes becomes tens of thousands of handler calls in
	-- a single frame — an amplification the per-packet rate limits never see,
	-- because they are only reached once the work has been done.
	local f = fixture(true)
	local calls = countingHandler(f, 0, true)

	f.reliable.OnServerEvent:fire({ Name = "attacker" }, emptyPackets(64))

	t.eq(calls(), 4, "the walk should stop at the ceiling")
	t.eq(#f.abuse, 1, "and report the sender")
	t.ok(string.find(f.abuse[1], "more than 4 packets", 1, true), `unexpected reason: {f.abuse[1]}`)
end)

t.test("a batch at the ceiling is processed in full", function()
	local f = fixture(true)
	local calls = countingHandler(f, 0, true)

	f.reliable.OnServerEvent:fire({ Name = "honest" }, emptyPackets(4))

	t.eq(calls(), 4, "everything up to the ceiling is legitimate")
	t.eq(#f.abuse, 0, "and nothing to report")
end)

t.test("the ceiling is configurable", function()
	local f = fixture(true, { maxPacketsPerBatch = 16 })
	local calls = countingHandler(f, 0, true)

	f.reliable.OnServerEvent:fire({ Name = "honest" }, emptyPackets(16))

	t.eq(calls(), 16)
	t.eq(#f.abuse, 0)
end)

t.test("the client does not apply the ceiling", function()
	-- Everything the client receives came from the server, which is not the
	-- untrusted peer. Server batches legitimately run to hundreds of packets:
	-- a channel keyframe per replicated entity is one each.
	local f = fixture(false)
	local calls = countingHandler(f, 0, true)

	f.reliable.OnClientEvent:fire(emptyPackets(64))

	t.eq(calls(), 64, "the client should trust the server's batch")
	t.eq(#f.abuse, 0)
end)

t.suite("Transport — channel binding")

t.test("a reliable packet sent unreliably is refused", function()
	-- Both remotes feed the same handler table, so without this a client could
	-- send anything down either one and help itself to both of the engine's
	-- throttles.
	local f = fixture(true)
	local calls = countingHandler(f, 0, true)

	f.unreliable.OnServerEvent:fire({ Name = "attacker" }, emptyPackets(1))

	t.eq(calls(), 0, "the handler must not run")
	t.eq(#f.abuse, 1)
	t.ok(string.find(f.abuse[1], "wrong channel", 1, true), `unexpected reason: {f.abuse[1]}`)
end)

t.test("a packet on its declared channel is accepted", function()
	local f = fixture(true)
	local reliableCalls = countingHandler(f, 0, true)
	local unreliableCalls = countingHandler(f, 1, false)

	f.reliable.OnServerEvent:fire({ Name = "honest" }, emptyPackets(1))

	local unreliablePayload = buffer.create(1)
	buffer.writeu8(unreliablePayload, 0, 1)
	f.unreliable.OnServerEvent:fire({ Name = "honest" }, unreliablePayload)

	t.eq(reliableCalls(), 1)
	t.eq(unreliableCalls(), 1)
	t.eq(#f.abuse, 0)
end)

t.test("the client does not apply channel binding", function()
	local f = fixture(false)
	local calls = countingHandler(f, 0, true)

	f.unreliable.OnClientEvent:fire(emptyPackets(1))

	t.eq(calls(), 1, "the client should trust whichever remote the server used")
	t.eq(#f.abuse, 0)
end)

t.suite("Transport — malformed input")

t.test("a payload that is not a buffer is refused", function()
	local f = fixture(true)
	f.reliable.OnServerEvent:fire({ Name = "attacker" }, "not a buffer")

	t.eq(#f.abuse, 1)
	t.ok(string.find(f.abuse[1], "not a buffer", 1, true), `unexpected reason: {f.abuse[1]}`)
end)

t.test("an unknown opcode is refused", function()
	local f = fixture(true)
	local payload = buffer.create(1)
	buffer.writeu8(payload, 0, 200)

	f.reliable.OnServerEvent:fire({ Name = "attacker" }, payload)

	t.eq(#f.abuse, 1)
	t.ok(string.find(f.abuse[1], "unknown opcode 200", 1, true), `unexpected reason: {f.abuse[1]}`)
end)

t.suite("Transport — flush")

t.test("a departed player's batch is dropped rather than fired at", function()
	-- A request handler that yielded across the disconnect, or a stale
	-- `to(player)`, can queue bytes for somebody who has already left. Firing
	-- at them throws, and the throw would abort the whole flush loop — every
	-- other player's batch delayed by a frame, once per stale reference.
	local f = fixture(true)
	local gone = { Name = "gone", Parent = nil }

	local b, offset, stream = f.Transport.reserve(f.endpoint, gone, true, 4)
	buffer.writeu32(b, offset, 7)
	Stream.finish(stream, 4)

	f.Transport.flush(f.endpoint)

	t.eq(#f.reliable.sent, 0, "nothing should be fired at a departed player")
	t.eq(f.endpoint.reliableStreams[gone], nil, "and their stream should be dropped")
end)

t.test("a present player's batch is fired", function()
	local f = fixture(true)
	local here = { Name = "here", Parent = { Name = "Players" } }

	local b, offset, stream = f.Transport.reserve(f.endpoint, here, true, 4)
	buffer.writeu32(b, offset, 7)
	Stream.finish(stream, 4)

	f.Transport.flush(f.endpoint)

	t.eq(#f.reliable.sent, 1, "a live player should be sent their batch")
	t.eq(f.reliable.sent[1].player, here)
	t.eq(buffer.len(f.reliable.sent[1].payload), 4, "and it should be exactly the bytes written")
end)

t.test("one departed player does not stall the rest of the flush", function()
	-- The regression this guards: the flush loop aborted on the first throw,
	-- so a single stale reference delayed everybody else by a frame. Stream
	-- iteration order is unspecified, so the assertion that has to hold every
	-- time is that the flush completes at all.
	local f = fixture(true)
	local gone = { Name = "gone", Parent = nil }
	local here = { Name = "here", Parent = { Name = "Players" } }

	for _, player in { gone, here } do
		local b, offset, stream = f.Transport.reserve(f.endpoint, player, true, 4)
		buffer.writeu32(b, offset, 1)
		Stream.finish(stream, 4)
	end

	local ok, err = pcall(f.Transport.flush, f.endpoint)

	t.ok(ok, `the flush should survive a departed player: {tostring(err)}`)
	t.eq(#f.reliable.sent, 1, "the live player should still have been sent to")
	t.eq(f.reliable.sent[1].player, here)
end)

t.test("a leaver's pending bytes are dropped on PlayerRemoving", function()
	local f = fixture(true)
	local leaver = { Name = "leaver", Parent = { Name = "Players" } }

	local b, offset, stream = f.Transport.reserve(f.endpoint, leaver, true, 4)
	buffer.writeu32(b, offset, 1)
	Stream.finish(stream, 4)

	f.players.PlayerRemoving:fire(leaver)
	f.Transport.flush(f.endpoint)

	t.eq(#f.reliable.sent, 0, "the queued bytes should be gone")
end)

return true
