--!strict
--[[
	Studio integration test — client half. See TestServer for the rationale.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Net"))

local function say(...: any)
	print("[client]", ...)
end

local folder = ReplicatedStorage:WaitForChild("BTYN")
local reliable = folder:WaitForChild("R") :: RemoteEvent
local unreliable = folder:WaitForChild("U") :: UnreliableRemoteEvent

local stats = {
	reliableFires = 0,
	reliableBytes = 0,
	unreliableFires = 0,
	unreliableBytes = 0,
	damaged = 0,
	muzzle = 0,
	announce = 0,
	healthUpdates = 0,
	plateUpdates = 0,
	healthRemoved = 0,
}

reliable.OnClientEvent:Connect(function(payload)
	stats.reliableFires += 1
	stats.reliableBytes += buffer.len(payload)
	-- Per-fire sizes, so the totals can be reconciled against what the schema
	-- says each packet should cost rather than taken on faith.
	say(`  <- reliable batch: {buffer.len(payload)} B`)
end)

unreliable.OnClientEvent:Connect(function(payload)
	stats.unreliableFires += 1
	stats.unreliableBytes += buffer.len(payload)
	say(`  <- unreliable batch: {buffer.len(payload)} B`)
end)

Net.Damaged.on(function(data)
	stats.damaged += 1
	say(`Damaged: victim={data.victim} amount={data.amount} critical={tostring(data.critical)}`)
end)

Net.Muzzle.on(function(data)
	stats.muzzle += 1
	say(string.format("Muzzle: at=(%.1f, %.1f, %.1f) dir=(%.3f, %.3f, %.3f)", data.at.X, data.at.Y, data.at.Z, data.dir.X, data.dir.Y, data.dir.Z))
end)

Net.Announce.on(function(data)
	stats.announce += 1
	say(`Announce: "{data.text}" team={data.team} at=({data.at.x}, {data.at.y})`)
end)

Net.Health.on(function(id, state, changed)
	stats.healthUpdates += 1
	local keys = {}
	for key in changed do
		table.insert(keys, key)
	end
	table.sort(keys)
	say(`Health[{id}] changed=\{{table.concat(keys, ",")}} state: hp={state.hp} armor={state.armor} downed={tostring(state.downed)}`)
end)

Net.Health.onRemove(function(id)
	stats.healthRemoved += 1
	say(`Health[{id}] removed`)
end)

Net.Nameplate.on(function(id, state, changed)
	stats.plateUpdates += 1
	say(`Nameplate[{id}]: label="{state.label}" team={state.team}`)
end)

task.wait(2)

-- Batching: five packets queued in a single frame must leave as one fire.
say("firing 5 Attacks in one frame")
for index = 1, 5 do
	Net.Attack.fire({ target = 40 + index, combo = index, heavy = index % 2 == 0 })
end

task.wait(0.5)

say("firing 3 unreliable Aims in one frame")
for index = 1, 3 do
	Net.Aim.fire({ yaw = index * 0.5, pitch = -index * 0.25 })
end

task.wait(0.5)

-- Request/reply. The handler yields server-side.
say("calling Buy (handler yields 0.1s)")
local started = os.clock()
local reply = Net.Buy.call({ item = 7, quantity = 3 })
say(string.format("Buy replied in %.0f ms: ok=%s balance=%d", (os.clock() - started) * 1000, tostring(reply.ok), reply.balance))

-- Rejection path: the handler returns nil.
local ok, err = Net.Buy.try({ item = 999, quantity = 1 })
say(`Buy(999) rejected as expected: ok={tostring(ok)} err={tostring(err)}`)

task.wait(0.5)

-- Rate limit: Chat is declared `rate 2`, so most of a burst of 20 must be
-- dropped and reported on the server.
say("firing 20 Chats against a rate of 2/s")
for index = 1, 20 do
	Net.Chat.fire({ text = `message {index}` })
end

task.wait(4)

say("--- client counters ---")
say(`  reliable   : {stats.reliableFires} fires, {stats.reliableBytes} B`)
say(`  unreliable : {stats.unreliableFires} fires, {stats.unreliableBytes} B`)
say(`  Damaged    : {stats.damaged}`)
say(`  Muzzle     : {stats.muzzle}`)
say(`  Announce   : {stats.announce}`)
say(`  Health     : {stats.healthUpdates} updates, {stats.healthRemoved} removals`)
say(`  Nameplate  : {stats.plateUpdates} updates`)
say("--- end ---")
