--!strict
--[[
	Indented source builder for the generated Luau.

	Generated code gets read by humans — when a packet misbehaves the first
	thing anyone does is open the output — so it is formatted properly rather
	than dumped on one line.
]]

local Writer = {}

export type State = {
	lines: { string },
	depth: number,
}

export type Impl = typeof(setmetatable({} :: State, {} :: any))

local methods = {}
methods.__index = methods

function Writer.new(): Impl
	return setmetatable({ lines = {}, depth = 0 } :: State, methods) :: any
end

function methods.line(self: Impl, text: string?)
	if text == nil or text == "" then
		table.insert(self.lines, "")
		return
	end
	table.insert(self.lines, string.rep("\t", self.depth) .. text)
end

function methods.push(self: Impl, text: string?)
	if text then
		self:line(text)
	end
	self.depth += 1
end

function methods.pop(self: Impl, text: string?)
	self.depth = math.max(self.depth - 1, 0)
	if text then
		self:line(text)
	end
end

--[[
	Appends another builder's lines at the current depth.
]]
function methods.concat(self: Impl, other: Impl)
	for _, line in other.lines do
		table.insert(self.lines, if line == "" then "" else string.rep("\t", self.depth) .. line)
	end
end

function methods.build(self: Impl): string
	return table.concat(self.lines, "\n")
end

--[[
	`o` and `o + 4` rather than `o + 0`; small thing, but the generated code is
	read often enough to be worth it.
]]
function Writer.offset(base: string, delta: number): string
	if delta == 0 then
		return base
	end
	return `{base} + {delta}`
end

return Writer
