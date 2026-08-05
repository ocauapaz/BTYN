--!strict
--[[
	Resolves a written TypeRef into a sized, validated type.

	Sizing happens here because it drives three things that matter downstream:

	  * `fixed` decides whether the emitter can use constant offsets (no cursor
	    arithmetic at all) or has to fall back to a running cursor.
	  * `maxSize` lets the analyzer reject an unreliable packet that cannot fit
	    in the engine's payload cap — at compile time, instead of the engine
	    silently dropping it at runtime.
	  * `bits` collects boolean-ish fields into one packed bitfield per packet.

	One deliberate trick: an optional whose inner type is fixed-size stays
	fixed-size. It spends one presence bit in the bitfield and always writes its
	payload bytes (zeroed when absent, so nothing leaks from the reused scratch
	buffer). That keeps the constant-offset fast path for `u8?`, which would
	otherwise force the whole packet onto the slow cursor path.
]]

local Ast = require("./Ast")
local Diagnostics = require("./Diagnostics")

type Span = Diagnostics.Span
type ReporterImpl = Diagnostics.ReporterImpl

local Resolve = {}

export type Kind = "prim" | "bool" | "string" | "array" | "optional" | "struct" | "enum" | "instance"

export type Resolved = {
	kind: Kind,
	-- prim name (u8, f32, vec3, unit, ...) or the referenced struct/enum name
	name: string?,
	-- string(N) / [T; N]
	cap: number?,
	lenBytes: number?,
	-- u8(0..100)
	min: number?,
	max: number?,
	-- fixed(min, max, bytes)
	args: { number }?,
	-- array element / optional inner
	of: Resolved?,
	-- struct fields, already laid out
	fields: { ResolvedField }?,
	-- enum variants, in declaration order; the wire value is the index - 1
	variants: { string }?,
	-- exact size when `fixed`, otherwise the minimum
	size: number,
	maxSize: number,
	fixed: boolean,
	-- bitfield bits this type claims in its container
	bits: number,
	usesRefs: boolean,
	span: Span,
}

export type ResolvedField = {
	name: string,
	type: Resolved,
	-- byte offset inside the struct, nil when the struct is dynamic
	offset: number?,
	-- first bitfield bit index, for bool / optional presence
	bit: number?,
	span: Span,
}

--[[
	Inclusive value ranges for the integer primitives, used to reject a
	`u8(0..300)` at compile time rather than clamping silently at runtime.
]]
local PRIM_RANGES: { [string]: { number } } = {
	u8 = { 0, 255 },
	u16 = { 0, 65535 },
	u32 = { 0, 4294967295 },
	i8 = { -128, 127 },
	i16 = { -32768, 32767 },
	i32 = { -2147483648, 2147483647 },
}

export type Symbols = {
	structs: { [string]: Ast.StructDecl },
	enums: { [string]: Ast.EnumDecl },
	-- structs currently being resolved, for cycle detection
	resolving: { [string]: boolean },
	-- memoised struct results
	cache: { [string]: Resolved },
	reporter: ReporterImpl,
}

local function lengthBytes(cap: number): number
	return if cap <= 255 then 1 else 2
end

--[[
	Packs a list of fields into byte offsets and bitfield bits.

	Booleans go first as a bitfield, so a packet of 32 flags costs 4 bytes and a
	single `writeu32` instead of 32 separate byte writes. That is the exact case
	where the survey measured Blink at 97 FPS against ByteNet's 35.

	Returns the fields (mutated with offsets), the total fixed size, the worst
	case size, and whether the whole group is fixed-size.
]]
function Resolve.layoutFields(fields: { ResolvedField }): (number, number, boolean, number)
	local bitCount = 0
	for _, field in fields do
		bitCount += field.type.bits
	end

	local bitfieldBytes = math.ceil(bitCount / 8)
	local minSize = bitfieldBytes
	local maxSize = bitfieldBytes
	local allFixed = true
	local nextBit = 0

	for _, field in fields do
		if field.type.bits > 0 then
			field.bit = nextBit
			nextBit += field.type.bits
		end

		-- A constant offset is only valid while every preceding field has had a
		-- constant size. After the first dynamic field the emitter has to fall
		-- back to a running cursor, so leaving a stale offset here would be a
		-- silently wrong write.
		if allFixed and field.type.fixed then
			field.offset = minSize
		else
			field.offset = nil
		end

		if not field.type.fixed then
			allFixed = false
		end

		minSize += field.type.size
		maxSize += field.type.maxSize
	end

	return minSize, maxSize, allFixed, bitfieldBytes
end

local resolveType: (Ast.TypeRef, Symbols) -> Resolved

