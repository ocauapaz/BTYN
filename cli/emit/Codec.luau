--!strict
--[[
	Emits the read and write bodies for a packet.

	Two shapes come out of here:

	  Fixed layout — every field sits at a constant offset, so the generated
	  code is a straight line of `buffer.writeu8(b, o + 4, v.combo)` with no
	  cursor variable and no per-field arithmetic. This is the whole point of
	  compiling a schema instead of walking one at runtime.

	  Cursor layout — used only when a string, array or dynamic optional makes
	  the size vary. Fields before the first dynamic one still get constant
	  offsets; only the tail pays for a cursor.

	Booleans never take a byte of their own. They are packed into a bitfield at
	the front of the packet and written with one store per 32 flags.

	Reads validate. Writes validate only when `write_checks` is on (default), so
	a shipped game can drop the checks it already proved in development while
	the receiving side — the actual trust boundary — always keeps them.
]]

local Resolve = require("../Resolve")
local Writer = require("./Writer")

type Resolved = Resolve.Resolved
type ResolvedField = Resolve.ResolvedField
type Impl = Writer.Impl

local Codec = {}

export type Options = {
	-- Emit range/capacity checks on the write side.
	writeChecks: boolean,
	-- Emit validation on the read side. Always true for anything crossing the
	-- trust boundary; exposed only so tests can inspect both shapes.
	readChecks: boolean,
}

local PI = "3.1415926535897932"

-- Shortest vector still treated as a direction. Below this the normalisation
-- a `unit` read performs would divide by ~zero and hand back NaN.
local MIN_DIRECTION = "1e-6"

-- The ref index is a u16, so a batch cannot address more than this many
-- Instances.
local MAX_REFS = 65535

--[[
	Numeric primitives that map straight onto a buffer accessor.
]]
local DIRECT: { [string]: string } = {
	u8 = "u8",
	u16 = "u16",
	u32 = "u32",
	i8 = "i8",
	i16 = "i16",
	i32 = "i32",
	f32 = "f32",
	f64 = "f64",
	entity = "u32",
}

local FLOATS: { [string]: boolean } = { f32 = true, f64 = true }

--[[
	Bit masks for the packed boolean field, grouped into stores of at most 32
	bits. Returns a list of { byteOffset, byteWidth, firstBit, bitCount }.
]]
function Codec.bitChunks(bitfieldBytes: number): { { offset: number, width: number, firstBit: number } }
	local chunks = {}
	local offset = 0
	local remaining = bitfieldBytes

	while remaining > 0 do
		local width = if remaining >= 4 then 4 elseif remaining >= 2 then 2 else 1
		table.insert(chunks, { offset = offset, width = width, firstBit = offset * 8 })
		offset += width
		remaining -= width
	end

	return chunks
end

local function accessor(width: number): string
	if width == 4 then
		return "u32"
	elseif width == 2 then
		return "u16"
	end
	return "u8"
end

--[[
	The reject path. A malformed packet aborts the whole batch: the runtime
	catches this, drops what is left and reports the sender.
]]
local function reject(w: Impl, reason: string)
	w:line(`error("btyn: {reason}", 0)`)
end

--[[
	Expression that is true when `value` is NaN or infinite.

	Both poison a physics or economy calculation the same way, and both ride
	inside an otherwise well-formed packet. Every float crossing the trust
	boundary is tested with this — including the components of `vec3` and
	`cframe`, which are floats wearing a different name and were the one hole
	in this net.
]]
local function notFinite(value: string): string
	return `{value} ~= {value} or {value} == math.huge or {value} == -math.huge`
end

--[[
	Emits validation for a value that has just been read.
]]
local function validateRead(w: Impl, ty: Resolved, value: string, label: string, options: Options)
	if not options.readChecks then
		return
	end

	local name = ty.name

	if name and FLOATS[name] then
		w:push(`if {notFinite(value)} then`)
		reject(w, `{label} is not a finite number`)
		w:pop("end")
	end

	if ty.min ~= nil then
		w:push(`if {value} < {ty.min} or {value} > {ty.max} then`)
		reject(w, `{label} out of range`)
		w:pop("end")
	end
end

