--!strict
--[[
	Turns a parsed file into the schema the emitter consumes.

	Responsibilities:
	  * collect struct/enum symbols and reject duplicates
	  * read and validate `config`
	  * assign opcodes deterministically
	  * resolve and lay out every packet body
	  * reject unreliable packets that cannot fit the engine's payload cap

	That last one is the point of having a compiler at all. The engine drops an
	oversized unreliable payload silently, which is the nastiest failure mode in
	the whole survey: no error, no warning, just a packet that never arrives.
	Knowing every packet's worst-case size at build time turns that into a
	compile error with the exact byte count.
]]

local Ast = require("./Ast")
local Diagnostics = require("./Diagnostics")
local Resolve = require("./Resolve")

type Span = Diagnostics.Span
type ReporterImpl = Diagnostics.ReporterImpl

local Analyze = {}

export type Body = {
	fields: { Resolve.ResolvedField },
	size: number,
	maxSize: number,
	fixed: boolean,
	bitfieldBytes: number,
	usesRefs: boolean,
}

export type Packet = {
	name: string,
	kind: "event" | "request" | "channel",
	from: Ast.Direction,
	reliable: boolean,
	rate: number?,
	priority: Ast.Priority?,
	body: Body,
	-- requests only
	reply: Body?,
	-- primary opcode; requests also get `replyOpcode`, channels `removeOpcode`
	opcode: number,
	replyOpcode: number?,
	removeOpcode: number?,
	span: Span,
	nameSpan: Span,
}

export type Config = {
	server: string,
	client: string,
	types: string?,
	typescript: boolean,
	budget: number,
	unreliableCap: number,
	manual: boolean,
	-- Ceiling on packets in one received batch, enforced server-side. The
	-- smallest packet is a single opcode byte, so without this a client can
	-- turn one payload into tens of thousands of handler calls in a frame.
	maxPacketsPerBatch: number,
	-- Luau expression the generated files use to reach the BTYN runtime.
	runtime: string,
	-- Where the two remotes live, as a `/`-separated path under
	-- ReplicatedStorage. Points at an existing framework folder when the
	-- project would rather not carry a stray instance at the root.
	remotes: string,
	-- Seconds before an unanswered request gives up.
	requestTimeout: number,
	-- Validate on the way out as well as on the way in. On by default: writing
	-- 300 into a u8 silently truncates to 44, and finding that at the far end
	-- of a network hop is miserable. Turn it off once a build is proven.
	writeChecks: boolean,
}

export type Schema = {
	config: Config,
	packets: { Packet },
	enums: { Ast.EnumDecl },
	structs: { [string]: Resolve.Resolved },
	-- 1 while the schema fits in 255 opcodes, otherwise 2
	opcodeBytes: number,
	usesRefs: boolean,
}

local CONFIG_KEYS = {
	"server",
	"client",
	"types",
	"typescript",
	"budget",
	"unreliable_cap",
	"max_packets_per_batch",
	"manual",
	"runtime",
	"remotes",
	"write_checks",
	"request_timeout",
}

local DEFAULT_RUNTIME = 'game:GetService("ReplicatedStorage"):WaitForChild("BTYN")'

local DEFAULT_REMOTES = "BTYN"

--[[
	Conservative default for the UnreliableRemoteEvent payload cap.

	Roblox does not publish this number; community measurement puts it near
	1000 bytes. Undershooting costs a few bytes per packet, overshooting costs
	silent data loss, so the default sits well below the reported figure and is
	overridable via `unreliable_cap` once measured on a real place.
]]
local DEFAULT_UNRELIABLE_CAP = 800

-- Soft per-client outbound budget in bytes/second. The engine starts throttling
-- around 50 KB/s, and that ceiling is shared with character and physics
-- replication, so only part of it is ours to spend.
local DEFAULT_BUDGET = 40000

-- Packets one received batch may carry. A client sending more than this in a
-- single frame is not playing the game: a busy frame of ordinary input is a
-- handful of packets, and the server's own batches are not subject to this.
local DEFAULT_MAX_PACKETS_PER_BATCH = 256

local function defaultConfig(): Config
	return {
		server = "",
		client = "",
		types = nil,
		typescript = false,
		budget = DEFAULT_BUDGET,
		unreliableCap = DEFAULT_UNRELIABLE_CAP,
		maxPacketsPerBatch = DEFAULT_MAX_PACKETS_PER_BATCH,
		manual = false,
		runtime = DEFAULT_RUNTIME,
		remotes = DEFAULT_REMOTES,
		writeChecks = true,
		requestTimeout = 10,
	}
end

