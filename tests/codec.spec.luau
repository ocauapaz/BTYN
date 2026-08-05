--!strict
--[[
	Round-trip tests against the generated code itself.

	These compile a schema, load the emitted Luau, and check that
	`read(write(value)) == value` for randomly generated payloads. It is the one
	check that fails if anything in the offset maths, bit packing, quantisation
	or bounds checking is wrong.
]]

local Analyze = require("../cli/Analyze")
local Module = require("../cli/emit/Module")
local Parser = require("../cli/Parser")
local Resolve = require("../cli/Resolve")
local roblox = require("./roblox")
local t = require("./harness")

local CONFIG = 'config { server = "s.luau" client = "c.luau" }\n'

type Codecs = {
	write: { [string]: (buffer, number, any, { any }) -> number },
	read: { [string]: (buffer, number, number, { any }?) -> (any, number) },
	size: { [string]: number },
	maxSize: { [string]: number },
	fixed: { [string]: boolean },
}

--[[
	Compiles a schema and loads the generated codec module.
]]
local function build(source: string): (Codecs, Analyze.Schema, string)
	local file, reporter = Parser.parseSource("net.btyn", CONFIG .. source)
	local schema = Analyze.run(file, reporter)
	local code = Module.emitCodecModule(schema, { writeChecks = true, readChecks = true })

	local chunk, err = loadstring(roblox.source .. code, "generated")
	if not chunk then
		error(`generated code does not compile: {err}\n\n{code}`)
	end

	return (chunk :: any)(), schema, code
end

local function bodyOf(schema: Analyze.Schema, name: string): Analyze.Body
	for _, packet in schema.packets do
		if packet.name == name then
			return packet.body
		end
	end
	error(`no packet '{name}'`)
end

--[[
	Writes a value and reads it straight back.
]]
local function roundTrip(codecs: Codecs, name: string, value: any): any
	local capacity = math.max(codecs.maxSize[name], 1)
	local b = buffer.create(capacity)
	local refs: { any } = {}

	local written = codecs.write[name](b, 0, value, refs)
	local decoded = codecs.read[name](b, 0, written, refs)
	return decoded, written
end

-- Tolerances for the deliberately lossy types.
local TOLERANCE: { [string]: number } = {
	f32 = 1e-5,
	angle = 2 * math.pi / 65535 + 1e-9,
	unit = 1 / 32767 + 1e-9,
	color3 = 1 / 255 + 1e-9,
}

local function approx(actual: number, expected: number, tolerance: number, where: string)
	if math.abs(actual - expected) > tolerance then
		error(`{where}: expected ~{expected}, got {actual} (tolerance {tolerance})`, 2)
	end
end

