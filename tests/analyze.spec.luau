--!strict

local Analyze = require("../cli/Analyze")
local Parser = require("../cli/Parser")
local t = require("./harness")

local CONFIG = 'config { server = "s.luau" client = "c.luau" }\n'

local function analyze(source: string): Analyze.Schema
	local file, reporter = Parser.parseSource("net.btyn", CONFIG .. source)
	return Analyze.run(file, reporter)
end

local function packet(schema: Analyze.Schema, name: string): Analyze.Packet
	for _, p in schema.packets do
		if p.name == name then
			return p
		end
	end
	error(`no packet named '{name}'`)
end

local function field(body: Analyze.Body, name: string)
	for _, f in body.fields do
		if f.name == name then
			return f
		end
	end
	error(`no field named '{name}'`)
end

t.suite("Analyze — config")

t.test("reads config values", function()
	local file, reporter = Parser.parseSource(
		"net.btyn",
		[[
		config {
			server = "src/Server/Net.luau"
			client = "src/Client/Net.luau"
			types  = "src/Shared/NetTypes.luau"
			budget = 12345
			unreliable_cap = 512
			manual = true
		}
		event A from client { a: u8 }
	]]
	)
	local schema = Analyze.run(file, reporter)

	t.eq(schema.config.server, "src/Server/Net.luau")
	t.eq(schema.config.types, "src/Shared/NetTypes.luau")
	t.eq(schema.config.budget, 12345)
	t.eq(schema.config.unreliableCap, 512)
	t.eq(schema.config.manual, true)
end)

t.test("defaults are conservative", function()
	local schema = analyze("event A from client { a: u8 }")
	-- Well under the community-reported ~1000 byte figure: undershooting costs
	-- bytes, overshooting costs silent packet loss.
	t.eq(schema.config.unreliableCap, 800)
	t.eq(schema.config.budget, 40000)
	t.eq(schema.config.manual, false)
end)

t.test("an unimplemented output flag fails rather than being ignored", function()
	t.raises(function()
		local file, reporter = Parser.parseSource(
			"net.btyn",
			'config { server = "s.luau" client = "c.luau" typescript = true }\nevent A from client { a: u8 }'
		)
		Analyze.run(file, reporter)
	end, "not implemented yet")
end)

t.test("unknown config key suggests the closest", function()
	t.raises(function()
		local file, reporter = Parser.parseSource(
			"net.btyn",
			'config { server = "s.luau" client = "c.luau" serverr = "x.luau" }\nevent A from client { a: u8 }'
		)
		Analyze.run(file, reporter)
	end, "did you mean 'server'?")
end)

t.test("missing output paths are reported", function()
	local file, reporter = Parser.parseSource("net.btyn", "event A from client { a: u8 }")
	t.raises(function()
		Analyze.run(file, reporter)
	end, "missing an output path")
end)

t.suite("Analyze — opcodes")

t.test("opcodes are assigned by sorted name", function()
	local schema = analyze([[
		event Zebra from client { a: u8 }
		event Alpha from client { a: u8 }
		event Mango from client { a: u8 }
	]])

	t.eq(packet(schema, "Alpha").opcode, 0)
	t.eq(packet(schema, "Mango").opcode, 1)
	t.eq(packet(schema, "Zebra").opcode, 2)
end)

t.test("requests take two opcodes, channels two", function()
	local schema = analyze([[
		event   A from client { a: u8 }
		request B from client { a: u8 } -> { b: u8 }
		channel C { a: u8 }
	]])

	t.eq(packet(schema, "A").opcode, 0)
	t.eq(packet(schema, "B").opcode, 1)
	t.eq(packet(schema, "B").replyOpcode, 2)
	t.eq(packet(schema, "C").opcode, 3)
	t.eq(packet(schema, "C").removeOpcode, 4)
end)

t.test("opcode width stays at one byte for small schemas", function()
	local schema = analyze("event A from client { a: u8 }")
	t.eq(schema.opcodeBytes, 1)
end)

t.suite("Analyze — layout")

t.test("fixed packet gets constant offsets", function()
	local schema = analyze([[
		event Attack from client {
			target: entity,
			combo:  u8,
			angle:  u16,
		}
	]])

	local body = packet(schema, "Attack").body
	t.eq(body.fixed, true)
	t.eq(body.bitfieldBytes, 0)
	t.eq(field(body, "target").offset, 0)
	t.eq(field(body, "combo").offset, 4)
	t.eq(field(body, "angle").offset, 5)
	t.eq(body.size, 7)
	t.eq(body.maxSize, 7)
end)

