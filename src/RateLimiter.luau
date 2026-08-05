--!strict
--[[
	Per-player token bucket.

	Schema validation proves a packet is well-formed; it says nothing about how
	often it arrives. Without a limit one client can spend the engine's ~500
	requests/second budget on its own and degrade the server for everybody, and
	buffers make that cheaper to attempt rather than harder.

	A bucket refills continuously at `rate` tokens per second and holds at most
	`burst`. That absorbs the natural clumping of a frame-batched sender while
	still bounding the sustained rate.
]]

local RateLimiter = {}

export type Bucket = {
	rate: number,
	burst: number,
	-- Weak keys: a player who leaves takes their entry with them, so there is
	-- no cleanup hook to forget to wire up.
	tokens: { [Player]: number },
	stamps: { [Player]: number },
}

--[[
	`burst` defaults to one second of budget, with a floor of one so a rate
	below 1/s can still ever fire.
]]
function RateLimiter.new(rate: number, burst: number?): Bucket
	return {
		rate = rate,
		burst = burst or math.max(rate, 1),
		tokens = setmetatable({}, { __mode = "k" }) :: any,
		stamps = setmetatable({}, { __mode = "k" }) :: any,
	}
end

--[[
	Spends a token if one is available.

	Returns false when the caller is over budget; the packet should be dropped
	and reported, never queued — queueing an abusive sender just moves the cost.
]]
function RateLimiter.allow(bucket: Bucket, player: Player): boolean
	local now = os.clock()
	local last = bucket.stamps[player]

	local available: number
	if last == nil then
		available = bucket.burst
	else
		available = math.min(bucket.burst, bucket.tokens[player] + (now - last) * bucket.rate)
	end

	bucket.stamps[player] = now

	if available < 1 then
		bucket.tokens[player] = available
		return false
	end

	bucket.tokens[player] = available - 1
	return true
end

return RateLimiter
