--!strict
--[[
	Tests for requests and channels.

	The delta codecs are pure Luau and get the same round-trip treatment as the
	packet codecs. The transport halves are checked by generating both sides and
	asserting the emitted API matches the schema's direction.
]]

local Analyze = require("../cli/Analyze")
local Codec = require("../cli/emit/Codec")
local Luau = require("../cli/emit/Luau")
local Module = require("../cli/emit/Module")
local Parser = require("../cli/Parser")
local Writer = require("../cli/emit/Writer")
local roblox = require("./roblox")
local t = require("./harness")

local CONFIG = 'config { server = "s.luau" client = "c.luau" }\n'

local function compile(source: string): Analyze.Schema
	local file, reporter = Parser.parseSource("net.btyn", CONFIG .. source)
	return Analyze.run(file, reporter)
end

local function generate(source: string): (string, string)
	local schema = compile(source)
	return Luau.emitServer(schema), Luau.emitClient(schema)
end

local function assertCompiles(code: string, label: string)
	local chunk, err = loadstring(code, label)
	if not chunk then
		error(`{label} does not compile: {err}\n\n{code}`)
	end
end

--[[
	Builds a loadable module exposing just a channel's delta codecs.
]]
local function buildDelta(source: string)
	local schema = compile(source)
	local options: Codec.Options = { writeChecks = true, readChecks = true }
	local w = Writer.new()

	w:line("--!strict")
	Module.emitShared(w, schema, options)

	local packet = schema.packets[1]
	w:push(
		`local function writeDelta(b: buffer, o: number, v: any, mask: number, refs: \{ Instance }): number`
	)
	Codec.emitWriteDelta(w, packet.body, options)
	w:pop("end")

	w:push(`local function readDelta(b: buffer, o: number, limit: number, refs: \{ Instance }?): (any, number)`)
	Codec.emitReadDelta(w, packet.body, options)
	w:pop("end")

	w:line("return { write = writeDelta, read = readDelta }")

	local code = w:build()
	local chunk, err = loadstring(roblox.source .. code, "delta")
	if not chunk then
		error(`delta codec does not compile: {err}\n\n{code}`)
	end
	return (chunk :: any)(), packet
end

t.suite("Channel — delta codec")

t.test("a full mask round trips every field", function()
	local codec = buildDelta("channel Health { hp: u8, armor: u16, downed: bool }")
	local b = buffer.create(64)

	local state = { hp = 80, armor = 300, downed = true }
	local written = codec.write(b, 0, state, 7, {})
	local decoded = codec.read(b, 0, written, {})

	t.deepEq(decoded, state)
end)

t.test("a partial mask carries only the flagged fields", function()
	local codec = buildDelta("channel Health { hp: u8, armor: u16, downed: bool }")
	local b = buffer.create(64)

	-- Only bit 1 (hp) is set.
	local written = codec.write(b, 0, { hp = 42, armor = 300, downed = true }, 1, {})
	local decoded = codec.read(b, 0, written, {})

	t.deepEq(decoded, { hp = 42 })
	-- One mask byte plus one value byte, nothing else.
	t.eq(written, 2)
end)

t.test("an empty mask costs only the mask itself", function()
	local codec = buildDelta("channel Health { hp: u8, armor: u16 }")
	local b = buffer.create(64)

	local written = codec.write(b, 0, { hp = 1, armor = 2 }, 0, {})
	t.eq(written, 1)
	t.deepEq(codec.read(b, 0, written, {}), {})
end)

t.test("a delta of dynamic fields round trips", function()
	local codec = buildDelta("channel Board { title: string(32), scores: [u16; 8] }")
	local b = buffer.create(256)

	local state = { title = "round one", scores = { 10, 20, 30 } }
	local written = codec.write(b, 0, state, 3, {})
	t.deepEq(codec.read(b, 0, written, {}), state)
end)

--[[
	Mask width steps at 8 and 16 bits so it stays a single load or store.
]]
local function assertMaskWidth(fieldCount: number, expectedMaskBytes: number)
	local fields = {}
	for index = 1, fieldCount do
		table.insert(fields, `f{index}: u8,`)
	end
	local codec = buildDelta("channel Wide { " .. table.concat(fields, " ") .. " }")
	local b = buffer.create(256)

	local state = {}
	for index = 1, fieldCount do
		state[`f{index}`] = index
	end

	local written = codec.write(b, 0, state, 2 ^ fieldCount - 1, {})
	t.eq(written, expectedMaskBytes + fieldCount, `{fieldCount} fields should use a {expectedMaskBytes} byte mask`)
	t.deepEq(codec.read(b, 0, written, {}), state)
end

t.test("mask width follows field count", function()
	assertMaskWidth(8, 1)
	assertMaskWidth(12, 2)
	assertMaskWidth(16, 2)
	-- 20 flags need 20 bits, which does not fit two bytes.
	assertMaskWidth(20, 4)
	assertMaskWidth(32, 4)
end)

