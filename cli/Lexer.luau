--!strict
--[[
	Tokeniser for .btyn.

	There are no reserved words. `event`, `from`, `rate` and friends are matched
	contextually by the parser, so a field may legitimately be called `rate` or
	`from` — one less rule for the reader to memorise.

	Comments follow Luau: a line comment starts with a double dash, and the
	block form opens with `--[[` (the levelled `--[=[` long brackets are not
	supported). The audience already writes Luau all day, so that is one less
	rule to learn.
]]

local Diagnostics = require("./Diagnostics")

type Span = Diagnostics.Span
type ReporterImpl = Diagnostics.ReporterImpl

local Lexer = {}

export type TokenKind = "ident" | "number" | "string" | "punct" | "eof"

export type Token = {
	kind: TokenKind,
	text: string,
	number: number?,
	span: Span,
}

local function isDigit(c: string): boolean
	return c >= "0" and c <= "9"
end

local function isAlpha(c: string): boolean
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end

local function isAlphaNumeric(c: string): boolean
	return isAlpha(c) or isDigit(c)
end

--[[
	Multi-character punctuation, longest first so `->` wins over `-`.
]]
local PUNCT = { "->", "..", "{", "}", "(", ")", "[", "]", ":", ",", ";", "?", "=", "-" }

--[[
	Turns source text into a flat token list, ending with a single `eof` token.
	Raises through the reporter on malformed input.
]]
function Lexer.tokenise(source: string, reporter: ReporterImpl): { Token }
	local tokens: { Token } = {}
	local normalised = string.gsub(source, "\r\n", "\n")
	local length = #normalised

	local pos = 1
	local line = 1
	local col = 1

	local function peek(offset: number?): string
		local at = pos + (offset or 0)
		if at > length then
			return ""
		end
		return string.sub(normalised, at, at)
	end

	local function advance(count: number)
		for _ = 1, count do
			if string.sub(normalised, pos, pos) == "\n" then
				line += 1
				col = 1
			else
				col += 1
			end
			pos += 1
		end
	end

	local function spanHere(len: number): Span
		return { line = line, col = col, len = len }
	end

	while pos <= length do
		local c = peek()

		if c == " " or c == "\t" or c == "\n" or c == "\r" then
			advance(1)
			continue
		end

		-- Comments. `--[[ ... ]]` block form, otherwise to end of line.
		if c == "-" and peek(1) == "-" then
			if peek(2) == "[" and peek(3) == "[" then
				local startSpan = spanHere(2)
				advance(4)
				local closed = false
				while pos <= length do
					if peek() == "]" and peek(1) == "]" then
						advance(2)
						closed = true
						break
					end
					advance(1)
				end
				if not closed then
					reporter:fatal({
						message = "unterminated block comment",
						span = startSpan,
						label = "opened here",
						help = "close it with `]]`",
					})
				end
			else
				while pos <= length and peek() ~= "\n" do
					advance(1)
				end
			end
			continue
		end

		if isAlpha(c) then
			local startSpan = spanHere(0)
			local startPos = pos
			while pos <= length and isAlphaNumeric(peek()) do
				advance(1)
			end
			local text = string.sub(normalised, startPos, pos - 1)
			startSpan.len = #text
			table.insert(tokens, { kind = "ident", text = text, span = startSpan })
			continue
		end

		if isDigit(c) then
			local startSpan = spanHere(0)
			local startPos = pos
			while pos <= length and isDigit(peek()) do
				advance(1)
			end
			-- A decimal point, but not the `..` range operator.
			if peek() == "." and peek(1) ~= "." then
				advance(1)
				while pos <= length and isDigit(peek()) do
					advance(1)
				end
			end
			local text = string.sub(normalised, startPos, pos - 1)
			startSpan.len = #text
			table.insert(tokens, {
				kind = "number",
				text = text,
				number = tonumber(text),
				span = startSpan,
			})
			continue
		end

		if c == '"' then
			local startSpan = spanHere(0)
			local startPos = pos
			advance(1)
			local chars = {}
			local closed = false
			while pos <= length do
				local ch = peek()
				if ch == "\\" then
					advance(1)
					local escaped = peek()
					if escaped == "n" then
						table.insert(chars, "\n")
					elseif escaped == "t" then
						table.insert(chars, "\t")
					else
						table.insert(chars, escaped)
					end
					advance(1)
				elseif ch == '"' then
					advance(1)
					closed = true
					break
				elseif ch == "\n" then
					break
				else
					table.insert(chars, ch)
					advance(1)
				end
			end
			if not closed then
				startSpan.len = math.max(pos - startPos, 1)
				reporter:fatal({
					message = "unterminated string",
					span = startSpan,
					label = "opened here",
					help = 'strings must close on the same line, e.g. "src/Server/Net.luau"',
				})
			end
			startSpan.len = pos - startPos
			table.insert(tokens, { kind = "string", text = table.concat(chars), span = startSpan })
			continue
		end

		local matched = false
		for _, punct in PUNCT do
			if string.sub(normalised, pos, pos + #punct - 1) == punct then
				local span = spanHere(#punct)
				advance(#punct)
				table.insert(tokens, { kind = "punct", text = punct, span = span })
				matched = true
				break
			end
		end
		if matched then
			continue
		end

		reporter:fatal({
			message = `unexpected character '{c}'`,
			span = spanHere(1),
			label = "not valid here",
		})
	end

	table.insert(tokens, { kind = "eof", text = "<eof>", span = { line = line, col = col, len = 1 } })
	return tokens
end

return Lexer
