--!strict
--!native
--[[
	Replicated state, delta-encoded, with an explicit audience.

	Events answer "something happened". Channels answer "this is how things
	are", which is a different problem: resending an entity's whole state every
	frame is how a game quietly walks into the ~50 KB/s throttle.

	Two mechanisms do the work:

	  Delta encoding — each instance tracks which fields changed since the last
	  flush and sends only those, behind a bitmask. A health tick costs one mask
	  byte plus one value byte, not the whole record.

	  Audience — every instance carries the set of players it is relevant to.
	  This is the interest management the survey calls the single biggest
	  saving (§5.1) and that none of the surveyed libraries implement: the
	  cheapest packet is the one never sent. A player joining an audience gets a
	  keyframe automatically, so they never decode a delta against state they
	  never had.

	Deltas coalesce, which makes deferring safe: when a player is over their
	byte budget, low-priority updates simply stay dirty and go out next frame
	merged with whatever else changed. Nothing is lost, only delayed.
]]

local Stream = require(script.Parent.Stream)
local Transport = require(script.Parent.Transport)

local Channel = {}

type Endpoint = Transport.Endpoint

-- Higher goes out first, and is the last to be dropped when a player is over
-- budget for the frame.
local PRIORITY_ORDER: { [string]: number } = {
	high = 3,
	normal = 2,
	low = 1,
}

--[[
	The three per-player maps are weak-keyed, for the same reason RateLimiter's
	are: a handle can outlive a session, and a player who leaves would otherwise
	stay in `known` forever — costing a removal packet aimed at nobody every
	time an entity dropped them, and growing without bound over a long uptime.
]]
export type Handle = {
	id: number,
	state: { [string]: any },
	-- bitmask of fields changed since the last flush
	mask: number,
	audience: { [Player]: boolean },
	-- players who have received a keyframe and can decode a delta
	known: { [Player]: boolean },
	-- bits owed to a specific player because their update was deferred when
	-- they were over budget; merged into the next update they do receive
	carry: { [Player]: number },
}

local WEAK_KEYS = { __mode = "k" }

local function weakSet(players: { Player }?): { [Player]: boolean }
	local result: { [Player]: boolean } = setmetatable({}, WEAK_KEYS) :: any
	if players then
		for _, player in players do
			result[player] = true
		end
	end
	return result
end

export type Set = {
	endpoint: Endpoint,
	opcode: number,
	removeOpcode: number,
	opcodeBytes: number,
	maxSize: number,
	priority: number,
	fieldBits: { [string]: number },
	fullMask: number,
	write: (buffer, number, { [string]: any }, number, { Instance }) -> number,
	handles: { [number]: Handle },
	-- Destroyed handles waiting to have their removal packet sent. They leave
	-- `handles` at destroy time rather than at flush time, so re-creating the
	-- same id later in the frame gets a fresh, live handle instead of the
	-- corpse of the old one.
	removed: { Handle },
}

export type Config = {
	endpoint: Endpoint,
	opcode: number,
	removeOpcode: number,
	opcodeBytes: number,
	maxSize: number,
	priority: string,
	fields: { string },
	write: (buffer, number, { [string]: any }, number, { Instance }) -> number,
}

function Channel.new(config: Config): Set
	local fieldBits: { [string]: number } = {}
	for index, name in config.fields do
		fieldBits[name] = 2 ^ (index - 1)
	end

	return {
		endpoint = config.endpoint,
		opcode = config.opcode,
		removeOpcode = config.removeOpcode,
		opcodeBytes = config.opcodeBytes,
		maxSize = config.maxSize,
		priority = PRIORITY_ORDER[config.priority] or 2,
		fieldBits = fieldBits,
		fullMask = 2 ^ #config.fields - 1,
		write = config.write,
		handles = {},
		removed = {},
	}
end

--[[
	Returns the handle for an entity, creating it on first use.
]]
function Channel.of(set: Set, id: number): Handle
	local handle = set.handles[id]
	if handle then
		return handle
	end

	handle = {
		id = id,
		state = {},
		mask = 0,
		audience = weakSet(),
		known = weakSet(),
		-- Holds bit masks rather than flags, but wants the same weak keys.
		carry = setmetatable({}, WEAK_KEYS) :: any,
	}
	set.handles[id] = handle
	return handle
end