local function validateWrite(w: Impl, ty: Resolved, value: string, label: string, options: Options)
	if not options.writeChecks then
		return
	end

	if ty.min ~= nil then
		w:push(`if {value} < {ty.min} or {value} > {ty.max} then`)
		w:line(`error("btyn: {label} must be between {ty.min} and {ty.max}, got " .. tostring({value}), 0)`)
		w:pop("end")
	end
end

--[[
	Writes one value of a fixed-size type at a known offset.
]]
local function writeFixed(w: Impl, ty: Resolved, value: string, offset: string, label: string, options: Options)
	local name = ty.name

	if ty.kind == "prim" and name and DIRECT[name] then
		validateWrite(w, ty, value, label, options)
		w:line(`buffer.write{DIRECT[name]}(b, {offset}, {value})`)
		return
	end

	if ty.kind == "prim" and name == "fixed" then
		local args = ty.args :: { number }
		local low, high, bytes = args[1], args[2], args[3]
		local steps = 2 ^ (bytes * 8) - 1
		local scale = steps / (high - low)
		w:line(
			`buffer.write{accessor(bytes)}(b, {offset}, math.round((math.clamp({value}, {low}, {high}) - {low}) * {scale}))`
		)
		return
	end

	if ty.kind == "prim" and name == "vec3" then
		w:line(`buffer.writef32(b, {offset}, {value}.X)`)
		w:line(`buffer.writef32(b, {Writer.offset(offset, 4)}, {value}.Y)`)
		w:line(`buffer.writef32(b, {Writer.offset(offset, 8)}, {value}.Z)`)
		return
	end

	if ty.kind == "prim" and name == "unit" then
		-- Each component is already in [-1, 1]; i16 gives ~0.00003 resolution,
		-- far finer than anything a player can perceive in aim or facing.
		for index, axis in { "X", "Y", "Z" } do
			w:line(
				`buffer.writei16(b, {Writer.offset(offset, (index - 1) * 2)}, math.round(math.clamp({value}.{axis}, -1, 1) * 32767))`
			)
		end
		return
	end

	if ty.kind == "prim" and name == "angle" then
		-- Biased by pi before wrapping so the decoded value lands back in
		-- [-pi, pi] rather than [0, 2pi). Without the bias a caller sending
		-- -0.25 gets 6.03 back: the same direction, but not the same number,
		-- which breaks any comparison or interpolation done on the result.
		w:line(
			`buffer.writeu16(b, {offset}, math.round((({value} + {PI}) % ({PI} * 2)) / ({PI} * 2) * 65535))`
		)
		return
	end

	if ty.kind == "prim" and name == "color3" then
		w:line(`buffer.writeu8(b, {offset}, math.round(math.clamp({value}.R, 0, 1) * 255))`)
		w:line(`buffer.writeu8(b, {Writer.offset(offset, 1)}, math.round(math.clamp({value}.G, 0, 1) * 255))`)
		w:line(`buffer.writeu8(b, {Writer.offset(offset, 2)}, math.round(math.clamp({value}.B, 0, 1) * 255))`)
		return
	end

	if ty.kind == "prim" and name == "cframe" then
		w:line(`buffer.writef32(b, {offset}, {value}.X)`)
		w:line(`buffer.writef32(b, {Writer.offset(offset, 4)}, {value}.Y)`)
		w:line(`buffer.writef32(b, {Writer.offset(offset, 8)}, {value}.Z)`)
		w:line(`local rx, ry, rz = {value}:ToEulerAnglesXYZ()`)
		for index, axis in { "rx", "ry", "rz" } do
			w:line(
				`buffer.writei16(b, {Writer.offset(offset, 12 + (index - 1) * 2)}, math.round(math.clamp({axis} / {PI}, -1, 1) * 32767))`
			)
		end
		return
	end

	if ty.kind == "instance" then
		if options.writeChecks then
			w:push(`if #refs >= {MAX_REFS} then`)
			w:line(`error("btyn: more than {MAX_REFS} Instance references in one batch", 0)`)
			w:pop("end")
		end
		w:line(`refs[#refs + 1] = {value}`)
		w:line(`buffer.writeu16(b, {offset}, #refs)`)
		return
	end

	if ty.kind == "enum" then
		local variants = ty.variants :: { string }
		w:line(`local index = ENUM_{ty.name}[{value}]`)
		if options.writeChecks then
			w:push("if index == nil then")
			w:line(`error("btyn: {label} is not a valid {ty.name}, got " .. tostring({value}), 0)`)
			w:pop("end")
		end
		w:line(`buffer.write{if #variants <= 256 then "u8" else "u16"}(b, {offset}, index)`)
		return
	end

	if ty.kind == "struct" then
		w:line(`write{ty.name}(b, {offset}, {value}, refs)`)
		return
	end

	if ty.kind == "optional" then
		-- Presence lives in the bitfield; the payload is always written so the
		-- packet keeps its constant offsets. Absent writes zero rather than
		-- leaving whatever the reused scratch buffer held.
		local inner = ty.of :: Resolved
		w:push(`if {value} ~= nil then`)
		writeFixed(w, inner, value, offset, label, options)
		w:pop("else")
		w:push()
		w:line(`buffer.fill(b, {offset}, 0, {inner.size})`)
		w:pop("end")
		return
	end

	if ty.kind == "bool" then
		error("bool is carried in the bitfield and must not reach writeFixed")
	end

	error(`unhandled fixed type '{tostring(name)}' (kind {ty.kind})`)