--[[
	Compares a decoded value against the original, allowing for quantisation.
]]
local function compare(actual: any, expected: any, ty: Resolve.Resolved, where: string)
	if ty.kind == "optional" then
		if expected == nil then
			if actual ~= nil then
				error(`{where}: expected nil, got {tostring(actual)}`, 2)
			end
			return
		end
		compare(actual, expected, ty.of :: Resolve.Resolved, where)
		return
	end

	if ty.kind == "array" then
		t.eq(#actual, #expected, `{where}: length differs`)
		for index, item in expected do
			compare(actual[index], item, ty.of :: Resolve.Resolved, `{where}[{index}]`)
		end
		return
	end

	if ty.kind == "struct" then
		for _, field in ty.fields :: { Resolve.ResolvedField } do
			compare(actual[field.name], expected[field.name], field.type, `{where}.{field.name}`)
		end
		return
	end

	local name = ty.name

	if name == "vec3" then
		for _, axis in { "X", "Y", "Z" } do
			approx(actual[axis], expected[axis], TOLERANCE.f32 * math.max(1, math.abs(expected[axis])), `{where}.{axis}`)
		end
		return
	end

	if name == "unit" then
		for _, axis in { "X", "Y", "Z" } do
			approx(actual[axis], expected[axis], TOLERANCE.unit, `{where}.{axis}`)
		end
		return
	end

	if name == "color3" then
		for _, channel in { "R", "G", "B" } do
			approx(actual[channel], expected[channel], TOLERANCE.color3, `{where}.{channel}`)
		end
		return
	end

	if name == "cframe" then
		for _, axis in { "X", "Y", "Z" } do
			approx(actual[axis], expected[axis], TOLERANCE.f32 * math.max(1, math.abs(expected[axis])), `{where}.{axis}`)
		end
		for _, axis in { "rx", "ry", "rz" } do
			approx(actual[axis], expected[axis], math.pi / 32767 + 1e-9, `{where}.{axis}`)
		end
		return
	end

	if name == "angle" then
		approx(actual, expected, TOLERANCE.angle, where)
		return
	end

	if name == "f32" then
		approx(actual, expected, TOLERANCE.f32 * math.max(1, math.abs(expected)), where)
		return
	end

	if name == "fixed" then
		local args = ty.args :: { number }
		local step = (args[2] - args[1]) / (2 ^ (args[3] * 8) - 1)
		approx(actual, expected, step, where)
		return
	end

	if actual ~= expected then
		error(`{where}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

local function randomString(cap: number): string
	local length = math.random(0, math.min(cap, 40))
	local chars = table.create(length)
	for index = 1, length do
		chars[index] = string.char(math.random(97, 122))
	end
	return table.concat(chars)
end

--[[
	Generates a value valid for the given type.
]]
local function randomValue(ty: Resolve.Resolved): any
	if ty.kind == "bool" then
		return math.random() < 0.5
	end

	if ty.kind == "optional" then
		if math.random() < 0.4 then
			return nil
		end
		return randomValue(ty.of :: Resolve.Resolved)
	end

	if ty.kind == "string" then
		return randomString(ty.cap :: number)
	end

	if ty.kind == "array" then
		local count = math.random(0, math.min(ty.cap :: number, 8))
		local items = table.create(count)
		for index = 1, count do
			items[index] = randomValue(ty.of :: Resolve.Resolved)
		end
		return items
	end

	if ty.kind == "struct" then
		local value = {}
		for _, field in ty.fields :: { Resolve.ResolvedField } do
			value[field.name] = randomValue(field.type)
		end
		return value
	end

	if ty.kind == "enum" then
		local variants = ty.variants :: { string }
		return variants[math.random(1, #variants)]
	end

	local name = ty.name :: string

	if name == "vec3" then
		return roblox.Vector3(math.random(-500, 500) + 0.5, math.random(-500, 500), math.random(-500, 500))
	elseif name == "unit" then
		local x, y, z = math.random() - 0.5, math.random() - 0.5, math.random() - 0.5
		local length = math.sqrt(x * x + y * y + z * z)
		return roblox.Vector3(x / length, y / length, z / length)
	elseif name == "color3" then
		return roblox.Color3(math.random(0, 255) / 255, math.random(0, 255) / 255, math.random(0, 255) / 255)
	elseif name == "cframe" then
		return roblox.CFrame(
			math.random(-100, 100),
			math.random(-100, 100),
			math.random(-100, 100),
			(math.random() - 0.5) * math.pi,
			(math.random() - 0.5) * math.pi,
			(math.random() - 0.5) * math.pi
		)
	elseif name == "angle" then
		-- Spans negative values too. Generating only [0, 2pi) here is what let
		-- a sign bug in the angle codec survive the property tests.
		return (math.random() * 2 - 1) * math.pi
	elseif name == "fixed" then
		local args = ty.args :: { number }
		return args[1] + math.random() * (args[2] - args[1])
	end

	-- Respect a declared range, otherwise use the primitive's own limits.
	if ty.min ~= nil then
		if name == "f32" or name == "f64" then
			return ty.min + math.random() * ((ty.max :: number) - ty.min)
		end
		return math.random(ty.min, ty.max :: number)
	end

	if name == "f32" or name == "f64" then
		return math.random(-100000, 100000) + math.random()
	elseif name == "u8" then
		return math.random(0, 255)
	elseif name == "u16" then
		return math.random(0, 65535)
	elseif name == "u32" or name == "entity" then
		return math.random(0, 2 ^ 31 - 1)
	elseif name == "i8" then
		return math.random(-128, 127)
	elseif name == "i16" then
		return math.random(-32768, 32767)
	elseif name == "i32" then
		-- Split into two draws: a single call spanning the full i32 range
		-- exceeds what math.random accepts as an interval.
		return math.random(0, 2 ^ 30) * (if math.random() < 0.5 then -1 else 1)
	end

	error(`no generator for '{name}'`)
end

--[[
	Compiles the schema, then round-trips `iterations` random payloads through
	every packet in it.
]]
local function property(source: string, iterations: number?)
	local codecs, schema = build(source)

	for _, packet in schema.packets do
		local body = packet.body
		for _ = 1, iterations or 60 do
			local value = {}
			for _, field in body.fields do
				value[field.name] = randomValue(field.type)
			end

			local decoded = roundTrip(codecs, packet.name, value)
			for _, field in body.fields do
				compare(decoded[field.name], value[field.name], field.type, `{packet.name}.{field.name}`)
			end
		end
	end
end

t.suite("Codec — round trip")

t.test("integers survive a round trip", function()
	property([[
		event Ints from client {
			a: u8, b: u16, c: u32,
			d: i8, e: i16, f: i32,
			g: entity,
		}
	]])
end)

t.test("floats survive a round trip", function()
	property("event Floats from client { a: f32, b: f64 }")
end)

t.test("booleans survive a round trip", function()
	property("event Bools from client { a: bool, b: bool, c: bool, d: bool, hp: u8 }")
end)

t.test("a 32-bit bitfield survives a round trip", function()
	local fields = {}
	for index = 1, 32 do
		table.insert(fields, `f{index}: bool,`)
	end
	property("event Wide from client { " .. table.concat(fields, " ") .. " }")
end)

t.test("a bitfield that is not a whole word survives a round trip", function()
	-- 20 bools spans three bytes: a u16 store plus a u8 store.
	local fields = {}
	for index = 1, 20 do
		table.insert(fields, `f{index}: bool,`)
	end
	property("event Odd from client { " .. table.concat(fields, " ") .. " }")
end)

t.test("strings survive a round trip", function()
	property("event Text from client { id: u8, name: string(40), tag: string(300) }")
end)

t.test("arrays survive a round trip", function()
	property("event Items from client { ids: [u16; 50], names: [string(10); 5] }")
end)

t.test("optionals survive a round trip", function()
	property([[
		event Opt from client {
			maybeNum:    u16?,
			maybeFlag:   bool?,
			maybeText:   string(20)?,
			maybeList:   [u8; 4]?,
			definitely:  u8,
		}
	]])
end)

t.test("structs survive a round trip", function()
	property([[
		struct Inner { x: i16, y: i16, flag: bool }
		struct Outer { inner: Inner, label: string(16) }
		event Nested from client { outer: Outer, plain: Inner }
	]])
end)

t.test("enums survive a round trip", function()
	property([[
		enum Team { Red, Blue, Spectator }
		event Pick from client { team: Team, second: Team? }
	]])
end)

t.test("quantised types survive a round trip within tolerance", function()
	property([[
		event Quant from client {
			pos:   vec3,
			dir:   unit,
			yaw:   angle,
			tint:  color3,
			blend: fixed(-1, 1, 2),
			coarse: fixed(0, 100, 1),
		}
	]])
end)

t.test("cframe survives a round trip within tolerance", function()
	property("event Move from client { at: cframe }")
end)

t.test("a negative angle comes back negative", function()
	-- Regression: the first implementation encoded into [0, 2pi), so -0.25
	-- decoded as 6.03. The same direction, but not the same number, which
	-- breaks any comparison or interpolation done on the result.
	local codecs = build("event Aim from client { yaw: angle, pitch: angle }")
	local decoded = roundTrip(codecs, "Aim", { yaw = 0.5, pitch = -0.25 })

	approx(decoded.yaw, 0.5, TOLERANCE.angle, "yaw")
	approx(decoded.pitch, -0.25, TOLERANCE.angle, "pitch")
end)

t.test("angles at the wrap boundary round trip", function()
	local codecs = build("event Aim from client { yaw: angle, pitch: angle }")

	for _, value in { 0, math.pi - 0.001, -math.pi + 0.001, 1.5, -1.5 } do
		local decoded = roundTrip(codecs, "Aim", { yaw = value, pitch = -value })
		approx(decoded.yaw, value, TOLERANCE.angle, `yaw at {value}`)
	end
end)

t.test("ranged values survive a round trip", function()
	property("event Ranged from client { hp: u8(0..100), temp: i16(-50..50) }")
end)

t.test("an empty packet round trips to an empty table", function()
	local codecs = build("event Ping from client { }")
	local decoded, written = roundTrip(codecs, "Ping", {})
	t.eq(written, 0)
	t.deepEq(decoded, {})
end)

t.test("a mixed fixed and dynamic packet survives a round trip", function()
	property([[
		event Mixed from client {
			id:    u32,
			flag:  bool,
			name:  string(24),
			count: u16,
			tags:  [string(8); 4],
		}
	]])
end)

t.suite("Codec — wire size")

t.test("a fixed packet writes exactly its declared size", function()
	local codecs = build("event Attack from client { target: entity, combo: u8 }")
	local _, written = roundTrip(codecs, "Attack", { target = 7, combo = 3 })
	t.eq(written, 5)
end)

t.test("32 booleans cost 4 bytes on the wire", function()
	local fields, value = {}, {}
	for index = 1, 32 do
		table.insert(fields, `f{index}: bool,`)
		value[`f{index}`] = index % 2 == 0
	end
	local codecs = build("event Wide from client { " .. table.concat(fields, " ") .. " }")

	local _, written = roundTrip(codecs, "Wide", value)
	t.eq(written, 4)
end)

t.test("a dynamic packet only pays for what it carries", function()
	local codecs = build("event Text from client { name: string(255) }")
	local _, written = roundTrip(codecs, "Text", { name = "hi" })
	-- One length byte plus two characters, not the 255 byte worst case.
	t.eq(written, 3)
end)

t.test("an absent optional still costs its payload but no presence byte", function()
	local codecs = build("event Opt from client { maybe: u16?, sure: u8 }")
	local decoded, written = roundTrip(codecs, "Opt", { sure = 9 })
	-- One bitfield byte, two payload bytes, one byte for `sure`.
	t.eq(written, 4)
	t.eq(decoded.maybe, nil)
	t.eq(decoded.sure, 9)
end)

t.suite("Codec — validation")

t.test("a truncated dynamic packet is rejected", function()
	local codecs = build("event Text from client { name: string(255) }")
	local b = buffer.create(64)
	codecs.write.Text(b, 0, { name = "hello" }, {})

	-- Claim the packet is shorter than the length prefix promises.
	t.raises(function()
		codecs.read.Text(b, 0, 3, {})
	end, "btyn:")
end)

t.test("an oversized declared length is rejected", function()
	local codecs = build("event Text from client { name: string(20) }")
	local b = buffer.create(64)
	buffer.writeu8(b, 0, 200) -- longer than the cap allows

	t.raises(function()
		codecs.read.Text(b, 0, 64, {})
	end, "cap")
end)

t.test("an out-of-range value is rejected on read", function()
	local codecs = build("event Ranged from client { hp: u8(0..100) }")
	local b = buffer.create(8)
	buffer.writeu8(b, 0, 200)

	t.raises(function()
		codecs.read.Ranged(b, 0, 8, {})
	end, "out of range")
end)

t.test("an out-of-range value is rejected on write", function()
	local codecs = build("event Ranged from client { hp: u8(0..100) }")
	local b = buffer.create(8)

	t.raises(function()
		codecs.write.Ranged(b, 0, { hp = 200 }, {})
	end, "must be between 0 and 100")
end)

t.test("a NaN float is rejected on read", function()
	local codecs = build("event F from client { x: f32 }")
	local b = buffer.create(8)
	buffer.writef32(b, 0, 0 / 0)

	t.raises(function()
		codecs.read.F(b, 0, 8, {})
	end, "not a finite number")
end)

t.test("an infinite float is rejected on read", function()
	local codecs = build("event F from client { x: f64 }")
	local b = buffer.create(16)
	buffer.writef64(b, 0, math.huge)

	t.raises(function()
		codecs.read.F(b, 0, 16, {})
	end, "not a finite number")
end)

t.test("an over-cap array count is rejected", function()
	local codecs = build("event A from client { ids: [u8; 4] }")
	local b = buffer.create(64)
	buffer.writeu8(b, 0, 99)

	t.raises(function()
		codecs.read.A(b, 0, 64, {})
	end, "item cap")
end)

t.test("an over-cap string is rejected on write", function()
	local codecs = build("event Text from client { name: string(4) }")
	local b = buffer.create(64)

	t.raises(function()
		codecs.write.Text(b, 0, { name = "far too long" }, {})
	end, "over the 4 byte cap")
end)

t.test("an invalid enum index is rejected on read", function()
	local codecs = build([[
		enum Team { Red, Blue }
		event Pick from client { team: Team }
	]])
	local b = buffer.create(8)
	buffer.writeu8(b, 0, 77)

	t.raises(function()
		codecs.read.Pick(b, 0, 8, {})
	end, "not a valid Team")
end)

return true
