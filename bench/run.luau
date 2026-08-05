--!strict
--[[
	Headless codec benchmark.

	    lune run bench/run

	What this measures: CPU cost of encoding and decoding, and bytes on the
	wire, for the generated codecs. The survey that motivated BTYN found that
	bandwidth between buffer-based libraries differs by under 3% while CPU
	differs by a lot — so CPU is the number worth watching, and it is the one
	thing measurable without the engine.

	What this does NOT measure, and cannot:

	  * real bandwidth in a running game, including engine framing overhead
	  * throttling behaviour, latency, or packet loss
	  * a comparison against Blink, Zap or ByteNet — that needs those libraries
	    installed and a real place to run them in

	For any of the above use Studio's MicroProfiler network view with a
	realistic player count. Do not quote these numbers as a library comparison.

	Payloads vary every iteration on purpose. Benchmarking serialisation with
	constant data is how a well-known result once measured a library "sending
	almost nothing" — its delta scheme was XORing identical frames to zero.
]]

local Analyze = require("../cli/Analyze")
local Module = require("../cli/emit/Module")
local Parser = require("../cli/Parser")
local roblox = require("../tests/roblox")

local CONFIG = 'config { server = "s.luau" client = "c.luau" }\n'

local ITERATIONS = 200000

local function build(source: string)
	local file, reporter = Parser.parseSource("bench.btyn", CONFIG .. source)
	local schema = Analyze.run(file, reporter)
	local code = Module.emitCodecModule(schema, { writeChecks = true, readChecks = true })

	-- Same stand-ins the tests use, so Vector3 and friends resolve headlessly.
	local chunk, err = loadstring(roblox.source .. code, "generated")
	if not chunk then
		error(`generated code does not compile: {err}`)
	end
	return (chunk :: any)(), schema
end

local function format(value: number): string
	if value >= 1e6 then
		return string.format("%.1fM", value / 1e6)
	elseif value >= 1e3 then
		return string.format("%.0fk", value / 1e3)
	end
	return string.format("%.0f", value)
end

--[[
	Times encode and decode over `ITERATIONS` distinct payloads.

	`make(i)` must produce a different value for each i, so the run cannot be
	flattered by branch prediction on constant data.
]]
local function measure(label: string, source: string, packet: string, make: (number) -> any)
	local codecs = build(source)
	local capacity = math.max(codecs.maxSize[packet], 8)
	local b = buffer.create(capacity)
	local refs: { any } = {}

	-- Warm up so the first-call cost of the chunk is not in the sample.
	for index = 1, 1000 do
		local written = codecs.write[packet](b, 0, make(index), refs)
		codecs.read[packet](b, 0, written, refs)
	end

	local bytes = 0

	local writeStart = os.clock()
	for index = 1, ITERATIONS do
		bytes = codecs.write[packet](b, 0, make(index), refs)
	end
	local writeTime = os.clock() - writeStart

	-- Decode the last payload written, repeatedly. Re-encoding inside the read
	-- loop would put encode cost in the decode number.
	local readStart = os.clock()
	for _ = 1, ITERATIONS do
		codecs.read[packet](b, 0, bytes, refs)
	end
	local readTime = os.clock() - readStart

	print(
		string.format(
			"  %-22s %6d B   encode %8s/s   decode %8s/s",
			label,
			bytes,
			format(ITERATIONS / writeTime),
			format(ITERATIONS / readTime)
		)
	)
end

print(`\nBTYN codec benchmark — {format(ITERATIONS)} iterations, payload varies each pass\n`)

measure("fixed, 3 fields", "event A from client { target: entity, combo: u8, angle: u16 }", "A", function(i)
	return { target = i % 4294967295, combo = i % 256, angle = i % 65536 }
end)

do
	-- The headline case for compiled schemas: 32 flags become one u32 store
	-- rather than 32 byte writes.
	local fields = {}
	local keys = table.create(32)
	local masks = table.create(32)
	for index = 1, 32 do
		keys[index] = `f{index}`
		masks[index] = 2 ^ (index - 1)
		table.insert(fields, `{keys[index]}: bool,`)
	end

	-- Keys are precomputed and one table is reused, mutating values in place.
	-- Building a fresh 32-key table per iteration would cost far more than the
	-- codec being measured and would drown the result.
	local value = {}
	for index = 1, 32 do
		value[keys[index]] = false
	end

	measure("32 booleans", "event B from client { " .. table.concat(fields, " ") .. " }", "B", function(i)
		for index = 1, 32 do
			value[keys[index]] = bit32.btest(i, masks[index])
		end
		return value
	end)
end

measure("quantised vec3 + unit", "event C from client { at: vec3, dir: unit }", "C", function(i)
	local scale = (i % 1000) / 1000
	return {
		at = { X = i % 500, Y = scale * 100, Z = -(i % 250) },
		dir = { X = scale, Y = 1 - scale, Z = 0 },
	}
end)

measure("dynamic string", "event D from client { id: u32, name: string(64) }", "D", function(i)
	return { id = i, name = string.rep("x", 1 + i % 40) }
end)

measure("array of 16 u16", "event E from client { ids: [u16; 64] }", "E", function(i)
	local ids = table.create(16)
	for index = 1, 16 do
		ids[index] = (i + index) % 65536
	end
	return { ids = ids }
end)

measure("struct + enum", [[
	struct Inner { x: i16, y: i16, flag: bool }
	enum Kind { One, Two, Three }
	event F from client { inner: Inner, kind: Kind, n: u8 }
]], "F", function(i)
	return {
		inner = { x = i % 32767, y = -(i % 32767), flag = i % 2 == 0 },
		kind = ({ "One", "Two", "Three" })[(i % 3) + 1],
		n = i % 256,
	}
end)

print("\n  Bytes shown are actual wire size for the last payload encoded.")
print("  The 32-boolean row is dominated by reading 32 table fields, which any")
print("  caller pays regardless; the interesting number there is the 4 bytes.")
print("  These are CPU and size figures only — see the header of this file.\n")