end

--[[
	Reads one value of a fixed-size type. Returns an expression when the type
	maps to a single accessor, otherwise emits statements into `w` and returns
	the name of the local holding the result.
]]
local function readFixed(w: Impl, ty: Resolved, offset: string, label: string, options: Options, temp: string): string
	local name = ty.name

	if ty.kind == "prim" and name and DIRECT[name] then
		local expr = `buffer.read{DIRECT[name]}(b, {offset})`
		if not options.readChecks or (ty.min == nil and not FLOATS[name]) then
			return expr
		end
		w:line(`local {temp} = {expr}`)
		validateRead(w, ty, temp, label, options)
		return temp
	end

	if ty.kind == "prim" and name == "fixed" then
		local args = ty.args :: { number }
		local low, high, bytes = args[1], args[2], args[3]
		local steps = 2 ^ (bytes * 8) - 1
		return `(buffer.read{accessor(bytes)}(b, {offset}) * {(high - low) / steps} + {low})`
	end

	if ty.kind == "prim" and name == "vec3" then
		if not options.readChecks then
			return `Vector3.new(buffer.readf32(b, {offset}), buffer.readf32(b, {Writer.offset(offset, 4)}), buffer.readf32(b, {Writer.offset(offset, 8)}))`
		end

		local x, y, z = `{temp}X`, `{temp}Y`, `{temp}Z`
		w:line(`local {x} = buffer.readf32(b, {offset})`)
		w:line(`local {y} = buffer.readf32(b, {Writer.offset(offset, 4)})`)
		w:line(`local {z} = buffer.readf32(b, {Writer.offset(offset, 8)})`)
		w:push(`if {notFinite(x)} or {notFinite(y)} or {notFinite(z)} then`)
		reject(w, `{label} is not a finite vector`)
		w:pop("end")
		w:line(`local {temp} = Vector3.new({x}, {y}, {z})`)
		return temp
	end

	if ty.kind == "prim" and name == "unit" then
		-- Each component decodes into [-1.00003, 1], so three at full scale
		-- make a vector of magnitude 1.73 — the raw decode is not a unit
		-- vector at all. A caller trusting the name for a hitscan direction
		-- would get 73% more reach than it asked for, which is a reach hack
		-- handed out by the codec. Normalising here makes the type honest;
		-- the sender pays nothing, since only the receiver runs this.
		local x, y, z = `{temp}X`, `{temp}Y`, `{temp}Z`
		local magnitude = `{temp}Mag`

		w:line(`local {x} = buffer.readi16(b, {offset}) / 32767`)
		w:line(`local {y} = buffer.readi16(b, {Writer.offset(offset, 2)}) / 32767`)
		w:line(`local {z} = buffer.readi16(b, {Writer.offset(offset, 4)}) / 32767`)
		w:line(`local {magnitude} = math.sqrt({x} * {x} + {y} * {y} + {z} * {z})`)

		if options.readChecks then
			w:push(`if {magnitude} < {MIN_DIRECTION} then`)
			reject(w, `{label} is not a direction`)
			w:pop("end")
		end

		w:line(`local {temp} = Vector3.new({x} / {magnitude}, {y} / {magnitude}, {z} / {magnitude})`)
		return temp
	end

	if ty.kind == "prim" and name == "angle" then
		return `(buffer.readu16(b, {offset}) / 65535 * {PI} * 2 - {PI})`
	end

	if ty.kind == "prim" and name == "color3" then
		return `Color3.fromRGB(buffer.readu8(b, {offset}), buffer.readu8(b, {Writer.offset(offset, 1)}), buffer.readu8(b, {Writer.offset(offset, 2)}))`
	end

	if ty.kind == "prim" and name == "cframe" then
		-- Only the position is checked: the rotation arrives as three i16 and
		-- is bounded by its own width, so it cannot carry NaN or infinity.
		local x, y, z = `{temp}X`, `{temp}Y`, `{temp}Z`
		w:line(`local {x} = buffer.readf32(b, {offset})`)
		w:line(`local {y} = buffer.readf32(b, {Writer.offset(offset, 4)})`)
		w:line(`local {z} = buffer.readf32(b, {Writer.offset(offset, 8)})`)

		if options.readChecks then
			w:push(`if {notFinite(x)} or {notFinite(y)} or {notFinite(z)} then`)
			reject(w, `{label} position is not finite`)
			w:pop("end")
		end

		w:line(`local {temp} = CFrame.new({x}, {y}, {z}) * CFrame.fromEulerAnglesXYZ(`)
		w:push()
		w:line(
			`buffer.readi16(b, {Writer.offset(offset, 12)}) / 32767 * {PI}, buffer.readi16(b, {Writer.offset(offset, 14)}) / 32767 * {PI}, buffer.readi16(b, {Writer.offset(offset, 16)}) / 32767 * {PI}`
		)
		w:pop(")")
		return temp
	end

	if ty.kind == "instance" then
		w:line(`local {temp}Index = buffer.readu16(b, {offset})`)
		if options.readChecks then
			w:push(`if refs == nil or {temp}Index < 1 or {temp}Index > #refs then`)
			reject(w, `{label} references a missing instance`)
			w:pop("end")
		end
		w:line(`local {temp} = refs[{temp}Index]`)
		if options.readChecks then
			-- `refs` is the second argument of the remote call and is entirely
			-- sender-controlled. Nothing stops a client putting a string, a
			-- number or a table where the schema says Instance, and the
			-- generated type would still claim it is one.
			w:push(`if typeof({temp}) ~= "Instance" then`)
			reject(w, `{label} is not an Instance`)
			w:pop("end")
		end
		return temp
	end

	if ty.kind == "enum" then
		local variants = ty.variants :: { string }
		w:line(`local {temp}Index = buffer.read{if #variants <= 256 then "u8" else "u16"}(b, {offset})`)
		if options.readChecks then
			w:push(`if {temp}Index < 1 or {temp}Index > {#variants} then`)
			reject(w, `{label} is not a valid {ty.name}`)
			w:pop("end")
		end
		w:line(`local {temp} = ENUM_{ty.name}_VALUES[{temp}Index]`)
		return temp
	end

	if ty.kind == "struct" then
		w:line(`local {temp} = read{ty.name}(b, {offset}, limit, refs)`)
		return temp
	end

	error(`unhandled fixed type '{tostring(name)}' (kind {ty.kind})`)
