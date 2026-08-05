--!strict
--[[
	Studio integration test — server half.

	The headless suite covers the compiler and the codecs. What it cannot reach
	is the part that needs a running engine: real RemoteEvents, real batching
	across a frame, and the actual byte counts on the wire.

	This script drives the server side and reports counters the client cannot
	see. Run it with TestClient in StarterPlayerScripts and read the output.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Net = require(ServerScriptService:WaitForChild("Net"))

local function say(...: any)
	print("[server]", ...)
end

-- Spy on the raw remotes. Extra listeners are harmless and let us count what
-- actually crossed the wire, rather than what we think we sent.
local folder = ReplicatedStorage:WaitForChild("BTYN")
local reliable = folder:WaitForChild("R") :: RemoteEvent
local unreliable = folder:WaitForChild("U") :: UnreliableRemoteEvent

local stats = {
	reliableFires = 0,
	reliableBytes = 0,
	unreliableFires = 0,
	unreliableBytes = 0,
	attacks = 0,
	aims = 0,
	chats = 0,
	buys = 0,
	abuse = 0,
}

reliable.OnServerEvent:Connect(function(_, payload)
	stats.reliableFires += 1
	stats.reliableBytes += buffer.len(payload)
end)

unreliable.OnServerEvent:Connect(function(_, payload)
	stats.unreliableFires += 1
	stats.unreliableBytes += buffer.len(payload)
end)

Net.onAbuse(function(player, reason)
	stats.abuse += 1
	say("abuse:", reason)
end)

Net.Attack.on(function(player, data)
	stats.attacks += 1
	if stats.attacks == 1 then
		say(`first Attack decoded: target={data.target} combo={data.combo} heavy={tostring(data.heavy)}`)
	end
end)

Net.Aim.on(function(_, data)
	stats.aims += 1
	if stats.aims == 1 then
		say(string.format("first Aim decoded: yaw=%.4f pitch=%.4f", data.yaw, data.pitch))
	end
end)

Net.Chat.on(function(_, data)
	stats.chats += 1
end)

Net.Buy.on(function(player, request)
	stats.buys += 1
	say(`Buy request: item={request.item} quantity={request.quantity}`)

	if request.item == 999 then
		return nil -- rejection path
	end

	-- Yield on purpose: a real handler hits a datastore here, and the batch
	-- walk must not stall behind it.
	task.wait(0.1)
	return { ok = true, balance = 1234, reason = "" }
end)

local function runScenario(player: Player)
	say("player joined:", player.Name)

	-- Let the client's LocalScript finish loading before anything is sent.
	-- Otherwise the first flush can land before its spy is connected, and the
	-- byte totals silently disagree by exactly one packet.
	task.wait(3)

	-- Channels. Health is high priority, Nameplate is low.
	local health = Net.Health.of(1)
	local plate = Net.Nameplate.of(1)

	health.audience({ player })
	plate.audience({ player })

	health.set({ hp = 100, armor = 50, downed = false })
	plate.set({ label = "Dummy", team = "Red" })
	say("channel keyframe queued")

	task.wait(1)

	-- A delta: only hp changed, so only hp should cross.
	health.set({ hp = 80 })
	say("channel delta queued (hp only)")

	task.wait(0.5)

	-- Setting a field to the value it already holds must not dirty it.
	health.set({ hp = 80, armor = 50 })
	say("redundant set queued (should send nothing)")

	task.wait(1)

	-- Server to client, three broadcast forms in one frame.
	Net.Damaged.all({ victim = 1, attacker = 2, amount = 25, critical = true, killed = false })
	Net.Muzzle.all({ at = Vector3.new(1, 2, 3), dir = Vector3.new(0, 1, 0) })
	Net.Announce.list({ player }, { text = "hello", team = "Blue", at = { x = 3, y = 4 } })

	task.wait(2)

	-- Drop the audience: the client should be told to remove the entity.
	health.audience({})
	say("audience cleared")

	task.wait(1)

	say("--- server counters ---")
	say(`  reliable   : {stats.reliableFires} fires, {stats.reliableBytes} B`)
	say(`  unreliable : {stats.unreliableFires} fires, {stats.unreliableBytes} B`)
	say(`  Attack     : {stats.attacks} decoded`)
	say(`  Aim        : {stats.aims} decoded`)
	say(`  Chat       : {stats.chats} decoded`)
	say(`  Buy        : {stats.buys} decoded`)
	say(`  abuse      : {stats.abuse} reports`)
	say("--- end ---")
end

Players.PlayerAdded:Connect(runScenario)
for _, player in Players:GetPlayers() do
	task.spawn(runScenario, player)
end