t.test("booleans pack into a leading bitfield", function()
	local schema = analyze([[
		event Flags from client {
			a: bool, b: bool, c: bool,
			hp: u8,
		}
	]])

	local body = packet(schema, "Flags").body
	-- Three bools cost one byte total, not three.
	t.eq(body.bitfieldBytes, 1)
	t.eq(field(body, "a").bit, 0)
	t.eq(field(body, "b").bit, 1)
	t.eq(field(body, "c").bit, 2)
	-- The payload starts after the bitfield.
	t.eq(field(body, "hp").offset, 1)
	t.eq(body.size, 2)
end)

t.test("32 booleans cost 4 bytes", function()
	local fields = {}
	for i = 1, 32 do
		table.insert(fields, `f{i}: bool,`)
	end
	local schema = analyze("event Flags from client { " .. table.concat(fields, " ") .. " }")

	local body = packet(schema, "Flags").body
	t.eq(body.bitfieldBytes, 4)
	t.eq(body.size, 4)
	t.eq(body.fixed, true)
end)

t.test("an optional of a fixed type stays fixed", function()
	-- One presence bit plus always-written payload keeps the constant-offset
	-- fast path, instead of dropping the packet onto the cursor path.
	local schema = analyze([[
		event E from client {
			maybe: u16?,
			sure:  u8,
		}
	]])

	local body = packet(schema, "E").body
	t.eq(body.fixed, true)
	t.eq(body.bitfieldBytes, 1)
	t.eq(field(body, "maybe").bit, 0)
	t.eq(field(body, "maybe").offset, 1)
	t.eq(field(body, "sure").offset, 3)
	t.eq(body.size, 4)
end)

t.test("a string makes the packet dynamic", function()
	local schema = analyze([[
		event E from client {
			id:   u8,
			name: string(24),
		}
	]])

	local body = packet(schema, "E").body
	t.eq(body.fixed, false)
	-- Worst case: 1 byte id + 1 length byte + 24 chars.
	t.eq(body.maxSize, 26)
end)

t.test("array capacity drives the worst case", function()
	local schema = analyze("event E from client { items: [u16; 100] }")
	local body = packet(schema, "E").body
	t.eq(body.fixed, false)
	t.eq(body.maxSize, 201)
end)

t.test("a long string uses a two-byte length prefix", function()
	local schema = analyze("event E from client { blob: string(1000) }")
	local body = packet(schema, "E").body
	t.eq(body.maxSize, 1002)
end)

t.test("structs are laid out recursively with their own bitfield", function()
	local schema = analyze([[
		struct Flags { a: bool, b: bool }
		event E from client { at: Flags, hp: u8 }
	]])

	local body = packet(schema, "E").body
	-- The struct's bools live inside the struct, so the packet has no bitfield.
	t.eq(body.bitfieldBytes, 0)
	t.eq(field(body, "at").offset, 0)
	t.eq(field(body, "hp").offset, 1)
end)

t.test("enum width follows variant count", function()
	local schema = analyze([[
		enum Team { Red, Blue, Spectator }
		event E from client { team: Team }
	]])
	t.eq(field(packet(schema, "E").body, "team").type.size, 1)
end)

t.suite("Analyze — validation")

t.test("unreliable over the cap is a compile error", function()
	t.raises(function()
		analyze("unreliable Big from server { blob: string(1000) }")
	end, "over the 800 byte cap")
end)

t.test("the oversize error names the actual worst case", function()
	t.raises(function()
		analyze("unreliable Big from server { blob: string(1000) }")
	end, "can reach 1003 bytes")
end)

t.test("a reliable event of the same size is fine", function()
	local schema = analyze("event Big from server { blob: string(1000) }")
	t.eq(packet(schema, "Big").reliable, true)
end)

t.test("raising unreliable_cap allows a bigger packet", function()
	local file, reporter = Parser.parseSource(
		"net.btyn",
		[[
		config { server = "s.luau" client = "c.luau" unreliable_cap = 2000 }
		unreliable Big from server { blob: string(1000) }
	]]
	)
	local schema = Analyze.run(file, reporter)
	t.eq(packet(schema, "Big").reliable, false)
end)

t.test("uncapped string is rejected with a reason", function()
	t.raises(function()
		analyze("event E from client { name: string }")
	end, "needs a maximum length")
end)

