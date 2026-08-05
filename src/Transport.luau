--!strict
--[[
	The wire.

	Two RemoteEvent instances for the entire game — one reliable, one
	unreliable — in both directions. That single decision is what buys most of
	the win described in the survey:

	  * ~9 bytes of per-call overhead is paid twice a frame instead of once per
	    message, so a hundred small messages stop costing ~900 bytes of headers
	  * the ~500 requests/second client rate limit stops being reachable by
	    ordinary gameplay traffic
	  * an exploiter enumerating RemoteEvents finds two opaque endpoints rather
	    than eighty helpfully-named ones

	Packets accumulate in per-player streams and go out once per frame on
	Heartbeat, or on demand when `manual` is set.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Stream = require(script.Parent.Stream)

local Transport = {}

type StreamType = Stream.Stream

export type Config = {
	opcodeBytes: number,
	unreliableCap: number,
	budget: number,
	manual: boolean,
}

export type Handler = (player: Player?, b: buffer, offset: number, limit: number, refs: { Instance }?) -> number

local REMOTE_FOLDER = "BTYN"
local RELIABLE_NAME = "R"
local UNRELIABLE_NAME = "U"

--[[
	Finds or creates the two remotes.

	The server creates them; the client waits. Names are deliberately
	uninformative — there is nothing to learn from reading them.
]]
local function resolveRemotes(): (RemoteEvent, UnreliableRemoteEvent)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = REMOTE_FOLDER
			folder.Parent = ReplicatedStorage
		end

		local reliable = folder:FindFirstChild(RELIABLE_NAME) :: RemoteEvent?
		if not reliable then
			reliable = Instance.new("RemoteEvent")
			;(reliable :: RemoteEvent).Name = RELIABLE_NAME
			;(reliable :: RemoteEvent).Parent = folder
		end

		local unreliable = folder:FindFirstChild(UNRELIABLE_NAME) :: UnreliableRemoteEvent?
		if not unreliable then
			unreliable = Instance.new("UnreliableRemoteEvent")
			;(unreliable :: UnreliableRemoteEvent).Name = UNRELIABLE_NAME
			;(unreliable :: UnreliableRemoteEvent).Parent = folder
		end

		return reliable :: RemoteEvent, unreliable :: UnreliableRemoteEvent
	end

	local folder = ReplicatedStorage:WaitForChild(REMOTE_FOLDER)
	return folder:WaitForChild(RELIABLE_NAME) :: RemoteEvent, folder:WaitForChild(UNRELIABLE_NAME) :: UnreliableRemoteEvent
end

export type Endpoint = {
	config: Config,
	reliable: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
	handlers: { [number]: Handler },
	-- server: keyed by player; client: a single pair under the `false` key
	reliableStreams: { [any]: StreamType },
	unreliableStreams: { [any]: StreamType },
	-- serialise-once staging for broadcasts
	scratch: StreamType,
	onAbuse: ((player: Player?, reason: string) -> ())?,
	-- Runs immediately before every flush. Channels use it to write their
	-- deltas into the batches that this same flush is about to send; two
	-- independent Heartbeat connections would have no defined order between
	-- them and would cost a frame of latency half the time.
	beforeFlush: (() -> ())?,
	isServer: boolean,
	connections: { RBXScriptConnection },
}

local function newEndpoint(config: Config): Endpoint
	local reliable, unreliable = resolveRemotes()
	return {
		config = config,
		reliable = reliable,
		unreliable = unreliable,
		handlers = {},
		reliableStreams = {},
		unreliableStreams = {},
		scratch = Stream.new(),
		onAbuse = nil,
		beforeFlush = nil,
		isServer = RunService:IsServer(),
		connections = {},
	}
end

--[[
	Walks a received batch, handing each packet to its registered reader.

	The whole batch runs inside one pcall. A malformed packet means the rest of
	the batch cannot be located either — offsets are only meaningful in
	sequence — so the remainder is dropped and the sender reported. For a
	legitimate client this never happens: the same compiler wrote both sides.
]]
local function consume(endpoint: Endpoint, player: Player?, payload: buffer, refs: { Instance }?)
	local limit = buffer.len(payload)
	local opcodeBytes = endpoint.config.opcodeBytes
	local cursor = 0

	local ok, err = pcall(function()
		while cursor < limit do
			if cursor + opcodeBytes > limit then
				error("btyn: truncated opcode", 0)
			end

			local opcode = if opcodeBytes == 1
				then buffer.readu8(payload, cursor)
				else buffer.readu16(payload, cursor)
			cursor += opcodeBytes

			local handler = endpoint.handlers[opcode]
			if not handler then
				error(`btyn: unknown opcode {opcode}`, 0)
			end

			cursor += handler(player, payload, cursor, limit, refs)
		end
	end)

	if not ok and endpoint.onAbuse then
		(endpoint.onAbuse :: any)(player, tostring(err))
	end
end

local function streamFor(endpoint: Endpoint, key: any, reliable: boolean): StreamType
	local table_ = if reliable then endpoint.reliableStreams else endpoint.unreliableStreams
	local stream = table_[key]
	if not stream then
		stream = Stream.new()
		table_[key] = stream
	end
	return stream
end

--[[
	Sends one stream's contents and clears it.
]]
local function flushStream(endpoint: Endpoint, key: any, stream: StreamType, reliable: boolean)
	if Stream.isEmpty(stream) then
		return
	end

	local payload, refs = Stream.take(stream)

	if endpoint.isServer then
		local player = key :: Player
		if reliable then
			endpoint.reliable:FireClient(player, payload, refs)
		else
			endpoint.unreliable:FireClient(player, payload, refs)
		end
	else
		if reliable then
			endpoint.reliable:FireServer(payload, refs)
		else
			endpoint.unreliable:FireServer(payload, refs)
		end
	end
end

function Transport.flush(endpoint: Endpoint)
	if endpoint.beforeFlush then
		(endpoint.beforeFlush :: any)()
	end

	for key, stream in endpoint.reliableStreams do
		flushStream(endpoint, key, stream, true)
	end
	for key, stream in endpoint.unreliableStreams do
		flushStream(endpoint, key, stream, false)
	end
end

--[[
	Reserves room for a packet in a stream.

	An unreliable batch that would cross the payload cap is flushed first and
	the packet starts a fresh one. The engine discards an oversized unreliable
	payload silently, so this boundary is enforced rather than hoped for. The
	compiler has already proved that no single packet exceeds the cap on its
	own, which is what makes splitting here always sufficient.
]]
function Transport.reserve(endpoint: Endpoint, key: any, reliable: boolean, bytes: number): (buffer, number, StreamType)
	local stream = streamFor(endpoint, key, reliable)

	if not reliable and stream.cursor + bytes > endpoint.config.unreliableCap then
		flushStream(endpoint, key, stream, false)
	end

	local buf, offset = Stream.begin(stream, bytes)
	return buf, offset, stream
end

function Transport.setHandler(endpoint: Endpoint, opcode: number, handler: Handler)
	endpoint.handlers[opcode] = handler
end

--[[
	Copies an already-serialised packet into each recipient's batch.

	The packet is encoded once into `endpoint.scratch` and then memcpy'd, so a
	broadcast to forty players costs one serialisation and forty copies rather
	than forty serialisations. Unlike FireAllClients this still lets the caller
	choose the recipients, which is what makes interest management possible.
]]
function Transport.fanout(endpoint: Endpoint, recipients: { Player }, reliable: boolean)
	local scratch = endpoint.scratch
	local length = scratch.cursor
	if length == 0 then
		return
	end

	for _, player in recipients do
		local stream = streamFor(endpoint, player, reliable)
		if not reliable and stream.cursor + length > endpoint.config.unreliableCap then
			flushStream(endpoint, player, stream, false)
		end
		Stream.append(stream, scratch)
	end
end

--[[
	Fan-out to everyone, optionally skipping one player.
]]
function Transport.fanoutAll(endpoint: Endpoint, reliable: boolean, except: Player?)
	local scratch = endpoint.scratch
	local length = scratch.cursor
	if length == 0 then
		return
	end

	for _, player in Players:GetPlayers() do
		if player == except then
			continue
		end
		local stream = streamFor(endpoint, player, reliable)
		if not reliable and stream.cursor + length > endpoint.config.unreliableCap then
			flushStream(endpoint, player, stream, false)
		end
		Stream.append(stream, scratch)
	end
end

--[[
	Starts listening, and schedules the per-frame flush.

	Heartbeat runs once per frame, which naturally caps the send rate at the
	frame rate — comfortably under the point where the server degrades. `manual`
	hands that decision to the caller instead.
]]
function Transport.start(endpoint: Endpoint)
	if endpoint.isServer then
		table.insert(
			endpoint.connections,
			endpoint.reliable.OnServerEvent:Connect(function(player, payload, refs)
				if typeof(payload) ~= "buffer" then
					if endpoint.onAbuse then
						(endpoint.onAbuse :: any)(player, "btyn: payload was not a buffer")
					end
					return
				end
				consume(endpoint, player, payload, refs)
			end)
		)
		table.insert(
			endpoint.connections,
			endpoint.unreliable.OnServerEvent:Connect(function(player, payload, refs)
				if typeof(payload) ~= "buffer" then
					if endpoint.onAbuse then
						(endpoint.onAbuse :: any)(player, "btyn: payload was not a buffer")
					end
					return
				end
				consume(endpoint, player, payload, refs)
			end)
		)

		-- Drop a leaver's pending bytes rather than firing at a gone player.
		table.insert(
			endpoint.connections,
			Players.PlayerRemoving:Connect(function(player)
				endpoint.reliableStreams[player] = nil
				endpoint.unreliableStreams[player] = nil
			end)
		)
	else
		table.insert(
			endpoint.connections,
			endpoint.reliable.OnClientEvent:Connect(function(payload, refs)
				consume(endpoint, nil, payload, refs)
			end)
		)
		table.insert(
			endpoint.connections,
			endpoint.unreliable.OnClientEvent:Connect(function(payload, refs)
				consume(endpoint, nil, payload, refs)
			end)
		)
	end

	if not endpoint.config.manual then
		table.insert(
			endpoint.connections,
			RunService.Heartbeat:Connect(function()
				Transport.flush(endpoint)
			end)
		)
	end
end

function Transport.new(config: Config): Endpoint
	return newEndpoint(config)
end

Transport.streamFor = streamFor
Transport.flushStream = flushStream

return Transport