t.test("a truncated delta is rejected", function()
	local codec = buildDelta("channel Board { title: string(32) }")
	local b = buffer.create(64)
	local written = codec.write(b, 0, { title = "hello" }, 1, {})

	t.raises(function()
		codec.read(b, 0, written - 3, {})
	end, "btyn:")
end)

t.suite("Channel — emitted API")

t.test("the generated modules compile", function()
	local server, client = generate([[
		channel Health priority high { hp: u8, armor: u16, downed: bool }
		channel Score { points: u32 }
	]])
	assertCompiles(server, "server")
	assertCompiles(client, "client")
end)

t.test("the server gets the write side and the client the read side", function()
	local server, client = generate("channel Health { hp: u8 }")

	t.ok(string.find(server, "of = function", 1, true), "server should expose of")
	t.ok(string.find(server, "set = function", 1, true), "server should expose set")
	t.ok(string.find(server, "audience = function", 1, true), "server should expose audience")
	t.ok(string.find(server, "destroy = function", 1, true), "server should expose destroy")
	t.ok(string.find(server, "writeHealthDelta", 1, true), "server needs the delta writer")

	t.ok(string.find(client, "on = function", 1, true), "client should expose on")
	t.ok(string.find(client, "get = function", 1, true), "client should expose get")
	t.ok(string.find(client, "onRemove = function", 1, true), "client should expose onRemove")
	t.ok(string.find(client, "readHealthDelta", 1, true), "client needs the delta reader")
end)

t.test("channel priority reaches the generated runtime call", function()
	local server = generate("channel Health priority high { hp: u8 }")
	t.ok(string.find(server, 'priority = "high"', 1, true), "priority should be emitted")
end)

t.test("channels are flushed before the batch goes out", function()
	-- Two independent Heartbeat connections would have no defined order, so the
	-- deltas must be written from the flush hook.
	local server = generate("channel Health { hp: u8 }")
	t.ok(string.find(server, "endpoint.beforeFlush", 1, true), "should use the pre-flush hook")
	t.ok(string.find(server, "Channel.flushAll", 1, true), "should flush channel sets")
end)

t.test("a channel over 32 fields is rejected", function()
	local fields = {}
	for index = 1, 33 do
		table.insert(fields, `f{index}: u8,`)
	end
	t.raises(function()
		compile("channel Wide { " .. table.concat(fields, " ") .. " }")
	end, "over the limit of 32")
end)

t.suite("Request — emitted API")

t.test("the generated modules compile", function()
	local server, client = generate([[
		request Buy from client rate 4 { item: u16 } -> { ok: bool, balance: u32 }
		request Ping from server { nonce: u32 } -> { pong: u32 }
	]])
	assertCompiles(server, "server")
	assertCompiles(client, "client")
end)

t.test("the requester gets call and try, the responder gets on", function()
	local server, client = generate("request Buy from client { item: u16 } -> { ok: bool }")

	t.ok(string.find(client, "call = function", 1, true), "client should expose call")
	t.ok(string.find(client, "try = function", 1, true), "client should expose try")
	t.ok(not string.find(client, "on = function", 1, true), "client should not expose on")

	t.ok(string.find(server, "on = function", 1, true), "server should expose on")
	t.ok(not string.find(server, "call = function", 1, true), "server should not expose call")
end)

t.test("a server-initiated request takes a target player", function()
	local server = generate("request Ping from server { nonce: u32 } -> { pong: u32 }")
	t.ok(string.find(server, "call = function(player: Player, v: Ping)", 1, true), "should require a target")
end)

t.test("the responder answers on a spawned thread", function()
	-- A handler that yields on a datastore call must not stall the batch walk.
	local server = generate("request Buy from client { item: u16 } -> { ok: bool }")
	t.ok(string.find(server, "task.spawn", 1, true), "should spawn the responder")
end)

t.test("timed out requests are swept", function()
	local client = select(2, generate("request Buy from client { item: u16 } -> { ok: bool }"))
	t.ok(string.find(client, "Request.sweep", 1, true), "should sweep the registry")
end)

t.test("the request timeout is configurable", function()
	local file, reporter = Parser.parseSource(
		"net.btyn",
		[[
		config { server = "s.luau" client = "c.luau" request_timeout = 3 }
		request Buy from client { item: u16 } -> { ok: bool }
	]]
	)
	local client = Luau.emitClient(Analyze.run(file, reporter))
	t.ok(string.find(client, "Request.new(3)", 1, true), "should use the configured timeout")
end)

t.suite("Rate limiting")

t.test("a rate limited event gets a bucket on the receiving side", function()
	local server, client = generate("event Attack from client rate 10 { combo: u8 }")

	t.ok(string.find(server, "RateLimiter.new(10)", 1, true), "server should build the bucket")
	t.ok(string.find(server, "exceeded its rate limit", 1, true), "server should report abuse")

	-- The sender is not the trust boundary and pays nothing for this.
	t.ok(not string.find(client, "RateLimiter", 1, true), "client should carry no limiter")
end)

t.test("an unrated event has no limiter", function()
	local server = generate("event Attack from client { combo: u8 }")
	t.ok(not string.find(server, "RateLimiter", 1, true), "should not emit a limiter")
end)

return true
