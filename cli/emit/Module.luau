--!strict
--[[
	Assembles the pure codec section of the generated output.

	This part touches no Roblox API beyond the value types (Vector3, CFrame,
	Color3), which is deliberate: it means the whole serialisation layer can be
	loaded and round-tripped headlessly under Lune. The transport glue that does
	need Roblox lives in the runtime, and is kept deliberately thin.
]]

local Analyze = require("../Analyze")
local Codec = require("./Codec")
local Resolve = require("../Resolve")
local Writer = require("./Writer")

type Impl = Writer.Impl
type Resolved = Resolve.Resolved

local Module = {}

--[[
	Luau type expression for a resolved type, so the generated file carries real
	types rather than `any`. This is what the IDL buys over a runtime schema:
	Luau has no mapped types, so a table-based schema cannot infer its own
	payload type — a compiler just writes it out.
]]
local function luauType(ty: Resolved): string
	if ty.kind == "bool" then
		return "boolean"
	elseif ty.kind == "string" then
		return "string"
	elseif ty.kind == "instance" then
		return "Instance"
	elseif ty.kind == "optional" then
		return `{luauType(ty.of :: Resolved)}?`
	elseif ty.kind == "array" then
		return `\{ {luauType(ty.of :: Resolved)} }`
	elseif ty.kind == "struct" then
		return ty.name :: string
	elseif ty.kind == "enum" then
		local parts = {}
		for _, variant in ty.variants :: { string } do
			table.insert(parts, `"{variant}"`)
		end
		return table.concat(parts, " | ")
	end

	local name = ty.name :: string
	if name == "vec3" or name == "unit" then
		return "Vector3"
	elseif name == "cframe" then
		return "CFrame"
	elseif name == "color3" then
		return "Color3"
	end
	return "number"
end

Module.luauType = luauType

--[[
	Emits `export type Name = { ... }` for a field list.
]]
function Module.emitTypeAlias(w: Impl, name: string, fields: { Resolve.ResolvedField })
	if #fields == 0 then
		w:line(`export type {name} = \{}`)
		return
	end

	w:push(`export type {name} = \{`)
	for _, field in fields do
		w:line(`{field.name}: {luauType(field.type)},`)
	end
	w:pop("}")
end

--[[
	Emits the same shape with every field optional.

	Channels move as deltas, so `set` takes only the fields that changed and the
	client hands a handler both the merged state and the partial that arrived.
]]
function Module.emitPartialAlias(w: Impl, name: string, fields: { Resolve.ResolvedField })
	if #fields == 0 then
		w:line(`export type {name} = \{}`)
		return
	end

	w:push(`export type {name} = \{`)
	for _, field in fields do
		local inner = luauType(field.type)
		-- Already optional; a second `?` is not a type.
		w:line(`{field.name}: {if string.sub(inner, -1) == "?" then inner else inner .. "?"},`)
	end
	w:pop("}")
end

local function emitEnums(w: Impl, schema: Analyze.Schema)
	for _, enumDecl in schema.enums do
		local names = {}
		local values = {}
		for index, variant in enumDecl.variants do
			table.insert(names, `{variant} = {index}`)
			table.insert(values, `"{variant}"`)
		end
		-- Names on the wire are a byte; in Luau they stay strings, which reads
		-- far better than an opaque number at the call site.
		w:line(`local ENUM_{enumDecl.name} = \{ {table.concat(names, ", ")} }`)
		w:line(`local ENUM_{enumDecl.name}_VALUES = \{ {table.concat(values, ", ")} }`)
	end
	if #schema.enums > 0 then
		w:line()
	end
end

--[[
	Emits struct codecs in dependency order so a struct is always defined before
	whatever references it.
]]
local function emitStructs(w: Impl, schema: Analyze.Schema, options: Codec.Options)
	local emitted: { [string]: boolean } = {}

	local function visit(name: string)
		if emitted[name] then
			return
		end
		emitted[name] = true

		local resolved = schema.structs[name]
		if not resolved then
			return
		end

		for _, field in resolved.fields :: { Resolve.ResolvedField } do
			local ty = field.type
			-- Look through arrays and optionals for a nested struct dependency.
			while ty.kind == "array" or ty.kind == "optional" do
				ty = ty.of :: Resolved
			end
			if ty.kind == "struct" then
				visit(ty.name :: string)
			end
		end

		local body: Codec.Body = {
			fields = resolved.fields :: { Resolve.ResolvedField },
			size = resolved.size,
			maxSize = resolved.maxSize,
			fixed = resolved.fixed,
			bitfieldBytes = select(4, Resolve.layoutFields(resolved.fields :: { Resolve.ResolvedField })),
			usesRefs = resolved.usesRefs,
		}

		Module.emitTypeAlias(w, name, body.fields)
		w:line()

		w:push(`local function write{name}(b: buffer, o: number, v: {name}, refs: \{ Instance }): number`)
		Codec.emitWrite(w, body, options)
		w:pop("end")
		w:line()

		w:push(`local function read{name}(b: buffer, o: number, limit: number, refs: \{ Instance }?): ({name}, number)`)
		Codec.emitRead(w, body, options)
		w:pop("end")
		w:line()
	end

	local names = {}
	for name in schema.structs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		visit(name)
	end
