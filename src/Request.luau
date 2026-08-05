--!strict
--[[
	Request/reply over the same two remotes.

	No RemoteFunction is involved. A RemoteFunction call blocks the caller and,
	on the server, a yielding invocation blocks replication behind it — so this
	rides the ordinary batched stream instead: the request carries a correlation
	id, the reply echoes it, and the waiting thread is resumed when it lands.

	Every request also gets a deadline. A reply that never arrives — the peer
	left, the handler threw, a packet was lost — must not strand a thread
	forever.
]]

local Request = {}

-- An entry with no thread is a tombstone: a request that timed out, kept in
-- the table so its id stays occupied for one more timeout period. Freeing the
-- id immediately would let a reply that arrives after the timeout land on a
-- fresh request that happened to reuse it.
--
-- `peer` is who the request went to, and is what a reply has to match. Nil on
-- the client, where the only possible peer is the server.
type Pending = {
	thread: thread?,
	deadline: number,
	peer: Player?,
}

export type Registry = {
	timeout: number,
	nextId: number,
	pending: { [number]: Pending },
}

local MAX_ID = 65535

function Request.new(timeout: number): Registry
	return {
		timeout = timeout,
		nextId = 1,
		pending = {},
	}
end

--[[
	Allocates a correlation id.

	Ids wrap at 16 bits. Colliding would need 65535 requests outstanding at
	once, but skipping a live id costs one comparison, so it is checked rather
	than assumed.
]]
function Request.allocate(registry: Registry): number
	local id = registry.nextId

	for _ = 1, MAX_ID do
		if registry.pending[id] == nil then
			registry.nextId = if id >= MAX_ID then 1 else id + 1
			return id
		end
		id = if id >= MAX_ID then 1 else id + 1
	end

	error("btyn: no free request ids — 65535 requests are already in flight", 0)
end

--[[
	Parks the calling thread until the matching reply arrives or the deadline
	passes. Returns (true, value) or (false, reason).

	`peer` is who the request was sent to. Only a reply from that peer resolves
	it — see `resolve`.
]]
function Request.await(registry: Registry, id: number, peer: Player?): (boolean, any)
	registry.pending[id] = {
		thread = coroutine.running(),
		deadline = os.clock() + registry.timeout,
		peer = peer,
	}
	return coroutine.yield()
end

--[[
	Delivers a reply. A late or duplicate reply for an id nobody is waiting on
	is dropped silently — that is exactly what an unreliable retransmit or a
	malicious echo looks like. A reply landing on a tombstone is the late reply
	the tombstone exists to absorb; it consumes it, freeing the id.

	`from` is who sent the reply, and must be the peer the request went to. The
	server's registry is shared across every player and ids are sequential, so
	without this check any client could answer — or blind-scan every id and
	answer — a request the server sent to somebody else. A forged reply is
	dropped as silently as a late one: an attacker learns nothing either way.
]]
function Request.resolve(registry: Registry, id: number, ok: boolean, value: any, from: Player?)
	local entry = registry.pending[id]
	if entry == nil or entry.peer ~= from then
		return
	end

	registry.pending[id] = nil
	if entry.thread == nil then
		return
	end
	task.spawn(entry.thread, ok, value)
end

--[[
	Fails every request whose deadline has passed. Call once per frame.

	A timed-out entry becomes a tombstone for one more timeout period rather
	than freeing its id on the spot — see the note on `Pending`.
]]
function Request.sweep(registry: Registry)
	local now = os.clock()
	for id, entry in registry.pending do
		if now < entry.deadline then
			continue
		end

		local thread = entry.thread
		if thread == nil then
			registry.pending[id] = nil
		else
			entry.thread = nil
			entry.deadline = now + registry.timeout
			task.spawn(thread, false, "btyn: request timed out")
		end
	end
end

return Request