end

Codec.writeFixed = writeFixed
Codec.readFixed = readFixed

--[[
	Writes a value at the running cursor `c`, advancing it. Used for the tail of
	a packet once something dynamic has appeared.
]]
local function writeDynamic(w: Impl, ty: Resolved, value: string, label: string, options: Options, depth: number)
	if ty.fixed then
		writeFixed(w, ty, value, "c", label, options)
		if ty.size > 0 then
			w:line(`c += {ty.size}`)
		end
		return
	end

	if ty.kind == "string" then
		local cap = ty.cap :: number
		local lenVar = `len{depth}`
		w:line(`local {lenVar} = #{value}`)
		if options.writeChecks then
			w:push(`if {lenVar} > {cap} then`)
			w:line(`error("btyn: {label} is " .. {lenVar} .. " bytes, over the {cap} byte cap", 0)`)
			w:pop("end")
		end
		w:line(`buffer.write{accessor(ty.lenBytes :: number)}(b, c, {lenVar})`)
		w:line(`c += {ty.lenBytes}`)
		w:line(`buffer.writestring(b, c, {value}, {lenVar})`)
		w:line(`c += {lenVar}`)
		return
	end

	if ty.kind == "array" then
		local cap = ty.cap :: number
		local countVar = `n{depth}`
		local itemVar = `item{depth}`
		w:line(`local {countVar} = #{value}`)
		if options.writeChecks then
			w:push(`if {countVar} > {cap} then`)
			w:line(`error("btyn: {label} has " .. {countVar} .. " items, over the {cap} item cap", 0)`)
			w:pop("end")
		end
		w:line(`buffer.write{accessor(ty.lenBytes :: number)}(b, c, {countVar})`)
		w:line(`c += {ty.lenBytes}`)
		w:push(`for i{depth} = 1, {countVar} do`)
		w:line(`local {itemVar} = {value}[i{depth}]`)
		writeDynamic(w, ty.of :: Resolved, itemVar, `{label}[]`, options, depth + 1)
		w:pop("end")
		return
	end

	if ty.kind == "optional" then
		local inner = ty.of :: Resolved
		w:push(`if {value} ~= nil then`)
		w:line("buffer.writeu8(b, c, 1)")
		w:line("c += 1")
		writeDynamic(w, inner, value, label, options, depth + 1)
		w:pop("else")
		w:push()
		w:line("buffer.writeu8(b, c, 0)")
		w:line("c += 1")
		w:pop("end")
		return
	end

	if ty.kind == "struct" then
		w:line(`c += write{ty.name}(b, c, {value}, refs)`)
		return
	end

	error(`unhandled dynamic type kind '{ty.kind}'`)