end

export type PacketCodec = {
	packet: Analyze.Packet,
	-- "" for an event body, "Reply" for the reply half of a request
	suffix: string,
	body: Analyze.Body,
	typeName: string,
}

--[[
	The codecs one packet needs: its body, plus a reply body for a request.
]]
function Module.packetCodecs(packet: Analyze.Packet): { PacketCodec }
	local list: { PacketCodec } = {
		{
			packet = packet,
			suffix = "",
			body = packet.body,
			typeName = packet.name,
		},
	}

	if packet.reply then
		table.insert(list, {
			packet = packet,
			suffix = "Reply",
			body = packet.reply :: Analyze.Body,
			typeName = `{packet.name}Reply`,
		})
	end

	return list
end

--[[
	Every codec a schema needs, flattened: one per event, two per request.
]]
function Module.codecs(schema: Analyze.Schema): { PacketCodec }
	local list: { PacketCodec } = {}
	for _, packet in schema.packets do
		for _, codec in Module.packetCodecs(packet) do
			table.insert(list, codec)
		end
	end
	return list
end

--[[
	Emits type aliases and read/write functions for every packet.
]]
function Module.emitPackets(w: Impl, schema: Analyze.Schema, options: Codec.Options)
	for _, codec in Module.codecs(schema) do
		Module.emitTypeAlias(w, codec.typeName, codec.body.fields)
		w:line()
	end

	for _, codec in Module.codecs(schema) do
		local name = codec.typeName

		w:push(`local function write{name}(b: buffer, o: number, v: {name}, refs: \{ Instance }): number`)
		Codec.emitWrite(w, codec.body, options)
		w:pop("end")
		w:line()

		w:push(`local function read{name}(b: buffer, o: number, limit: number, refs: \{ Instance }?): ({name}, number)`)
		Codec.emitRead(w, codec.body, options)
		w:pop("end")
		w:line()
	end
end

--[[
	Emits everything both sides need regardless of direction: enum tables and
	struct codecs.
]]
function Module.emitShared(w: Impl, schema: Analyze.Schema, options: Codec.Options)
	emitEnums(w, schema)
	emitStructs(w, schema, options)
end

--[[
	Emits a self-contained codec module.

	Used directly by the round-trip tests, and as the first half of the real
	server and client outputs.
]]
function Module.emitCodecModule(schema: Analyze.Schema, options: Codec.Options): string
	local w = Writer.new()

	w:line("--!strict")
	w:line("--!native")
	w:line("-- Generated by BTYN. Do not edit.")
	w:line()

	Module.emitShared(w, schema, options)
	Module.emitPackets(w, schema, options)

	local writeEntries = {}
	local readEntries = {}
	local sizeEntries = {}
	local maxEntries = {}
	local fixedEntries = {}

	for _, codec in Module.codecs(schema) do
		local name = codec.typeName
		table.insert(writeEntries, `{name} = write{name},`)
		table.insert(readEntries, `{name} = read{name},`)
		table.insert(sizeEntries, `{name} = {codec.body.size},`)
		table.insert(maxEntries, `{name} = {codec.body.maxSize},`)
		table.insert(fixedEntries, `{name} = {tostring(codec.body.fixed)},`)
	end

	local function emitTable(label: string, entries: { string })
		w:push(`{label} = \{`)
		for _, entry in entries do
			w:line(entry)
		end
		w:pop("},")
	end

	w:push("return {")
	emitTable("write", writeEntries)
	emitTable("read", readEntries)
	emitTable("size", sizeEntries)
	emitTable("maxSize", maxEntries)
	emitTable("fixed", fixedEntries)
	w:pop("}")
	w:line()

	return w:build()
end

return Module
