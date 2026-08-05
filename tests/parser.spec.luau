--!strict

local Diagnostics = require("../cli/Diagnostics")
local Parser = require("../cli/Parser")
local t = require("./harness")

local function parse(source: string)
	local file = Parser.parseSource("net.btyn", source)
	return file
end

t.suite("Parser")

t.test("parses a minimal event", function()
	local file = parse([[
		event Attack from client {
			target: entity,
			combo:  u8,
		}
	]])

	t.eq(#file.decls, 1)
	local decl = file.decls[1] :: any
	t.eq(decl.kind, "event")
	t.eq(decl.name, "Attack")
	t.eq(decl.from, "client")
	t.eq(decl.reliable, true)
	t.eq(#decl.fields, 2)
	t.eq(decl.fields[1].name, "target")
	t.eq(decl.fields[1].type.name, "entity")
	t.eq(decl.fields[2].type.name, "u8")
end)

t.test("unreliable sets reliable = false", function()
	local file = parse("unreliable Muzzle from server { at: vec3 }")
	local decl = file.decls[1] :: any
	t.eq(decl.kind, "event")
	t.eq(decl.reliable, false)
	t.eq(decl.from, "server")
end)

t.test("parses rate and priority modifiers", function()
	local file = parse([[
		event Attack from client rate 10 { combo: u8 }
		channel Health priority high { hp: u8 }
	]])

	t.eq((file.decls[1] :: any).rate, 10)
	t.eq((file.decls[2] :: any).priority, "high")
	t.eq((file.decls[2] :: any).kind, "channel")
end)

t.test("channel priority defaults to normal", function()
	local file = parse("channel Health { hp: u8 }")
	t.eq((file.decls[1] :: any).priority, "normal")
end)

t.test("parses a request with its reply", function()
	local file = parse([[
		request Buy from client rate 4 {
			item: u16,
		} -> {
			ok:      bool,
			balance: u32,
		}
	]])

	local decl = file.decls[1] :: any
	t.eq(decl.kind, "request")
	t.eq(decl.rate, 4)
	t.eq(#decl.fields, 1)
	t.eq(#decl.reply, 2)
	t.eq(decl.reply[2].name, "balance")
end)

t.test("parses type arguments: cap, range and fixed", function()
	local file = parse([[
		event E from client {
			name:   string(24),
			hp:     u8(0..100),
			offset: fixed(-1, 1, 2),
		}
	]])

	local fields = (file.decls[1] :: any).fields
	t.eq(fields[1].type.cap, 24)
	t.eq(fields[2].type.min, 0)
	t.eq(fields[2].type.max, 100)
	t.eq(fields[3].type.args[1], -1)
	t.eq(fields[3].type.args[2], 1)
	t.eq(fields[3].type.args[3], 2)
end)

t.test("parses arrays and optionals", function()
	local file = parse([[
		event E from client {
			items: [u16; 100],
			maybe: u8?,
			deep:  [u8; 4]?,
		}
	]])

	local fields = (file.decls[1] :: any).fields
	t.eq(fields[1].type.kind, "array")
	t.eq(fields[1].type.cap, 100)
	t.eq(fields[1].type.of.name, "u16")

	t.eq(fields[2].type.kind, "optional")
	t.eq(fields[2].type.of.name, "u8")

	t.eq(fields[3].type.kind, "optional")
	t.eq(fields[3].type.of.kind, "array")
end)

t.test("parses struct, enum and config", function()
	local file = parse([[
		config {
			server = "src/Server/Net.luau"
			budget = 40000
			typescript = true
		}

		struct Vec2i { x: i16, y: i16 }
		enum   Team  { Red, Blue, Spectator }
	]])

	local config = file.decls[1] :: any
	t.eq(config.kind, "config")
	t.eq(#config.entries, 3)
	t.eq(config.entries[1].value, "src/Server/Net.luau")
	t.eq(config.entries[2].value, 40000)
	t.eq(config.entries[3].value, true)

	t.eq((file.decls[2] :: any).kind, "struct")
	t.eq((file.decls[3] :: any).variants[3], "Spectator")
end)

t.test("a named type resolves to kind = named", function()
	local file = parse([[
		struct Vec2i { x: i16, y: i16 }
		event E from client { at: Vec2i }
	]])

	local field = (file.decls[2] :: any).fields[1]
	t.eq(field.type.kind, "named")
	t.eq(field.type.name, "Vec2i")
end)

t.test("comments are ignored", function()
	local file = parse([==[
		-- a line comment
		--[[ a block
		     comment ]]
		event E from client { a: u8 } -- trailing
	]==])
	t.eq(#file.decls, 1)
end)

t.test("modifier keywords are not reserved", function()
	-- `from`, `rate` and `event` are contextual, so they stay usable as fields.
	local file = parse("event E from client { rate: u8, from: u8, event: u8 }")
	local fields = (file.decls[1] :: any).fields
	t.eq(#fields, 3)
	t.eq(fields[1].name, "rate")
	t.eq(fields[3].name, "event")
end)

t.suite("Parser errors")

t.test("missing direction is reported with a fix", function()
	t.raises(function()
		parse("event Attack { combo: u8 }")
	end, "missing a direction")
end)

t.test("missing direction help shows the exact syntax", function()
	t.raises(function()
		parse("event Attack { combo: u8 }")
	end, "from client")
end)

t.test("request without a reply is reported", function()
	t.raises(function()
		parse("request Buy from client { item: u16 }")
	end, "missing its reply")
end)

t.test("channels reject a direction", function()
	t.raises(function()
		parse("channel Health from server { hp: u8 }")
	end, "channels do not take a direction")
end)

t.test("unknown declaration suggests the closest keyword", function()
	t.raises(function()
		parse("evnt Attack from client { a: u8 }")
	end, "did you mean 'event'?")
end)

t.test("unknown modifier suggests the closest one", function()
	t.raises(function()
		parse("event A from client rat 10 { a: u8 }")
	end, "did you mean 'rate'?")
end)

t.test("unknown direction is reported", function()
	t.raises(function()
		parse("event A from nobody { a: u8 }")
	end, "unknown direction 'nobody'")
end)

t.test("unterminated block comment is reported", function()
	t.raises(function()
		parse("--[[ never closed\nevent A from client { a: u8 }")
	end, "unterminated block comment")
end)

t.test("unterminated string is reported", function()
	t.raises(function()
		parse('config { server = "oops }')
	end, "unterminated string")
end)

t.test("missing colon after a field name is reported", function()
	t.raises(function()
		parse("event A from client { combo u8 }")
	end, "expected ':'")
end)

t.test("error output points at the right line and column", function()
	t.raises(function()
		parse("event A from client {\n\tcombo: u8,\n}\nevnt B from server { a: u8 }")
	end, "net.btyn:4:1")
end)

t.test("priority is rejected on events", function()
	t.raises(function()
		parse("event A from client priority high { a: u8 }")
	end, "not valid on events")
end)

return true