local function expectType(reporter: ReporterImpl, entry: Ast.ConfigEntry, expected: string): boolean
	if type(entry.value) == expected then
		return true
	end
	reporter:add({
		message = `config key '{entry.key}' expects a {expected}, got a {type(entry.value)}`,
		span = entry.valueSpan,
		label = `expected a {expected}`,
	})
	return false
end

--[[
	Numeric config keys are all sizes and durations. Zero or negative makes the
	generated runtime quietly nonsensical — a zero `unreliable_cap` flushes on
	every packet, a zero `budget` starves every non-high channel forever — so it
	is rejected here rather than discovered in Studio.
]]
local function expectPositive(reporter: ReporterImpl, entry: Ast.ConfigEntry, help: string): boolean
	if not expectType(reporter, entry, "number") then
		return false
	end
	if (entry.value :: number) > 0 then
		return true
	end
	reporter:add({
		message = `config key '{entry.key}' must be greater than zero, got {entry.value}`,
		span = entry.valueSpan,
		label = "not a usable value",
		help = help,
	})
	return false
end

local function readConfig(decls: { Ast.Decl }, reporter: ReporterImpl): Config
	local config = defaultConfig()
	local seenBlock = false

	for _, decl in decls do
		if decl.kind ~= "config" then
			continue
		end
		local configDecl = decl :: Ast.ConfigDecl

		if seenBlock then
			reporter:add({
				message = "duplicate `config` block",
				span = configDecl.span,
				label = "already configured above",
				help = "merge the keys into a single `config` block",
			})
			continue
		end
		seenBlock = true

		for _, entry in configDecl.entries do
			if entry.key == "server" then
				if expectType(reporter, entry, "string") then
					config.server = entry.value :: string
				end
			elseif entry.key == "client" then
				if expectType(reporter, entry, "string") then
					config.client = entry.value :: string
				end
			elseif entry.key == "types" then
				if expectType(reporter, entry, "string") then
					config.types = entry.value :: string
				end
			elseif entry.key == "typescript" then
				if expectType(reporter, entry, "boolean") then
					config.typescript = entry.value :: boolean
					if config.typescript then
						-- Better to fail than to accept the flag and quietly
						-- emit nothing, leaving a roblox-ts build to discover
						-- the missing declarations later.
						reporter:add({
							message = "`typescript` output is not implemented yet",
							span = entry.span,
							label = "not supported",
							help = "remove this key; the generated Luau is fully typed and usable from Luau today",
						})
					end
				end
			elseif entry.key == "budget" then
				if expectPositive(reporter, entry, "this is the per-client outbound allowance in bytes per second") then
					config.budget = entry.value :: number
				end
			elseif entry.key == "unreliable_cap" then
				if expectPositive(reporter, entry, "this is the UnreliableRemoteEvent payload cap in bytes; measure it on a real place before raising it") then
					config.unreliableCap = entry.value :: number
				end
			elseif entry.key == "max_packets_per_batch" then
				if expectPositive(reporter, entry, "this is how many packets one received batch may carry before the sender is refused") then
					config.maxPacketsPerBatch = entry.value :: number
				end
			elseif entry.key == "manual" then
				if expectType(reporter, entry, "boolean") then
					config.manual = entry.value :: boolean
				end
			elseif entry.key == "runtime" then
				if expectType(reporter, entry, "string") then
					config.runtime = entry.value :: string
				end
			elseif entry.key == "remotes" then
				if expectType(reporter, entry, "string") then
					config.remotes = entry.value :: string
				end
			elseif entry.key == "write_checks" then
				if expectType(reporter, entry, "boolean") then
					config.writeChecks = entry.value :: boolean
				end
			elseif entry.key == "request_timeout" then
				if expectPositive(reporter, entry, "this is how many seconds a caller waits before giving up") then
					config.requestTimeout = entry.value :: number
				end
			else
				local suggestion = Diagnostics.suggest(entry.key, CONFIG_KEYS)
				reporter:add({
					message = `unknown config key '{entry.key}'`,
					span = entry.span,
					label = "not a config key",
					help = if suggestion
						then `did you mean '{suggestion}'?`
						else `known keys: {table.concat(CONFIG_KEYS, ", ")}`,
				})
			end
		end
	end

	if config.server == "" then
		reporter:add({
			message = "config is missing an output path for the server",
			help = 'add `config { server = "src/Server/Net.luau", client = "src/Client/Net.luau" }`',
		})
	end
	if config.client == "" then
		reporter:add({
			message = "config is missing an output path for the client",
			help = 'add `config { server = "src/Server/Net.luau", client = "src/Client/Net.luau" }`',
		})
	end

	return config
end

