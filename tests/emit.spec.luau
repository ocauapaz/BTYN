--!strict
--[[
	Checks the generated server and client modules.

	These cannot be *run* headlessly — they touch RemoteEvents — but they must
	at minimum compile, and the API surface each side exposes must match the
	direction declared in the schema.
]]

local Analyze = require("../cli/Analyze")
local Luau = require("../cli/emit/Luau")
local Parser = require("../cli/Parser")
local t = require("./harness")

local CONFIG = 'config { server = "s.luau" client = "c.luau" }\n'

local function generate(source: string): (string, string)
	local file, reporter = Parser.parseSource("net.btyn", CONFIG .. source)
	local schema = Analyze.run(file, reporter)
	return Luau.emitServer(schema), Luau.emitClient(schema)
end

--[[
	Generated code must parse. loadstring compiles without executing, so the
	Roblox globals it references do not need to exist here.
]]
local function assertCompiles(code: string, label: string)
	local chunk, err = loadstring(code, label)
	if not chunk then
		error(`{label} does not compile: {err}\n\n{code}`)
	end
end

local SAMPLE = [[
	struct Vec2i { x: i16, y: i16 }
	enum Team { Red, Blue, Spectator }

	event Attack from client rate 10 {
		target: entity,
		combo:  u8,
		crit:   bool,
	}

	event Award from server {
		amount: u32,
		team:   Team,
		note:   string(64),
		at:     Vec2i,
	}

	unreliable Muzzle from server {
		at:  vec3,
		dir: unit,
	}

	unreliable Aim from client {
		yaw:   angle,
		pitch: angle,
	}
]]

t.suite("Emit")

t.test("the generated server module compiles", function()
	local server = generate(SAMPLE)
	assertCompiles(server, "server")
end)

t.test("the generated client module compiles", function()
	local _, client = generate(SAMPLE)
	assertCompiles(client, "client")
end)

t.test("a schema using every supported type compiles", function()
	local server, client = generate([[
		struct Inner { a: u8, b: bool }
		enum Kind { One, Two }

		event Everything from server {
			nu8: u8, nu16: u16, nu32: u32,
			ni8: i8, ni16: i16, ni32: i32,
			nf32: f32, nf64: f64,
			flag: bool, maybeFlag: bool?,
			id: entity, who: Instance,
			pos: vec3, dir: unit, spin: angle, tint: color3, place: cframe,
			blend: fixed(-1, 1, 2),
			ranged: u8(0..100),
			label: string(32), maybeLabel: string(16)?,
			list: [u16; 20], structs: [Inner; 4],
			nested: Inner, kind: Kind, maybeKind: Kind?,
		}
	]])
	assertCompiles(server, "server")
	assertCompiles(client, "client")
end)

t.suite("Emit — API direction")

t.test("a client-to-server event gives the client fire and the server on", function()
	local server, client = generate("event Attack from client { combo: u8 }")

	t.ok(string.find(client, "fire = function", 1, true), "client should expose fire")
	t.ok(not string.find(client, "on = function", 1, true), "client should not expose on")

	t.ok(string.find(server, "on = function", 1, true), "server should expose on")
	t.ok(not string.find(server, "to = function", 1, true), "server should not expose to")
end)

t.test("a server-to-client event gives the server the broadcast forms", function()
	local server, client = generate("event Award from server { amount: u32 }")

	t.ok(string.find(server, "to = function", 1, true), "server should expose to")
	t.ok(string.find(server, "all = function", 1, true), "server should expose all")
	t.ok(string.find(server, "list = function", 1, true), "server should expose list")
	t.ok(string.find(server, "except = function", 1, true), "server should expose except")

	t.ok(string.find(client, "on = function", 1, true), "client should expose on")
	t.ok(not string.find(client, "fire = function", 1, true), "client should not expose fire")
end)

t.suite("Emit — codec filtering")

t.test("each side only carries the codecs it uses", function()
	local server, client = generate("event Attack from client { combo: u8 }")

	-- The client sends Attack, so it needs the writer and not the reader.
	t.ok(string.find(client, "function writeAttack", 1, true), "client needs the writer")
	t.ok(not string.find(client, "function readAttack", 1, true), "client should not carry the reader")

	t.ok(string.find(server, "function readAttack", 1, true), "server needs the reader")
	t.ok(not string.find(server, "function writeAttack", 1, true), "server should not carry the writer")
end)

t.suite("Emit — broadcast strategy")

t.test("a ref-free broadcast serialises once and fans out", function()
	local server = generate("event Award from server { amount: u32 }")
	t.ok(string.find(server, "stageAward", 1, true), "should stage the packet once")
	t.ok(string.find(server, "Transport.fanoutAll", 1, true), "should fan out by copying")
end)

t.test("a broadcast carrying an Instance serialises per recipient", function()
	-- Instance indices are batch-relative, so the spliced fast path would
	-- resolve them against the wrong batch.
	local server = generate("event Show from server { thing: Instance }")
	t.ok(not string.find(server, "stageShow", 1, true), "should not stage a ref-carrying packet")
	t.ok(string.find(server, "Players:GetPlayers()", 1, true), "should loop recipients instead")
end)

t.suite("Emit — config")

t.test("the runtime require path is configurable", function()
	local file, reporter = Parser.parseSource(
		"net.btyn",
		[[
		config {
			server = "s.luau"
			client = "c.luau"
			runtime = "game.ReplicatedStorage.Packages.BTYN"
		}
		event A from client { a: u8 }
	]]
	)
	local server = Luau.emitServer(Analyze.run(file, reporter))
	t.ok(string.find(server, "require(game.ReplicatedStorage.Packages.BTYN)", 1, true), "should use the configured path")
end)

t.test("write_checks = false drops the outgoing range checks", function()
	local file, reporter = Parser.parseSource(
		"net.btyn",
		[[
		config { server = "s.luau" client = "c.luau" write_checks = false }
		event A from client { hp: u8(0..100) }
	]]
	)
	local schema = Analyze.run(file, reporter)
	local client = Luau.emitClient(schema)

	t.ok(not string.find(client, "must be between", 1, true), "write checks should be gone")

	-- The receiving side is the trust boundary and always keeps its checks.
	local server = Luau.emitServer(schema)
	t.ok(string.find(server, "out of range", 1, true), "read checks must remain")
end)

return true