end

--[[
	Reads a value at the running cursor `c` into a fresh local, returning its
	name. Every variable-length read is bounds-checked first: `limit` is the end
	of the batch, and a hostile sender is exactly who would claim a length that
	runs past it.
]]
local function readDynamic(w: Impl, ty: Resolved, label: string, options: Options, depth: number): string
	local temp = `v{depth}`

	if ty.fixed then
		if options.readChecks then
			w:push(`if c + {ty.size} > limit then`)
			reject(w, `{label} runs past the end of the packet`)
			w:pop("end")
		end
		local expr = readFixed(w, ty, "c", label, options, `{temp}f`)
		w:line(`local {temp} = {expr}`)
		if ty.size > 0 then
			w:line(`c += {ty.size}`)
		end
		return temp
	end

	if ty.kind == "string" then
		local cap = ty.cap :: number
		local lenBytes = ty.lenBytes :: number
		if options.readChecks then
			w:push(`if c + {lenBytes} > limit then`)
			reject(w, `{label} length runs past the end of the packet`)
			w:pop("end")
		end
		w:line(`local len{depth} = buffer.read{accessor(lenBytes)}(b, c)`)
		w:line(`c += {lenBytes}`)
		if options.readChecks then
			w:push(`if len{depth} > {cap} or c + len{depth} > limit then`)
			reject(w, `{label} is longer than its {cap} byte cap`)
			w:pop("end")
		end
		w:line(`local {temp} = buffer.readstring(b, c, len{depth})`)
		w:line(`c += len{depth}`)
		return temp
	end

	if ty.kind == "array" then
		local cap = ty.cap :: number
		local lenBytes = ty.lenBytes :: number
		if options.readChecks then
			w:push(`if c + {lenBytes} > limit then`)
			reject(w, `{label} count runs past the end of the packet`)
			w:pop("end")
		end
		w:line(`local n{depth} = buffer.read{accessor(lenBytes)}(b, c)`)
		w:line(`c += {lenBytes}`)
		if options.readChecks then
			w:push(`if n{depth} > {cap} then`)
			reject(w, `{label} has more than its {cap} item cap`)
			w:pop("end")
		end
		w:line(`local {temp} = table.create(n{depth})`)
		w:push(`for i{depth} = 1, n{depth} do`)
		local itemVar = readDynamic(w, ty.of :: Resolved, `{label}[]`, options, depth + 1)
		w:line(`{temp}[i{depth}] = {itemVar}`)
		w:pop("end")
		return temp
	end

	if ty.kind == "optional" then
		if options.readChecks then
			w:push("if c + 1 > limit then")
			reject(w, `{label} presence flag runs past the end of the packet`)
			w:pop("end")
		end
		w:line(`local {temp}`)
		w:push("if buffer.readu8(b, c) == 1 then")
		w:line("c += 1")
		local innerVar = readDynamic(w, ty.of :: Resolved, label, options, depth + 1)
		w:line(`{temp} = {innerVar}`)
		w:pop("else")
		w:push()
		w:line("c += 1")
		w:pop("end")
		return temp
	end

	if ty.kind == "struct" then
		w:line(`local {temp}, {temp}Size = read{ty.name}(b, c, limit, refs)`)
		w:line(`c += {temp}Size`)
		return temp
	end

	error(`unhandled dynamic type kind '{ty.kind}'`)
