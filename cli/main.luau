--!strict
--[[
	BTYN schema compiler.

	    lune run cli/main -- net.btyn

	Output paths come from the schema's own `config` block, so the command line
	stays a single argument and the schema remains the one source of truth.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Analyze = require("./Analyze")
local Diagnostics = require("./Diagnostics")
local Luau = require("./emit/Luau")
local Parser = require("./Parser")

local USAGE = [[
btyn — networking schema compiler

  lune run cli/main -- <schema.btyn> [--check] [--watch] [--json]

  --check   validate the schema and report sizes without writing any files
  --watch   recompile whenever the schema changes
  --json    emit machine-readable diagnostics and packet data, write nothing
]]

-- How often watch mode restats the schema. Fast enough to feel immediate when
-- alt-tabbing back to Studio, cheap enough to ignore.
local WATCH_INTERVAL = 0.3

--[[
	Creates every missing directory along a path.
]]
local function ensureDirectory(path: string)
	local normalised = string.gsub(path, "\\", "/")
	local parts = string.split(normalised, "/")
	table.remove(parts)

	-- An absolute path starts with an empty segment. Dropping it silently would
	-- turn `/opt/game/Net.luau` into a `./opt` directory beside the schema.
	local built = if string.sub(normalised, 1, 1) == "/" then "/" else ""

	for _, part in parts do
		if part == "" then
			continue
		end
		built = if built == "" or built == "/" then built .. part else `{built}/{part}`
		if not fs.isDir(built) then
			fs.writeDir(built)
		end
	end
end

local function fail(message: string): never
	print(message)
	process.exit(1)
	error("unreachable")
end

local function pad(text: string, width: number): string
	return text .. string.rep(" ", math.max(width - #text, 0))
end

--[[
	Human-readable size for a body: exact when the layout is fixed, a range when
	a string or array makes it vary.
]]
local function describeSize(body: Analyze.Body): string
	if body.fixed then
		return `{body.size} B`
	end
	return `{body.size}-{body.maxSize} B`
end

--[[
	Parses and analyses, returning the schema or the bail describing why not.
]]
local function attempt(path: string): (Analyze.Schema?, any, Diagnostics.ReporterImpl?)
	local source = fs.readFile(path)
	local captured: Diagnostics.ReporterImpl? = nil

	local ok, result = pcall(function()
		local file, reporter = Parser.parseSource(path, source)
		captured = reporter
		return Analyze.run(file, reporter)
	end)

	if ok then
		return result :: Analyze.Schema, nil, captured
	end
	if Diagnostics.isBail(result) then
		return nil, result, captured
	end

	error(result, 0)
end

--[[
	Parses and analyses. Returns nil after printing diagnostics, so watch mode
	can report an error and keep going rather than exiting.

	Warnings are printed on the way past: the schema compiled, but something in
	it will bite at runtime.
]]
local function compile(path: string): Analyze.Schema?
	local schema, bail, reporter = attempt(path)

	if reporter then
		local warnings = (reporter :: Diagnostics.ReporterImpl):renderWarnings()
		if warnings then
			print(warnings)
			print("")
		end
	end

	if schema then
		return schema
	end

	print((bail :: any).rendered)
	return nil
end

--[[
	Machine-readable output for editors and tooling.

	An editor should consume structured data, not scrape the rendered
	diagnostics back apart — the pretty output exists for humans and is free to
	change shape.
]]
local function emitJson(path: string)
	local schema, bail, reporter = attempt(path)

	--[[
		Both severities share one shape, so an editor can render them from a
		single list and colour by `severity`.
	]]
	local function encode(diag: Diagnostics.Diagnostic, severity: string)
		local span = diag.span
		return {
			severity = severity,
			message = diag.message,
			label = diag.label,
			help = diag.help,
			-- One-based, matching what editors expect to be handed.
			line = if span then span.line else 1,
			column = if span then span.col else 1,
			length = if span then span.len else 1,
		}
	end

	local warnings = {}
	if reporter then
		for _, diag in (reporter :: Diagnostics.ReporterImpl).warnings do
			table.insert(warnings, encode(diag, "warning"))
		end
	end

	if not schema then
		local diagnostics = {}
		for _, diag in (bail :: any).diagnostics :: { Diagnostics.Diagnostic } do
			table.insert(diagnostics, encode(diag, "error"))
		end

		print(serde.encode("json", { ok = false, diagnostics = diagnostics, warnings = warnings }))
		return
	end

	local found = schema :: Analyze.Schema
	local packets = {}

	for _, packet in found.packets do
		table.insert(packets, {
			name = packet.name,
			kind = packet.kind,
			from = packet.from,
			reliable = packet.reliable,
			priority = packet.priority,
			rate = packet.rate,
			opcode = packet.opcode,
			replyOpcode = packet.replyOpcode,
			removeOpcode = packet.removeOpcode,
			size = packet.body.size,
			maxSize = packet.body.maxSize,
			fixed = packet.body.fixed,
			replySize = if packet.reply then (packet.reply :: Analyze.Body).size else nil,
			replyMaxSize = if packet.reply then (packet.reply :: Analyze.Body).maxSize else nil,
			line = packet.nameSpan.line,
		})
	end

	print(serde.encode("json", {
		ok = true,
		diagnostics = {},
		warnings = warnings,
		packets = packets,
		opcodeBytes = found.opcodeBytes,
		unreliableCap = found.config.unreliableCap,
		budget = found.config.budget,
	}))
end

local function report(path: string, schema: Analyze.Schema)
	print(`btyn: {path} is valid — {#schema.packets} packet(s), {schema.opcodeBytes} byte opcodes\n`)

	for _, packet in schema.packets do
		local opcodes = tostring(packet.opcode)
		if packet.replyOpcode then
			opcodes ..= `,{packet.replyOpcode}`
		elseif packet.removeOpcode then
			opcodes ..= `,{packet.removeOpcode}`
		end

		local kind: string
		if packet.kind == "event" then
			kind = if packet.reliable then "event" else "unreliable"
		elseif packet.kind == "channel" then
			kind = `channel/{packet.priority}`
		else
			kind = "request"
		end

		local arrow = if packet.from == "client" then "client -> server" else "server -> client"
		local size = describeSize(packet.body)
		if packet.reply then
			size ..= ` -> {describeSize(packet.reply :: Analyze.Body)}`
		end

		local rate = if packet.rate then `  rate {packet.rate}/s` else ""
		print(`  [{pad(opcodes, 5)}] {pad(packet.name, 14)} {pad(kind, 14)} {pad(arrow, 17)} {size}{rate}`)
	end

	-- The headline number: how close the largest unreliable packet sits to the
	-- cap the engine silently drops things at.
	local widest = 0
	for _, packet in schema.packets do
		if not packet.reliable then
			widest = math.max(widest, schema.opcodeBytes + packet.body.maxSize)
		end
	end
	if widest > 0 then
		print(`\n  largest unreliable packet: {widest} B of the {schema.config.unreliableCap} B cap`)
	end
end

local function write(schema: Analyze.Schema)
	ensureDirectory(schema.config.server)
	ensureDirectory(schema.config.client)
	fs.writeFile(schema.config.server, Luau.emitServer(schema))
	fs.writeFile(schema.config.client, Luau.emitClient(schema))

	print(`btyn: wrote {schema.config.server}`)
	print(`btyn: wrote {schema.config.client}`)
end

local args = process.args
local schemaPath: string? = nil
local checkOnly = false
local watch = false
local json = false

for _, arg in args do
	if arg == "--" then
		-- Separator from the `lune run cli/main -- schema.btyn` form.
		continue
	elseif arg == "--check" then
		checkOnly = true
	elseif arg == "--watch" then
		watch = true
	elseif arg == "--json" then
		json = true
	elseif arg == "--help" or arg == "-h" then
		print(USAGE)
		process.exit(0)
	elseif string.sub(arg, 1, 2) == "--" then
		fail(`unknown flag '{arg}'\n{USAGE}`)
	else
		schemaPath = arg
	end
end

if not schemaPath then
	fail(USAGE)
end

local path = schemaPath :: string
if not fs.isFile(path) then
	if json then
		-- Still valid JSON, so a caller never has to special-case this.
		print(serde.encode("json", {
			ok = false,
			diagnostics = {
				{ severity = "error", message = `no such file '{path}'`, line = 1, column = 1, length = 1 },
			},
		}))
		process.exit(0)
	end
	fail(`btyn: no such file '{path}'`)
end

if json then
	emitJson(path)
	process.exit(0)
end

if not watch then
	local schema = compile(path)
	if not schema then
		process.exit(1)
	end

	if checkOnly then
		report(path, schema :: Analyze.Schema)
	else
		write(schema :: Analyze.Schema)
	end
	process.exit(0)
end

--[[
	Watch mode.

	A build step is the honest cost of compiling a schema; this is what makes it
	invisible while you work. Leave it running beside `rojo serve` and the
	generated modules track the schema on save.

	A failed compile prints and keeps watching — losing the loop on a typo would
	defeat the point.
]]
print(`btyn: watching {path} — ctrl-c to stop`)

local lastModified: number? = nil

while true do
	local metadata = fs.metadata(path)

	if not metadata.exists then
		-- Editors often delete and recreate on save; wait for it to come back.
		task.wait(WATCH_INTERVAL)
		continue
	end

	local modified = (metadata :: any).modifiedAt
	local stamp = if typeof(modified) == "number" then modified else (modified :: any).unixTimestampMillis

	if stamp ~= lastModified then
		lastModified = stamp

		local schema = compile(path)
		if schema then
			if checkOnly then
				report(path, schema :: Analyze.Schema)
			else
				write(schema :: Analyze.Schema)
			end
		end
		print("")
	end

	task.wait(WATCH_INTERVAL)
end