--[[
	Merges a partial update, marking only the fields that actually changed.

	The comparison matters: setting a field to the value it already holds must
	not dirty it, or a caller that re-sets its whole state every frame would
	defeat delta encoding entirely.
]]
function Channel.set(set: Set, handle: Handle, values: { [string]: any })
	local state = handle.state
	local mask = handle.mask

	for name, value in values do
		local bit = set.fieldBits[name]
		if bit == nil then
			error(`btyn: '{name}' is not a field of this channel`, 0)
		end
		-- Tables — struct and array fields — compare by reference, so a caller
		-- mutating the same table in place would never dirty the field. Treat
		-- every table as changed; scalars and Roblox value types compare by
		-- value and keep the cheap skip.
		if state[name] == value and type(value) ~= "table" then
			continue
		end
		state[name] = value
		mask = bit32.bor(mask, bit)
	end

	handle.mask = mask
end

--[[
	Replaces the audience.

	Players who left it are told to drop the entity; players who joined get a
	keyframe on the next flush.
]]
function Channel.audience(handle: Handle, players: { Player })
	handle.audience = weakSet(players)
end

--[[
	Marks the entity gone.

	The handle leaves the set immediately and moves to the removal queue, so a
	caller that destroys an id and re-creates it in the same frame gets a live
	handle back rather than the one already on its way out. The queued removal
	still goes out first, ahead of the new keyframe.
]]
function Channel.destroy(set: Set, handle: Handle)
	if set.handles[handle.id] ~= handle then
		return
	end

	set.handles[handle.id] = nil
	handle.audience = weakSet()
	table.insert(set.removed, handle)
end

--[[
	Writes one update packet into a player's batch.
]]
local function push(set: Set, player: Player, handle: Handle, mask: number): number
	local reserve = set.opcodeBytes + 4 + set.maxSize
	local b, o, stream = Transport.reserve(set.endpoint, player, true, reserve)

	if set.opcodeBytes == 1 then
		buffer.writeu8(b, o, set.opcode)
	else
		buffer.writeu16(b, o, set.opcode)
	end

	buffer.writeu32(b, o + set.opcodeBytes, handle.id)
	local written = set.write(b, o + set.opcodeBytes + 4, handle.state, mask, stream.refs)

	local total = set.opcodeBytes + 4 + written
	Stream.finish(stream, total)
	return total
end

local function pushRemove(set: Set, player: Player, id: number): number
	local total = set.opcodeBytes + 4
	local b, o, stream = Transport.reserve(set.endpoint, player, true, total)

	if set.opcodeBytes == 1 then
		buffer.writeu8(b, o, set.removeOpcode)
	else
		buffer.writeu16(b, o, set.removeOpcode)
	end

	buffer.writeu32(b, o + set.opcodeBytes, id)
	Stream.finish(stream, total)
	return total
end

--[[
	Flushes every channel set in priority order, respecting each player's frame
	byte budget.

	`spent` is shared across all sets for the frame so the budget is per player,
	not per channel — otherwise twenty channels would each happily spend a full
	allowance.
]]
function Channel.flushAll(sets: { Set }, budgetPerFrame: number)
	local spent: { [Player]: number } = {}

	-- Sorted in place: the caller hands over the same array every frame and
	-- always wants the same order, so there is nothing worth preserving — and
	-- after the first frame this is a no-op over an already-sorted array.
	table.sort(sets, function(a, b)
		return a.priority > b.priority
	end)

	for _, set in sets do
		-- Removals go out before this set's updates, so an id destroyed and
		-- re-created in the same frame reaches the client as drop-then-keyframe
		-- rather than the other way round.
		for _, handle in set.removed do
			for player in handle.known do
				pushRemove(set, player, handle.id)
			end
		end
		table.clear(set.removed)

		for id, handle in set.handles do
			for player in handle.known do
				if not handle.audience[player] then
					pushRemove(set, player, id)
					handle.known[player] = nil
					handle.carry[player] = nil
				end
			end

			for player in handle.audience do
				local used = spent[player] or 0
				local owed = bit32.bor(handle.mask, handle.carry[player] or 0)

				-- High priority ignores the budget: it is reserved for state a
				-- player cannot play without.
				if set.priority < 3 and used >= budgetPerFrame then
					-- Remember what this player still needs. Deltas coalesce,
					-- so a deferred update merges with the next one instead of
					-- being lost.
					if owed ~= 0 then
						handle.carry[player] = owed
					end
					continue
				end

				if not handle.known[player] then
					-- Keyframe: a full mask, so a fresh viewer starts from a
					-- complete picture rather than a delta they cannot apply.
					spent[player] = used + push(set, player, handle, set.fullMask)
					handle.known[player] = true
					handle.carry[player] = nil
				elseif owed ~= 0 then
					spent[player] = used + push(set, player, handle, owed)
					handle.carry[player] = nil
				end
			end

			handle.mask = 0
		end
	end
end

return Channel
