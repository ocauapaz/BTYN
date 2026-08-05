--!strict
--[[
	AST for the .btyn schema language.

	Shape of a schema file:

	    config { server = "src/Server/Net.luau" }

	    event Attack from client rate 10 {
	        target: entity,
	        combo:  u8,
	    }

	    unreliable Muzzle from server { at: vec3, dir: unit }

	    request Buy from client { item: u16 } -> { ok: bool, balance: u32 }

	    channel Health priority high { hp: u8(0..100), downed: bool }

	    struct Vec2i { x: i16, y: i16 }
	    enum   Team  { Red, Blue, Spectator }
]]

local Diagnostics = require("./Diagnostics")

type Span = Diagnostics.Span

local Ast = {}

export type Direction = "client" | "server"
export type Priority = "low" | "normal" | "high"

--[[
	A type reference as written in the source.

	  prim      u8, f32, bool, vec3, string(24), u8(0..100), fixed(-1, 1, 2)
	  named     a struct or enum declared elsewhere in the file
	  array     [u16; 100]
	  optional  u8?
]]
export type TypeRef = {
	kind: "prim" | "named" | "array" | "optional",
	-- prim / named
	name: string?,
	-- array element, optional inner type
	of: TypeRef?,
	-- string(N) and [T; N] capacity. Mandatory for both: an unbounded string or
	-- array is an unbounded packet, which is how you blow the bandwidth budget
	-- and hand an exploiter a free amplification primitive.
	cap: number?,
	-- u8(0..100) inclusive range validation
	min: number?,
	max: number?,
	-- fixed(min, max, bytes) quantisation
	args: { number }?,
	span: Span,
}

export type Field = {
	name: string,
	type: TypeRef,
	span: Span,
}

export type ConfigEntry = {
	key: string,
	value: string | number | boolean,
	span: Span,
	valueSpan: Span,
}

export type ConfigDecl = {
	kind: "config",
	entries: { ConfigEntry },
	span: Span,
}

export type EventDecl = {
	kind: "event",
	name: string,
	from: Direction,
	reliable: boolean,
	rate: number?,
	fields: { Field },
	span: Span,
	nameSpan: Span,
}

export type RequestDecl = {
	kind: "request",
	name: string,
	from: Direction,
	rate: number?,
	fields: { Field },
	reply: { Field },
	span: Span,
	nameSpan: Span,
}

export type ChannelDecl = {
	kind: "channel",
	name: string,
	priority: Priority,
	fields: { Field },
	span: Span,
	nameSpan: Span,
}

export type StructDecl = {
	kind: "struct",
	name: string,
	fields: { Field },
	span: Span,
	nameSpan: Span,
}

export type EnumDecl = {
	kind: "enum",
	name: string,
	variants: { string },
	span: Span,
	nameSpan: Span,
}

export type Decl = ConfigDecl | EventDecl | RequestDecl | ChannelDecl | StructDecl | EnumDecl

export type File = {
	decls: { Decl },
}

--[[
	Primitive types and their fixed byte widths.

	`entity` is a plain u32 game-owned id. It exists as its own name to steer
	people away from `Instance`: Instance refs cost bandwidth, cannot live in a
	buffer at all, and arrive nil when the receiver has not streamed the object
	in yet.
]]
Ast.PRIMITIVE_SIZES = {
	u8 = 1,
	u16 = 2,
	u32 = 4,
	i8 = 1,
	i16 = 2,
	i32 = 4,
	f32 = 4,
	f64 = 8,
	bool = 0, -- packed into a shared bitfield; contributes no standalone byte
	entity = 4,
	vec3 = 12, -- 3×f32
	cframe = 18, -- position as 3×f32, rotation as 3×i16 quantised euler angles
	color3 = 3, -- one byte per channel
	-- Each component quantised to i16. Octahedral encoding would fit a unit
	-- vector in 4 bytes instead of 6, but costs a page of subtle branchy maths
	-- either side; revisit only if a profile says these two bytes matter.
	unit = 6,
	angle = 2, -- radians quantised to u16 across [-pi, pi]
	Instance = 2, -- index into the sidecar ref array
} :: { [string]: number }

-- Types that take a `(...)` argument list.
Ast.PARAMETRIC = {
	string = "cap", -- string(24)
	fixed = "quant", -- fixed(min, max, bytes)
} :: { [string]: string }

-- Numeric primitives accept an optional inclusive `(min..max)` range.
Ast.RANGEABLE = {
	u8 = true,
	u16 = true,
	u32 = true,
	i8 = true,
	i16 = true,
	i32 = true,
	f32 = true,
	f64 = true,
} :: { [string]: boolean }

function Ast.isPrimitive(name: string): boolean
	return Ast.PRIMITIVE_SIZES[name] ~= nil or Ast.PARAMETRIC[name] ~= nil
end

--[[
	Every primitive name, for "did you mean" suggestions.
]]
function Ast.primitiveNames(): { string }
	local names = {}
	for name in Ast.PRIMITIVE_SIZES do
		table.insert(names, name)
	end
	for name in Ast.PARAMETRIC do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return Ast