t.test("range outside the primitive is rejected", function()
	t.raises(function()
		analyze("event E from client { hp: u8(0..300) }")
	end, "does not fit in u8")
end)

t.test("inverted range is rejected", function()
	t.raises(function()
		analyze("event E from client { hp: u8(100..0) }")
	end, "range is inverted")
end)

t.test("unknown type suggests the closest", function()
	t.raises(function()
		analyze("event E from client { a: u9 }")
	end, "did you mean 'u8'?")
end)

t.test("duplicate packet names are rejected", function()
	t.raises(function()
		analyze([[
			event A from client { a: u8 }
			event A from server { b: u8 }
		]])
	end, "'A' is declared twice")
end)

t.test("duplicate field names are rejected", function()
	t.raises(function()
		analyze("event E from client { a: u8, a: u16 }")
	end, "two fields named 'a'")
end)

t.test("recursive structs are rejected", function()
	t.raises(function()
		analyze([[
			struct Node { child: Node }
			event E from client { n: Node }
		]])
	end, "contains itself")
end)

t.test("redefining a primitive is rejected", function()
	t.raises(function()
		analyze([[
			struct u8 { a: u16 }
			event E from client { a: u16 }
		]])
	end, "is a built-in type")
end)

t.test("an empty channel is rejected", function()
	t.raises(function()
		analyze("channel Health { }")
	end, "nothing to replicate")
end)

t.test("double optional is rejected", function()
	t.raises(function()
		analyze("event E from client { a: u8?? }")
	end, "double optional")
end)

t.test("fixed() validates its byte width", function()
	t.raises(function()
		analyze("event E from client { a: fixed(-1, 1, 3) }")
	end, "must be 1, 2 or 4")
end)

t.test("arrays of bool are rejected with a workaround", function()
	t.raises(function()
		analyze("event E from client { flags: [bool; 8] }")
	end, "arrays of `bool` are not supported")
end)

t.test("arrays of optional fixed types are rejected with a workaround", function()
	-- The presence bit of an optional fixed type lives in the container's
	-- bitfield, which an array element does not have. This used to crash the
	-- emitter with an internal error instead of diagnosing.
	t.raises(function()
		analyze("event E from client { slots: [u16?; 4] }")
	end, "arrays cannot hold optionals")

	t.raises(function()
		analyze("event E from client { flags: [bool?; 4] }")
	end, "arrays cannot hold optionals")
end)

t.test("a channel field cannot be an optional of a fixed type", function()
	-- A channel delta has no bitfield for the presence bit. Also a former
	-- internal crash.
	t.raises(function()
		analyze("channel Health { armor: u16? }")
	end, "optional of a fixed-size type")

	t.raises(function()
		analyze("channel Health { downed: bool? }")
	end, "optional of a fixed-size type")
end)

t.test("a channel field may be an optional of a dynamic type", function()
	-- Dynamic optionals spend a presence byte instead and stay expressible.
	local schema = analyze("channel Board { title: string(8)? }")
	t.eq(packet(schema, "Board").kind, "channel")
end)

t.test("an empty event is allowed", function()
	local schema = analyze("event Ping from client { }")
	t.eq(packet(schema, "Ping").body.size, 0)
	t.eq(packet(schema, "Ping").body.fixed, true)
end)

t.test("a rate of zero or less is rejected", function()
	-- The bucket would hand out its burst once and then refuse forever, which
	-- reads as "the event stopped working" rather than as a limit.
	t.raises(function()
		analyze("event E from client rate 0 { a: u8 }")
	end, "rate must be greater than zero")

	t.raises(function()
		analyze("event E from client rate -5 { a: u8 }")
	end, "rate must be greater than zero")
end)

t.test("a rate on a channel is rejected rather than ignored", function()
	t.raises(function()
		analyze("channel Health rate 10 { hp: u8 }")
	end, "channels do not take a rate")
end)

t.test("non-positive numeric config is rejected", function()
	local function withConfig(entry: string)
		local file, reporter = Parser.parseSource("net.btyn", `config \{ server = "s" client = "c" {entry} }`)
		return Analyze.run(file, reporter)
	end

	t.raises(function()
		withConfig("unreliable_cap = 0")
	end, "must be greater than zero")

	t.raises(function()
		withConfig("budget = -1")
	end, "must be greater than zero")

	t.raises(function()
		withConfig("request_timeout = 0")
	end, "must be greater than zero")
end)

return true