end

--[[
	Emits the bitfield stores for a field list.
]]
local function writeBitfield(w: Impl, fields: { ResolvedField }, bitfieldBytes: number, offset: string)
	if bitfieldBytes == 0 then
		return
	end

	-- Flattened to one entry per bit before chunking. A `bool?` spends two bits
	-- — presence, then value — and those two can land either side of a chunk
	-- boundary, so each bit is placed by its own index rather than assumed to
	-- share the presence bit's chunk. Assuming otherwise wrote the value bit
	-- into the wrong accumulator, where it was silently truncated away.
	local placements: { { bit: number, condition: string } } = {}
	for _, field in fields do
		local bit = field.bit
		if bit == nil then
			continue
		end

		if field.type.kind == "optional" then
			table.insert(placements, { bit = bit, condition = `v.{field.name} ~= nil` })
			local inner = field.type.of :: Resolved
			if inner.kind == "bool" then
				table.insert(placements, { bit = bit + 1, condition = `v.{field.name} == true` })
			end
		else
			table.insert(placements, { bit = bit, condition = `v.{field.name}` })
		end
	end

	for chunkIndex, chunk in Codec.bitChunks(bitfieldBytes) do
		local lastBit = chunk.firstBit + chunk.width * 8 - 1
		local acc = `w{chunkIndex}`
		w:line(`local {acc} = 0`)

		for _, placement in placements do
			if placement.bit < chunk.firstBit or placement.bit > lastBit then
				continue
			end
			w:line(`if {placement.condition} then {acc} += {2 ^ (placement.bit - chunk.firstBit)} end`)
		end

		w:line(`buffer.write{accessor(chunk.width)}(b, {Writer.offset(offset, chunk.offset)}, {acc})`)
	end
end

local function readBitfield(w: Impl, bitfieldBytes: number, offset: string)
	if bitfieldBytes == 0 then
		return
	end
	for chunkIndex, chunk in Codec.bitChunks(bitfieldBytes) do
		w:line(`local w{chunkIndex} = buffer.read{accessor(chunk.width)}(b, {Writer.offset(offset, chunk.offset)})`)
	end
end

--[[
	Finds which bitfield chunk holds `bit`, for the read side.
]]
local function chunkFor(bitfieldBytes: number, bit: number): (number, number)
	for chunkIndex, chunk in Codec.bitChunks(bitfieldBytes) do
		if bit >= chunk.firstBit and bit < chunk.firstBit + chunk.width * 8 then
			return chunkIndex, 2 ^ (bit - chunk.firstBit)
		end
	end
	error("bit outside the bitfield")
end

export type Body = {
	fields: { ResolvedField },
	size: number,
	maxSize: number,
	fixed: boolean,
	bitfieldBytes: number,
	usesRefs: boolean,
}

--[[
	True when a field costs bits and no bytes — a `bool`, or a `bool?` which
	spends one bit on presence and one on the value. These never touch the
	payload loop in either direction.
]]
local function isBitfieldOnly(ty: Resolved): boolean
	return ty.fixed and ty.size == 0
end