local function resolveStruct(name: string, span: Span, symbols: Symbols): Resolved
	local cached = symbols.cache[name]
	if cached then
		return cached
	end

	if symbols.resolving[name] then
		symbols.reporter:fatal({
			message = `struct '{name}' contains itself`,
			span = span,
			label = "recursive type",
			help = "a packet has to have a bounded size; break the cycle or use an id field instead",
		})
	end

	local decl = symbols.structs[name]
	symbols.resolving[name] = true

	local fields: { ResolvedField } = {}
	for _, field in decl.fields do
		table.insert(fields, {
			name = field.name,
			type = resolveType(field.type, symbols),
			span = field.span,
		})
	end

	local size, maxSize, fixed = Resolve.layoutFields(fields)
	symbols.resolving[name] = nil

	local usesRefs = false
	for _, field in fields do
		if field.type.usesRefs then
			usesRefs = true
			break
		end
	end

	local resolved: Resolved = {
		kind = "struct",
		name = name,
		fields = fields,
		size = size,
		maxSize = maxSize,
		fixed = fixed,
		-- A struct owns its own internal bitfield, so from the container's
		-- point of view it is just bytes.
		bits = 0,
		usesRefs = usesRefs,
		span = span,
	}

	symbols.cache[name] = resolved
	return resolved
end

local function resolvePrim(ref: Ast.TypeRef, symbols: Symbols): Resolved
	local name = ref.name :: string
	local reporter = symbols.reporter

	if name == "string" then
		if not ref.cap then
			reporter:fatal({
				message = "`string` needs a maximum length",
				span = ref.span,
				label = "no length cap",
				help = "write `string(24)`. An uncapped string is an uncapped packet, which is both a bandwidth leak and a free amplification primitive for an exploiter",
			})
		end
		local cap = ref.cap :: number
		if cap < 1 or cap > 65535 or cap % 1 ~= 0 then
			reporter:fatal({
				message = `invalid string length {cap}`,
				span = ref.span,
				label = "out of range",
				help = "the cap must be a whole number between 1 and 65535",
			})
		end

		local lenBytes = lengthBytes(cap)
		return {
			kind = "string",
			name = "string",
			cap = cap,
			lenBytes = lenBytes,
			size = lenBytes,
			maxSize = lenBytes + cap,
			fixed = false,
			bits = 0,
			usesRefs = false,
			span = ref.span,
		}
	end

	if name == "fixed" then
		local args = ref.args
		if not args or #args ~= 3 then
			reporter:fatal({
				message = "`fixed` takes three arguments",
				span = ref.span,
				label = "wrong argument count",
				help = "write `fixed(min, max, bytes)`, e.g. `fixed(-1, 1, 2)` for a value in [-1, 1] quantised to two bytes",
			})
		end
		local low, high, bytes = args[1], args[2], args[3]
		if low >= high then
			reporter:fatal({
				message = "`fixed` needs min < max",
				span = ref.span,
				label = `got min = {low}, max = {high}`,
			})
		end
		if bytes ~= 1 and bytes ~= 2 and bytes ~= 4 then
			reporter:fatal({
				message = `\`fixed\` byte width must be 1, 2 or 4, got {bytes}`,
				span = ref.span,
				label = "unsupported width",
				help = "two bytes gives 65536 steps across the range, which covers almost every gameplay value",
			})
		end

		return {
			kind = "prim",
			name = "fixed",
			args = args,
			size = bytes,
			maxSize = bytes,
			fixed = true,
			bits = 0,
			usesRefs = false,
			span = ref.span,
		}
	end

	if ref.cap ~= nil then
		reporter:fatal({
			message = `'{name}' does not take a length argument`,
			span = ref.span,
			label = "unexpected argument",
			help = "only `string(n)` takes a length",
		})
	end

	if ref.min ~= nil then
		if not Ast.RANGEABLE[name] then
			reporter:fatal({
				message = `'{name}' does not take a range`,
				span = ref.span,
				label = "unexpected range",
				help = "ranges apply to the integer and float primitives, e.g. `u8(0..100)`",
			})
		end

		local low, high = ref.min :: number, ref.max :: number
		if low > high then
			reporter:fatal({
				message = `range is inverted: {low}..{high}`,
				span = ref.span,
				label = "min is greater than max",
			})
		end

		local limits = PRIM_RANGES[name]
		if limits and (low < limits[1] or high > limits[2]) then
			reporter:fatal({
				message = `range {low}..{high} does not fit in {name}`,
				span = ref.span,
				label = `{name} holds {limits[1]}..{limits[2]}`,
				help = "widen the type or narrow the range",
			})
		end
	end

	if name == "bool" then
		return {
			kind = "bool",
			name = "bool",
			size = 0,
			maxSize = 0,
			fixed = true,
			bits = 1,
			usesRefs = false,
			span = ref.span,
		}
	end

	if name == "Instance" then
		return {
			kind = "instance",
			name = "Instance",
			size = 2,
			maxSize = 2,
			fixed = true,
			bits = 0,
			usesRefs = true,
			span = ref.span,
		}
	end

	local size = Ast.PRIMITIVE_SIZES[name]
	return {
		kind = "prim",
		name = name,
		min = ref.min,
		max = ref.max,
		size = size,
		maxSize = size,
		fixed = true,
		bits = 0,
		usesRefs = false,
		span = ref.span,
	}
