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

type Pending = {
	thread: thread,
	deadline: number,
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
]]
function Request.await(registry: Registry, id: number): (boolean, any)
	registry.pending[id] = {
		thread = coroutine.running(),
		deadline = os.clock() + registry.timeout,
	}
	return coroutine.yield()
end

--[[
	Delivers a reply. A late or duplicate reply for an id nobody is waiting on
	is dropped silently — that is exactly what an unreliable retransmit or a
	malicious echo looks like.
]]
function Request.resolve(registry: Registry, id: number, ok: boolean, value: any)
	local entry = registry.pending[id]
	if entry == nil then
		return
	end

	registry.pending[id] = nil
	task.spawn(entry.thread, ok, value)
end

--[[
	Fails every request whose deadline has passed. Call once per frame.
]]
function Request.sweep(registry: Registry)
	local now = os.clock()
	for id, entry in registry.pending do
		if now >= entry.deadline then
			registry.pending[id] = nil
			task.spawn(entry.thread, false, "btyn: request timed out")
		end
	end
end

return Request