--[[
	Emits the read for a bitfield-only field, returning an expression for it.
]]
local function readBitfieldOnly(w: Impl, field: ResolvedField, bitfieldBytes: number): string
	local bit = field.bit :: number
	local chunkIndex, mask = chunkFor(bitfieldBytes, bit)

	if field.type.kind == "bool" then
		return `bit32.btest(w{chunkIndex}, {mask})`
	end

	-- bool?: presence bit, then the value bit immediately after it.
	local valueChunk, valueMask = chunkFor(bitfieldBytes, bit + 1)
	local temp = `{field.name}Value`
	w:line(`local {temp} = nil`)
	w:push(`if bit32.btest(w{chunkIndex}, {mask}) then`)
	w:line(`{temp} = bit32.btest(w{valueChunk}, {valueMask})`)
	w:pop("end")
	return temp
end

--[[
	Emits the body of a write function.

	Every generated writer has the same signature regardless of layout:

	    (b: buffer, o: number, v: T, refs: { Instance }) -> number

	returning how many bytes it wrote. A fixed writer returns a constant, so
	uniformity costs nothing on the hot path and saves the runtime from having
	to know which shape it is calling.
]]
function Codec.emitWrite(w: Impl, body: Body, options: Options)
	writeBitfield(w, body.fields, body.bitfieldBytes, "o")

	if body.fixed then
		for _, field in body.fields do
			if isBitfieldOnly(field.type) then
				continue
			end
			local offset = field.offset :: number
			writeFixed(w, field.type, `v.{field.name}`, Writer.offset("o", offset), field.name, options)
		end
		w:line(`return {body.size}`)
		return
	end

	w:line(`local c = {Writer.offset("o", body.bitfieldBytes)}`)
	for _, field in body.fields do
		if isBitfieldOnly(field.type) then
			continue
		end
		writeDynamic(w, field.type, `v.{field.name}`, field.name, options, 1)
	end
	w:line("return c - o")
end

--[[
	Byte width of a channel's dirty mask. Analysis caps channels at 32 fields,
	which is what keeps this to a single store.
]]
function Codec.maskBytes(fieldCount: number): number
	if fieldCount <= 8 then
		return 1
	elseif fieldCount <= 16 then
		return 2
	end
	return 4
end