--[[
	Builds the struct/enum symbol tables and reports name collisions.
]]
local function collectSymbols(decls: { Ast.Decl }, reporter: ReporterImpl): Resolve.Symbols
	local structs: { [string]: Ast.StructDecl } = {}
	local enums: { [string]: Ast.EnumDecl } = {}
	local seen: { [string]: Span } = {}

	for _, decl in decls do
		local named = decl :: any
		if decl.kind ~= "struct" and decl.kind ~= "enum" then
			continue
		end

		local name = named.name :: string

		if Ast.isPrimitive(name) then
			reporter:add({
				message = `'{name}' is a built-in type`,
				span = named.nameSpan,
				label = "cannot be redefined",
				help = "pick another name for your type",
			})
			continue
		end

		local previous = seen[name]
		if previous then
			reporter:add({
				message = `'{name}' is declared twice`,
				span = named.nameSpan,
				label = "duplicate declaration",
				help = `first declared on line {previous.line}`,
			})
			continue
		end
		seen[name] = named.nameSpan

		if decl.kind == "struct" then
			structs[name] = decl :: Ast.StructDecl
		else
			local enumDecl = decl :: Ast.EnumDecl
			local seenVariants: { [string]: boolean } = {}
			for _, variant in enumDecl.variants do
				if seenVariants[variant] then
					reporter:add({
						message = `enum '{name}' repeats variant '{variant}'`,
						span = enumDecl.nameSpan,
						label = "duplicate variant",
					})
				end
				seenVariants[variant] = true
			end
			enums[name] = enumDecl
		end
	end

	return {
		structs = structs,
		enums = enums,
		resolving = {},
		cache = {},
		reporter = reporter,
	}
end

local function checkDuplicateFields(fields: { Ast.Field }, owner: string, reporter: ReporterImpl)
	local seen: { [string]: Span } = {}
	for _, field in fields do
		local previous = seen[field.name]
		if previous then
			reporter:add({
				message = `'{owner}' has two fields named '{field.name}'`,
				span = field.span,
				label = "duplicate field",
				help = `first declared on line {previous.line}`,
			})
		end
		seen[field.name] = field.span
	end
end

--[[
	Resolves a field list into a laid-out body.
]]
local function buildBody(fields: { Ast.Field }, symbols: Resolve.Symbols): Body
	local resolved: { Resolve.ResolvedField } = {}
	for _, field in fields do
		table.insert(resolved, {
			name = field.name,
			type = Resolve.type(field.type, symbols),
			span = field.span,
		})
	end

	local size, maxSize, fixed, bitfieldBytes = Resolve.layoutFields(resolved)

	local usesRefs = false
	for _, field in resolved do
		if field.type.usesRefs then
			usesRefs = true
			break
		end
	end

	return {
		fields = resolved,
		size = size,
		maxSize = maxSize,
		fixed = fixed,
		bitfieldBytes = bitfieldBytes,
		usesRefs = usesRefs,
	}
end

