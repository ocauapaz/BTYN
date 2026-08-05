--!strict
--[[
	Compiler diagnostics.

	Error messages are a feature, not an afterthought: a schema language is only
	"easy to understand" if being wrong is easy to understand too. Output is
	Rust-style — a source snippet, a caret under the offending span, and a help
	line that suggests the fix.

	    error: unknown type 'u128'
	      --> net.btyn:12:13
	       |
	    12 |     amount: u128,
	       |             ^^^^ not a known type
	       |
	    help: did you mean 'u32'?
]]

local Diagnostics = {}

export type Span = {
	line: number,
	col: number,
	len: number,
}

export type Diagnostic = {
	message: string,
	span: Span?,
	label: string?,
	help: string?,
}

export type Reporter = {
	file: string,
	lines: { string },
	diagnostics: { Diagnostic },
}

-- Thrown by `fatal`. `main` catches this to print the rendered message instead
-- of a Luau traceback, which would bury the actual error.
--
-- `diagnostics` carries the same information unrendered, so an editor can place
-- squiggles without parsing the pretty output back apart.
export type Bail = {
	isBtynBail: true,
	rendered: string,
	diagnostics: { Diagnostic },
}

local RESET = "\27[0m"
local BOLD = "\27[1m"
local RED = "\27[31m"
local BLUE = "\27[34m"
local CYAN = "\27[36m"

local useColor = true

function Diagnostics.setColor(enabled: boolean)
	useColor = enabled
end

local function paint(code: string, text: string): string
	if not useColor then
		return text
	end
	return code .. text .. RESET
end

local function splitLines(source: string): { string }
	local lines = {}
	-- Normalise CRLF so column math matches what the editor shows.
	local normalised = string.gsub(source, "\r\n", "\n")
	for line in string.gmatch(normalised .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end
	-- The trailing split always produces one phantom empty line; drop it.
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

local Reporter = {}
Reporter.__index = Reporter

export type ReporterImpl = typeof(setmetatable({} :: Reporter, Reporter))

function Diagnostics.new(file: string, source: string): ReporterImpl
	return setmetatable({
		file = file,
		lines = splitLines(source),
		diagnostics = {},
	} :: Reporter, Reporter)
end

--[[
	Renders one diagnostic to a printable string.
]]
function Reporter.render(self: ReporterImpl, diag: Diagnostic): string
	local out = {}

	table.insert(out, paint(BOLD .. RED, "error") .. paint(BOLD, ": " .. diag.message))

	local span = diag.span
	if span then
		local lineText = self.lines[span.line] or ""
		local gutter = tostring(span.line)
		local pad = string.rep(" ", #gutter)

		table.insert(out, pad .. paint(BLUE, " --> ") .. `{self.file}:{span.line}:{span.col}`)
		table.insert(out, pad .. paint(BLUE, " |"))
		table.insert(out, paint(BLUE, gutter .. " | ") .. lineText)

		-- Tabs occupy one column in our count but render wider; echo the
		-- original whitespace so the caret lands under the right character.
		local prefix = string.gsub(string.sub(lineText, 1, span.col - 1), "[^\t]", " ")
		local caret = string.rep("^", math.max(span.len, 1))
		local label = if diag.label then " " .. diag.label else ""
		table.insert(out, pad .. paint(BLUE, " | ") .. prefix .. paint(BOLD .. RED, caret .. label))
		table.insert(out, pad .. paint(BLUE, " |"))
	end

	if diag.help then
		table.insert(out, paint(BOLD .. CYAN, "help") .. ": " .. diag.help)
	end

	return table.concat(out, "\n")
end

--[[
	Collects a diagnostic and keeps going. The analyzer uses this so one run
	surfaces every schema error, not just the first.
]]
function Reporter.add(self: ReporterImpl, diag: Diagnostic)
	table.insert(self.diagnostics, diag)
end

--[[
	Aborts compilation immediately. The lexer and parser use this: once the
	token stream is wrong, every later message is noise.
]]
function Reporter.fatal(self: ReporterImpl, diag: Diagnostic): never
	local bail: Bail = {
		isBtynBail = true,
		rendered = self:render(diag),
		diagnostics = { diag },
	}
	error(bail, 0)
end

function Reporter.hasErrors(self: ReporterImpl): boolean
	return #self.diagnostics > 0
end

--[[
	Renders everything collected so far, then aborts if anything was collected.
]]
function Reporter.bailIfErrors(self: ReporterImpl)
	if #self.diagnostics == 0 then
		return
	end

	local parts = {}
	for _, diag in self.diagnostics do
		table.insert(parts, self:render(diag))
	end

	local count = #self.diagnostics
	table.insert(parts, paint(BOLD .. RED, `\n{count} error{if count == 1 then "" else "s"} — no output written.`))

	local bail: Bail = {
		isBtynBail = true,
		rendered = table.concat(parts, "\n\n"),
		diagnostics = table.clone(self.diagnostics),
	}
	error(bail, 0)
end

function Diagnostics.isBail(err: any): boolean
	return type(err) == "table" and (err :: any).isBtynBail == true
end

--[[
	Levenshtein distance, used for "did you mean" suggestions.
]]
local function distance(a: string, b: string): number
	local aLen, bLen = #a, #b
	if aLen == 0 then
		return bLen
	end
	if bLen == 0 then
		return aLen
	end

	local prev = table.create(bLen + 1)
	local curr = table.create(bLen + 1)
	for j = 0, bLen do
		prev[j + 1] = j
	end

	for i = 1, aLen do
		curr[1] = i
		local aChar = string.byte(a, i)
		for j = 1, bLen do
			local cost = if aChar == string.byte(b, j) then 0 else 1
			curr[j + 1] = math.min(curr[j] + 1, prev[j + 1] + 1, prev[j] + cost)
		end
		prev, curr = curr, prev
	end

	return prev[bLen + 1]
end

--[[
	Picks the closest candidate to `word`, or nil when nothing is close enough
	to be worth suggesting. A bad suggestion is worse than none.
]]
function Diagnostics.suggest(word: string, candidates: { string }): string?
	local best: string? = nil
	local bestScore = math.huge
	local lowered = string.lower(word)

	for _, candidate in candidates do
		local score = distance(lowered, string.lower(candidate))
		if score < bestScore then
			bestScore = score
			best = candidate
		end
	end

	-- Allow roughly a third of the word to differ before giving up.
	local threshold = math.max(2, math.floor(#word / 3))
	if bestScore <= threshold then
		return best
	end
	return nil
end

return Diagnostics