--[[
	Emits a channel delta writer.

	    (b: buffer, o: number, v: T, mask: number, refs: { Instance }) -> number

	Only the fields whose bit is set in `mask` are written, so a health tick
	costs a mask byte plus one value byte rather than the whole record. A
	keyframe is the same function called with every bit set — there is no
	separate format for it, which is one less thing to keep in sync.

	Booleans cost a whole byte here. In a fixed packet they share a bitfield,
	but a conditionally-present field cannot be given a fixed bit position, and
	inferring the value from "it changed" breaks for anyone who missed a
	keyframe.
]]
function Codec.emitWriteDelta(w: Impl, body: Body, options: Options)
	local maskBytes = Codec.maskBytes(#body.fields)

	w:line("local c = o")
	w:line(`buffer.write{accessor(maskBytes)}(b, c, mask)`)
	w:line(`c += {maskBytes}`)

	for index, field in body.fields do
		w:push(`if bit32.btest(mask, {2 ^ (index - 1)}) then`)

		if field.type.kind == "bool" then
			w:line(`buffer.writeu8(b, c, if v.{field.name} then 1 else 0)`)
			w:line("c += 1")
		else
			writeDynamic(w, field.type, `v.{field.name}`, field.name, options, 1)
		end

		w:pop("end")
	end

	w:line("return c - o")
end

--[[
	Emits a channel delta reader, returning only the fields that were present.

	    (b, o, limit, refs) -> ({ [string]: any }, number)
]]
function Codec.emitReadDelta(w: Impl, body: Body, options: Options)
	local maskBytes = Codec.maskBytes(#body.fields)

	if options.readChecks then
		w:push(`if o + {maskBytes} > limit then`)
		reject(w, "channel delta is missing its mask")
		w:pop("end")
	end

	w:line("local c = o")
	w:line(`local mask = buffer.read{accessor(maskBytes)}(b, c)`)
	w:line(`c += {maskBytes}`)
	w:line("local out = {}")

	for index, field in body.fields do
		w:push(`if bit32.btest(mask, {2 ^ (index - 1)}) then`)

		if field.type.kind == "bool" then
			if options.readChecks then
				w:push("if c + 1 > limit then")
				reject(w, `{field.name} runs past the end of the packet`)
				w:pop("end")
			end
			w:line(`out.{field.name} = buffer.readu8(b, c) == 1`)
			w:line("c += 1")
		else
			local temp = readDynamic(w, field.type, field.name, options, 1)
			w:line(`out.{field.name} = {temp}`)
		end

		w:pop("end")
	end

	w:line("return out, c - o")
end

--[[
	Emits the body of a read function.

	    (b: buffer, o: number, limit: number, refs: { Instance }?) -> (T, number)

	`limit` is the end of the received batch. Every variable-length read is
	checked against it before it happens — a sender claiming a 60000 byte string
	inside a 40 byte packet is precisely the case this exists for.
]]
function Codec.emitRead(w: Impl, body: Body, options: Options)
	readBitfield(w, body.bitfieldBytes, "o")

	if body.fixed then
		-- Simple fields become table-constructor entries so the common packet
		-- reads as one allocation and no intermediate locals.
		local entries: { string } = {}
		local pending = Writer.new()

		for _, field in body.fields do
			local ty = field.type

			if isBitfieldOnly(ty) then
				table.insert(entries, `{field.name} = {readBitfieldOnly(pending, field, body.bitfieldBytes)},`)
				continue
			end

			if ty.kind == "optional" then
				local inner = ty.of :: Resolved
				local chunkIndex, mask = chunkFor(body.bitfieldBytes, field.bit :: number)

				pending:line(`local {field.name}Value = nil`)
				pending:push(`if bit32.btest(w{chunkIndex}, {mask}) then`)
				local expr = readFixed(
					pending,
					inner,
					Writer.offset("o", field.offset :: number),
					field.name,
					options,
					`{field.name}Raw`
				)
				pending:line(`{field.name}Value = {expr}`)
				pending:pop("end")

				table.insert(entries, `{field.name} = {field.name}Value,`)
				continue
			end

			local offset = Writer.offset("o", field.offset :: number)
			local expr = readFixed(pending, ty, offset, field.name, options, `{field.name}Value`)
			table.insert(entries, `{field.name} = {expr},`)
		end

		w:concat(pending)
		w:push("return {")
		for _, entry in entries do
			w:line(entry)
		end
		w:pop("}, " .. body.size)
		return
	end

	w:line(`local c = {Writer.offset("o", body.bitfieldBytes)}`)
	local entries: { string } = {}

	for _, field in body.fields do
		local ty = field.type

		if isBitfieldOnly(ty) then
			table.insert(entries, `{field.name} = {readBitfieldOnly(w, field, body.bitfieldBytes)},`)
			continue
		end

		-- An optional of a fixed type keeps its presence bit in the bitfield
		-- even here, and its payload is always written, so the cursor advances
		-- whether or not the value was present.
		if ty.kind == "optional" and ty.fixed then
			local inner = ty.of :: Resolved
			local chunkIndex, mask = chunkFor(body.bitfieldBytes, field.bit :: number)

			if options.readChecks then
				w:push(`if c + {inner.size} > limit then`)
				reject(w, `{field.name} runs past the end of the packet`)
				w:pop("end")
			end

			w:line(`local {field.name}Field = nil`)
			w:push(`if bit32.btest(w{chunkIndex}, {mask}) then`)
			local expr = readFixed(w, inner, "c", field.name, options, `{field.name}Raw`)
			w:line(`{field.name}Field = {expr}`)
			w:pop("end")
			if inner.size > 0 then
				w:line(`c += {inner.size}`)
			end

			table.insert(entries, `{field.name} = {field.name}Field,`)
			continue
		end

		local temp = readDynamic(w, ty, field.name, options, 1)
		w:line(`local {field.name}Field = {temp}`)
		table.insert(entries, `{field.name} = {field.name}Field,`)
	end

	w:push("return {")
	for _, entry in entries do
		w:line(entry)
	end
	w:pop("}, c - o")
end

return Codec