--[[
	Runs the full analysis. Raises a Diagnostics bail if anything is wrong.
]]
function Analyze.run(file: Ast.File, reporter: ReporterImpl): Schema
	local config = readConfig(file.decls, reporter)
	local symbols = collectSymbols(file.decls, reporter)

	-- Duplicate packet names, checked before resolution so the error list is
	-- about names rather than a cascade of type errors.
	local seenPackets: { [string]: Span } = {}
	local packetDecls: { any } = {}

	for _, decl in file.decls do
		if decl.kind ~= "event" and decl.kind ~= "request" and decl.kind ~= "channel" then
			continue
		end
		local named = decl :: any

		local previous = seenPackets[named.name]
		if previous then
			reporter:add({
				message = `'{named.name}' is declared twice`,
				span = named.nameSpan,
				label = "duplicate packet",
				help = `first declared on line {previous.line}`,
			})
			continue
		end
		seenPackets[named.name] = named.nameSpan

		checkDuplicateFields(named.fields, named.name, reporter)
		if decl.kind == "request" then
			checkDuplicateFields((decl :: Ast.RequestDecl).reply, `{named.name}`, reporter)
		end
		if decl.kind == "channel" and #named.fields == 0 then
			reporter:add({
				message = `channel '{named.name}' has no fields`,
				span = named.nameSpan,
				label = "nothing to replicate",
				help = "a channel exists to replicate state; give it at least one field",
			})
		end

		-- The dirty mask is a single store, so a channel is capped at 32
		-- fields. Splitting is also better design: a 40-field channel almost
		-- always contains groups that change at very different rates, and
		-- separate channels let each carry its own priority.
		if decl.kind == "channel" and #named.fields > 32 then
			reporter:add({
				message = `channel '{named.name}' has {#named.fields} fields, over the limit of 32`,
				span = named.nameSpan,
				label = "too many fields",
				help = "split it into several channels — fields that change at different rates want different priorities anyway",
			})
		end

		table.insert(packetDecls, decl)
	end

	reporter:bailIfErrors()

	-- Sorted by name so reordering declarations in the file does not churn the
	-- generated output. Both sides are emitted from this same run, so any stable
	-- assignment is correct — there is no handshake to get out of sync.
	table.sort(packetDecls, function(a, b)
		return a.name < b.name
	end)

	local packets: { Packet } = {}
	local nextOpcode = 0
	local usesRefs = false

	for _, decl in packetDecls do
		-- One bail per packet, so a type error in one does not hide the rest.
		local ok, err = pcall(function()
			local body = buildBody(decl.fields, symbols)
			local reply: Body? = if decl.kind == "request" then buildBody(decl.reply, symbols) else nil

			-- A channel delta has no bitfield, so an optional of a fixed type
			-- has nowhere to put its presence bit — the wire format cannot
			-- express it. Optionals of dynamic types spend a presence byte
			-- instead and are fine.
			if decl.kind == "channel" then
				for _, field in body.fields do
					if field.type.kind == "optional" and field.type.fixed then
						reporter:add({
							message = `channel '{decl.name}' field '{field.name}' is an optional of a fixed-size type`,
							span = field.span,
							label = "not representable in a delta",
							help = "wrap it in a struct — `struct Slot { value: u16? }` — which carries its own presence bit, or use a sentinel value",
						})
					end
				end
			end

			local packet: Packet = {
				name = decl.name,
				kind = decl.kind,
				from = if decl.kind == "channel" then "server" else decl.from,
				reliable = if decl.kind == "event" then decl.reliable else true,
				rate = decl.rate,
				priority = decl.priority,
				body = body,
				reply = reply,
				opcode = nextOpcode,
				span = decl.span,
				nameSpan = decl.nameSpan,
			}
			nextOpcode += 1

			if decl.kind == "request" then
				packet.replyOpcode = nextOpcode
				nextOpcode += 1
			elseif decl.kind == "channel" then
				packet.removeOpcode = nextOpcode
				nextOpcode += 1
			end

			if body.usesRefs or (reply and reply.usesRefs) then
				usesRefs = true
			end

			table.insert(packets, packet)
		end)

		if not ok then
			if Diagnostics.isBail(err) then
				-- Carry the inner diagnostics across with their spans intact,
				-- rather than folding the rendered text into a span-less
				-- message. The CLI then prints a proper source snippet, and an
				-- editor has somewhere to put the squiggle.
				for _, inner in (err :: any).diagnostics :: { Diagnostics.Diagnostic } do
					reporter:add({
						message = `{inner.message} (in {decl.kind} '{decl.name}')`,
						span = inner.span,
						label = inner.label,
						help = inner.help,
					})
				end
			else
				error(err, 0)
			end
		end
	end

	reporter:bailIfErrors()

	-- The opcode is the first byte of every packet. Opcodes start at zero, so
	-- one byte covers 256 of them; past that every opcode widens to two rather
	-- than paying for an escape-code branch on the hot path.
	local opcodeBytes = if nextOpcode <= 256 then 1 else 2

	for _, packet in packets do
		if packet.reliable then
			continue
		end

		local wireSize = opcodeBytes + packet.body.maxSize
		if wireSize > config.unreliableCap then
			reporter:add({
				message = `unreliable event '{packet.name}' can reach {wireSize} bytes, over the {config.unreliableCap} byte cap`,
				span = packet.nameSpan,
				label = `worst case is {wireSize} bytes`,
				help = "the engine drops an oversized unreliable payload without telling you. Shrink the packet (quantise floats, cap arrays tighter), split it, or make it a reliable `event`",
			})
		end
	end

	reporter:bailIfErrors()

	-- A client-sent packet with no rate is unlimited, and nothing else in the
	-- system will notice. This is the one piece of the security checklist the
	-- compiler can actually check, so it does — as a warning, since a schema
	-- under development has every right to be incomplete.
	for _, packet in packets do
		if packet.from == "client" and packet.rate == nil then
			reporter:warn({
				message = `'{packet.name}' is sent by the client and has no rate limit`,
				span = packet.nameSpan,
				label = "no `rate` here",
				help = `add \`rate <n>\` — without one a single client can send this as fast as it likes, and only the batch ceiling of {config.maxPacketsPerBatch} packets stands in the way`,
			})
		end
	end

	local structCache: { [string]: Resolve.Resolved } = {}
	for name, resolved in symbols.cache do
		structCache[name] = resolved
	end

	local enumList: { Ast.EnumDecl } = {}
	for _, decl in file.decls do
		if decl.kind == "enum" then
			table.insert(enumList, decl :: Ast.EnumDecl)
		end
	end

	return {
		config = config,
		packets = packets,
		enums = enumList,
		structs = structCache,
		opcodeBytes = opcodeBytes,
		usesRefs = usesRefs,
	}
end

return Analyze
