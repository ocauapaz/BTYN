--!strict
--[[
	Recursive-descent parser for .btyn.

	Design goal for the grammar: the common case costs one line of ceremony.
	Zap and Blink both spend four lines (from / type / call / data) before you
	reach a single field; here those become trailing modifiers with sane
	defaults, so `event Attack from client { ... }` is the whole declaration.

	The parser bails on the first syntax error. Once the token stream is wrong
	every later message is invented, so recovery would cost complexity and
	produce worse output. The analyzer, which runs on a valid tree, collects all
	its errors instead.
]]

local Ast = require("./Ast")
local Diagnostics = require("./Diagnostics")
local Lexer = require("./Lexer")

type Span = Diagnostics.Span
type ReporterImpl = Diagnostics.ReporterImpl
type Token = Lexer.Token

local Parser = {}

local DECL_KEYWORDS = { "config", "event", "unreliable", "request", "channel", "struct", "enum" }
local MODIFIER_KEYWORDS = { "from", "rate", "priority" }
local PRIORITIES = { low = true, normal = true, high = true }

type State = {
	tokens: { Token },
	pos: number,
	reporter: ReporterImpl,
}

local function peek(state: State, offset: number?): Token
	local index = math.min(state.pos + (offset or 0), #state.tokens)
	return state.tokens[index]
end

local function isPunct(token: Token, text: string): boolean
	return token.kind == "punct" and token.text == text
end

local function isIdent(token: Token, text: string): boolean
	return token.kind == "ident" and token.text == text
end

local function advance(state: State): Token
	local token = state.tokens[state.pos]
	if token.kind ~= "eof" then
		state.pos += 1
	end
	return token
end

local function matchPunct(state: State, text: string): boolean
	if isPunct(peek(state), text) then
		advance(state)
		return true
	end
	return false
end

local function describe(token: Token): string
	if token.kind == "eof" then
		return "end of file"
	elseif token.kind == "string" then
		return `string "{token.text}"`
	end
	return `'{token.text}'`
end

local function expectPunct(state: State, text: string, context: string): Token
	local token = peek(state)
	if isPunct(token, text) then
		return advance(state)
	end
	state.reporter:fatal({
		message = `expected '{text}' {context}, found {describe(token)}`,
		span = token.span,
		label = `expected '{text}'`,
	})
	error("unreachable")
end

local function expectIdent(state: State, context: string): Token
	local token = peek(state)
	if token.kind == "ident" then
		return advance(state)
	end
	state.reporter:fatal({
		message = `expected {context}, found {describe(token)}`,
		span = token.span,
		label = "expected a name",
	})
	error("unreachable")
end

--[[
	Parses an optionally negative number literal. `fixed(-1, 1, 2)` needs the
	sign, so `-` is lexed as its own token and folded in here.
]]
local function expectNumber(state: State, context: string): (number, Span)
	local negative = false
	local startSpan = peek(state).span
	if isPunct(peek(state), "-") then
		advance(state)
		negative = true
	end

	local token = peek(state)
	if token.kind ~= "number" then
		state.reporter:fatal({
			message = `expected a number {context}, found {describe(token)}`,
			span = token.span,
			label = "expected a number",
		})
	end
	advance(state)

	local value = token.number :: number
	return (if negative then -value else value), startSpan
end

--[[
	type := ( '[' type ';' number ']' | ident args? ) '?'?
	args := '(' signed ( '..' signed | (',' signed)* )? ')'
]]
local function parseType(state: State): Ast.TypeRef
	local token = peek(state)
	local result: Ast.TypeRef

	if isPunct(token, "[") then
		advance(state)
		local element = parseType(state)
		expectPunct(state, ";", "after the array element type")
		local cap = expectNumber(state, "for the array capacity")
		expectPunct(state, "]", "to close the array type")

		result = {
			kind = "array",
			of = element,
			cap = cap,
			span = token.span,
		}
	else
		local name = expectIdent(state, "a type name")
		result = {
			kind = if Ast.isPrimitive(name.text) then "prim" else "named",
			name = name.text,
			span = name.span,
		}

		if matchPunct(state, "(") then
			local first = expectNumber(state, "in the type argument list")

			if matchPunct(state, "..") then
				local last = expectNumber(state, "for the end of the range")
				result.min = first
				result.max = last
			else
				local nums = { first }
				while matchPunct(state, ",") do
					table.insert(nums, (expectNumber(state, "in the type argument list")))
				end
				if #nums == 1 then
					result.cap = nums[1]
				else
					result.args = nums
				end
			end

			expectPunct(state, ")", "to close the type arguments")
		end
	end

	-- Loops rather than matching once so `u8??` parses and the resolver can
	-- reject it by name, instead of failing here as a stray token.
	while matchPunct(state, "?") do
		result = {
			kind = "optional",
			of = result,
			span = result.span,
		}
	end

	return result
end

--[[
	block := '{' (field (',' field)* ','?)? '}'
	field := ident ':' type
]]
local function parseFields(state: State, context: string): { Ast.Field }
	expectPunct(state, "{", context)
	local fields: { Ast.Field } = {}

	while not isPunct(peek(state), "}") do
		if peek(state).kind == "eof" then
			state.reporter:fatal({
				message = "unexpected end of file inside a field list",
				span = peek(state).span,
				label = "expected '}'",
				help = "every `{` needs a matching `}`",
			})
		end

		local name = expectIdent(state, "a field name")
		expectPunct(state, ":", `after field '{name.text}'`)
		local fieldType = parseType(state)

		table.insert(fields, {
			name = name.text,
			type = fieldType,
			span = name.span,
		})

		if not matchPunct(state, ",") then
			break
		end
	end

	expectPunct(state, "}", "to close the field list")
	return fields
end

type Modifiers = {
	from: Ast.Direction?,
	rate: number?,
	priority: Ast.Priority?,
}

--[[
	Trailing modifiers: `from client`, `rate 10`, `priority high`.
]]
local function parseModifiers(state: State): Modifiers
	local mods: Modifiers = {}

	while peek(state).kind == "ident" do
		local token = peek(state)

		if token.text == "from" then
			advance(state)
			local dir = expectIdent(state, "'client' or 'server'")
			if dir.text ~= "client" and dir.text ~= "server" then
				state.reporter:fatal({
					message = `unknown direction '{dir.text}'`,
					span = dir.span,
					label = "expected 'client' or 'server'",
					help = "`from client` means the client sends and the server receives",
				})
			end
			mods.from = dir.text :: Ast.Direction
		elseif token.text == "rate" then
			advance(state)
			local value = expectNumber(state, "after 'rate'")
			mods.rate = value
		elseif token.text == "priority" then
			advance(state)
			local level = expectIdent(state, "a priority level")
			if not PRIORITIES[level.text] then
				state.reporter:fatal({
					message = `unknown priority '{level.text}'`,
					span = level.span,
					label = "expected 'low', 'normal' or 'high'",
					help = "low-priority channels are deferred first when a client is over its byte budget",
				})
			end
			mods.priority = level.text :: Ast.Priority
		else
			local suggestion = Diagnostics.suggest(token.text, MODIFIER_KEYWORDS)
			state.reporter:fatal({
				message = `unexpected '{token.text}' in the declaration header`,
				span = token.span,
				label = "not a modifier",
				help = if suggestion
					then `did you mean '{suggestion}'?`
					else "modifiers are `from client|server`, `rate <n>` and `priority low|normal|high`",
			})
		end
	end

	return mods
end

local function requireDirection(state: State, mods: Modifiers, kind: string, name: Token): Ast.Direction
	if mods.from then
		return mods.from
	end
	state.reporter:fatal({
		message = `{kind} '{name.text}' is missing a direction`,
		span = name.span,
		label = "no `from` here",
		help = `write \`{kind} {name.text} from client \{ ... }\` or \`from server\``,
	})
	error("unreachable")
end

local function rejectPriority(state: State, mods: Modifiers, kind: string)
	if mods.priority ~= nil then
		state.reporter:fatal({
			message = `'priority' is not valid on {kind}`,
			span = peek(state).span,
			help = "priority only applies to `channel`, where it decides what gets deferred under load",
		})
	end
end

local function parseConfig(state: State, keyword: Token): Ast.ConfigDecl
	expectPunct(state, "{", "after 'config'")
	local entries: { Ast.ConfigEntry } = {}

	while not isPunct(peek(state), "}") do
		if peek(state).kind == "eof" then
			state.reporter:fatal({
				message = "unexpected end of file inside `config`",
				span = peek(state).span,
				label = "expected '}'",
			})
		end

		local key = expectIdent(state, "a config key")
		expectPunct(state, "=", `after config key '{key.text}'`)

		local valueToken = peek(state)
		local value: string | number | boolean

		if valueToken.kind == "string" then
			advance(state)
			value = valueToken.text
		elseif valueToken.kind == "number" then
			advance(state)
			value = valueToken.number :: number
		elseif isIdent(valueToken, "true") or isIdent(valueToken, "false") then
			advance(state)
			value = valueToken.text == "true"
		else
			state.reporter:fatal({
				message = `expected a string, number or boolean for config key '{key.text}', found {describe(valueToken)}`,
				span = valueToken.span,
				label = "invalid config value",
			})
			error("unreachable")
		end

		table.insert(entries, {
			key = key.text,
			value = value,
			span = key.span,
			valueSpan = valueToken.span,
		})

		-- Commas between config entries are optional.
		matchPunct(state, ",")
	end

	expectPunct(state, "}", "to close `config`")
	return { kind = "config", entries = entries, span = keyword.span }
end

local function parseEnum(state: State, keyword: Token): Ast.EnumDecl
	local name = expectIdent(state, "an enum name")
	expectPunct(state, "{", `after enum '{name.text}'`)

	local variants: { string } = {}
	while not isPunct(peek(state), "}") do
		if peek(state).kind == "eof" then
			state.reporter:fatal({
				message = "unexpected end of file inside an enum",
				span = peek(state).span,
				label = "expected '}'",
			})
		end
		local variant = expectIdent(state, "an enum variant")
		table.insert(variants, variant.text)
		if not matchPunct(state, ",") then
			break
		end
	end

	expectPunct(state, "}", "to close the enum")
	return {
		kind = "enum",
		name = name.text,
		variants = variants,
		span = keyword.span,
		nameSpan = name.span,
	}
end

--[[
	Parses a whole schema file into a declaration list.
]]
function Parser.parse(tokens: { Token }, reporter: ReporterImpl): Ast.File
	local state: State = { tokens = tokens, pos = 1, reporter = reporter }
	local decls: { Decl } = {} :: { Ast.Decl }

	while peek(state).kind ~= "eof" do
		local keyword = peek(state)

		if keyword.kind ~= "ident" then
			reporter:fatal({
				message = `expected a declaration, found {describe(keyword)}`,
				span = keyword.span,
				label = "not a declaration",
				help = "declarations start with `event`, `unreliable`, `request`, `channel`, `struct`, `enum` or `config`",
			})
		end
		advance(state)

		if keyword.text == "config" then
			table.insert(decls, parseConfig(state, keyword))
		elseif keyword.text == "enum" then
			table.insert(decls, parseEnum(state, keyword))
		elseif keyword.text == "struct" then
			local name = expectIdent(state, "a struct name")
			local fields = parseFields(state, `after struct '{name.text}'`)
			table.insert(decls, {
				kind = "struct",
				name = name.text,
				fields = fields,
				span = keyword.span,
				nameSpan = name.span,
			})
		elseif keyword.text == "event" or keyword.text == "unreliable" then
			local name = expectIdent(state, "an event name")
			local mods = parseModifiers(state)
			rejectPriority(state, mods, "events")
			local from = requireDirection(state, mods, keyword.text, name)
			local fields = parseFields(state, `after event '{name.text}'`)

			table.insert(decls, {
				kind = "event",
				name = name.text,
				from = from,
				reliable = keyword.text == "event",
				rate = mods.rate,
				fields = fields,
				span = keyword.span,
				nameSpan = name.span,
			})
		elseif keyword.text == "request" then
			local name = expectIdent(state, "a request name")
			local mods = parseModifiers(state)
			rejectPriority(state, mods, "requests")
			local from = requireDirection(state, mods, "request", name)
			local fields = parseFields(state, `after request '{name.text}'`)

			if not matchPunct(state, "->") then
				reporter:fatal({
					message = `request '{name.text}' is missing its reply`,
					span = name.span,
					label = "no `->` after the argument list",
					help = `write \`request {name.text} from {from} \{ ... } -> \{ ok: bool }\``,
				})
			end
			local reply = parseFields(state, `after '->' in request '{name.text}'`)

			table.insert(decls, {
				kind = "request",
				name = name.text,
				from = from,
				rate = mods.rate,
				fields = fields,
				reply = reply,
				span = keyword.span,
				nameSpan = name.span,
			})
		elseif keyword.text == "channel" then
			local name = expectIdent(state, "a channel name")
			local mods = parseModifiers(state)

			if mods.from ~= nil then
				reporter:fatal({
					message = "channels do not take a direction",
					span = name.span,
					help = "channels always replicate server to client — the server owns authoritative state",
				})
			end

			local fields = parseFields(state, `after channel '{name.text}'`)
			table.insert(decls, {
				kind = "channel",
				name = name.text,
				priority = mods.priority or "normal",
				fields = fields,
				span = keyword.span,
				nameSpan = name.span,
			})
		else
			local suggestion = Diagnostics.suggest(keyword.text, DECL_KEYWORDS)
			reporter:fatal({
				message = `unknown declaration '{keyword.text}'`,
				span = keyword.span,
				label = "not a declaration keyword",
				help = if suggestion
					then `did you mean '{suggestion}'?`
					else "expected `event`, `unreliable`, `request`, `channel`, `struct`, `enum` or `config`",
			})
		end
	end

	return { decls = decls }
end

--[[
	Convenience wrapper: source text straight to an AST.
]]
function Parser.parseSource(file: string, source: string): (Ast.File, Diagnostics.ReporterImpl)
	local reporter = Diagnostics.new(file, source)
	local tokens = Lexer.tokenise(source, reporter)
	return Parser.parse(tokens, reporter), reporter
end

return Parser