end

function resolveType(ref: Ast.TypeRef, symbols: Symbols): Resolved
	local reporter = symbols.reporter

	if ref.kind == "array" then
		local cap = ref.cap :: number
		if cap < 1 or cap > 65535 or cap % 1 ~= 0 then
			reporter:fatal({
				message = `invalid array capacity {cap}`,
				span = ref.span,
				label = "out of range",
				help = "the capacity must be a whole number between 1 and 65535",
			})
		end

		local element = resolveType(ref.of :: Ast.TypeRef, symbols)
		if element.kind == "bool" then
			reporter:fatal({
				message = "arrays of `bool` are not supported",
				span = ref.span,
				label = "use a wider type",
				help = "booleans are packed into a shared bitfield, which an array cannot address; use `u32` and `bit32` for a flag set",
			})
		end

		-- An optional of a fixed type keeps its presence in the container's
		-- bitfield, and an array element has no bitfield to spend a bit in.
		if element.kind == "optional" and element.fixed then
			reporter:fatal({
				message = "arrays cannot hold optionals of fixed-size types",
				span = ref.span,
				label = "unsupported element type",
				help = "wrap the optional in a struct — `struct Slot { value: u16? }` — which carries its own presence bit, or use a sentinel value",
			})
		end

		local lenBytes = lengthBytes(cap)
		return {
			kind = "array",
			of = element,
			cap = cap,
			lenBytes = lenBytes,
			size = lenBytes,
			maxSize = lenBytes + cap * element.maxSize,
			fixed = false,
			bits = 0,
			usesRefs = element.usesRefs,
			span = ref.span,
		}
	end

	if ref.kind == "optional" then
		local inner = resolveType(ref.of :: Ast.TypeRef, symbols)
		if inner.kind == "optional" then
			reporter:fatal({
				message = "`??` is not a type",
				span = ref.span,
				label = "double optional",
				help = "one level of optionality is all the wire format can express",
			})
		end

		if inner.fixed then
			-- Stays fixed: one presence bit plus payload bytes that are always
			-- written. Keeps the constant-offset fast path for `u8?` and friends.
			return {
				kind = "optional",
				of = inner,
				size = inner.size,
				maxSize = inner.maxSize,
				fixed = true,
				bits = 1 + inner.bits,
				usesRefs = inner.usesRefs,
				span = ref.span,
			}
		end

		return {
			kind = "optional",
			of = inner,
			size = 1,
			maxSize = 1 + inner.maxSize,
			fixed = false,
			bits = 0,
			usesRefs = inner.usesRefs,
			span = ref.span,
		}
	end

	if ref.kind == "prim" then
		return resolvePrim(ref, symbols)
	end

	local name = ref.name :: string

	if symbols.structs[name] then
		return resolveStruct(name, ref.span, symbols)
	end

	if symbols.enums[name] then
		local decl = symbols.enums[name]
		local count = #decl.variants
		if count == 0 then
			reporter:fatal({
				message = `enum '{name}' has no variants`,
				span = ref.span,
				help = "an enum needs at least one variant to be sendable",
			})
		end

		return {
			kind = "enum",
			name = name,
			variants = decl.variants,
			size = if count <= 256 then 1 else 2,
			maxSize = if count <= 256 then 1 else 2,
			fixed = true,
			bits = 0,
			usesRefs = false,
			span = ref.span,
		}
	end

	-- Unknown name. Suggest across primitives and everything declared in the file.
	local candidates = Ast.primitiveNames()
	for structName in symbols.structs do
		table.insert(candidates, structName)
	end
	for enumName in symbols.enums do
		table.insert(candidates, enumName)
	end

	local suggestion = Diagnostics.suggest(name, candidates)
	reporter:fatal({
		message = `unknown type '{name}'`,
		span = ref.span,
		label = "not a known type",
		help = if suggestion
			then `did you mean '{suggestion}'?`
			else `available primitives: {table.concat(Ast.primitiveNames(), ", ")}`,
	})
	error("unreachable")
end

Resolve.type = resolveType

return Resolve
