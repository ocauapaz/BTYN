---
title: Generated API
lang: en
---

# The generated API

[← Docs index](README.md)

Compiling a schema writes two modules. Each one carries only the half of the
protocol its side takes part in: the client file has no reader for a packet the
server never sends it, and no writer for one the client never sends.

```luau
-- server
local Net = require(ServerScriptService.Net)
-- client
local Net = require(ReplicatedStorage.Net)
```

Every payload type is exported, so `Net.Attack.on` hands you a fully typed
table with no annotation on your side.

## Events

Given:

```btyn
event Attack from client rate 10 { target: entity, combo: u8 }
event Damaged from server { victim: entity, amount: u16 }
```

### Sending side

```luau
-- client, because Attack is `from client`
Net.Attack.fire({ target = id, combo = 2 })
```

```luau
-- server, because Damaged is `from server`
Net.Damaged.to(player, data)          -- one player
Net.Damaged.all(data)                 -- everyone
Net.Damaged.list(players, data)       -- a chosen set
Net.Damaged.except(player, data)      -- everyone but one
```

`all`, `list` and `except` serialise once and copy the bytes into each
recipient's batch. `list` is the one to reach for when you know who cares —
unlike `FireAllClients`, it lets you filter.

### Receiving side

```luau
-- server
Net.Attack.on(function(player, data)
    -- data.target: number, data.combo: number
end)

-- client
Net.Damaged.on(function(data) end)
```

One handler per packet; registering again replaces it.

## Requests

```btyn
request Buy from client { item: u16 } -> { ok: bool, balance: u32 }
```

```luau
-- client
local reply = Net.Buy.call({ item = 12 })       -- yields; throws on failure
local ok, reply = Net.Buy.try({ item = 12 })    -- yields; never throws
```

```luau
-- server
Net.Buy.on(function(player, request)
    if not canAfford(player, request.item) then
        return nil          -- nil rejects; the caller's `call` throws
    end
    return { ok = true, balance = balanceOf(player) }
end)
```

The handler runs on its own thread, so yielding in it — a datastore call, a
`task.wait` — does not hold up anything else in the batch.

For a `request X from server`, the direction flips and the server's `call` takes
a target: `Net.Ping.call(player, data)`.

## Channels

```btyn
channel Health priority high { hp: u8(0..100), downed: bool }
```

### Server

```luau
local health = Net.Health.of(entityId)

health.set({ hp = 80 })              -- only changed fields are marked dirty
health.audience(playersInRange)      -- who receives it
health.destroy()                     -- tells holders to drop it
```

`of` returns the same handle for the same id, so calling it in a loop does not
allocate.

`set` compares before marking. Re-setting a field to the value it already holds
does nothing, which means you can hand it your whole state every frame without
defeating delta encoding.

`audience` replaces the set. Players who joined get a **keyframe** — a full
update — so they never try to apply a delta against state they never had.
Players who left are told to drop the entity.

That call is the interest management. BTYN does not decide who is relevant,
because only your game knows; it makes acting on the answer cheap and correct.

```luau
-- a typical shape
Net.Health.of(id).audience(playersWithin(120, position))
```

### Client

```luau
Net.Health.on(function(id, state, changed)
    -- state:   the merged view, always complete
    -- changed: only the fields that arrived in this update
    updateBar(id, state.hp)
end)

Net.Health.onRemove(function(id) removeBar(id) end)

local current = Net.Health.get(id)   -- nil if never received
```

Use `state` for anything that needs the whole picture and `changed` when you
only want to react to what moved — retriggering a hit flash on every unrelated
armour tick is the usual bug here.

## Module-level

```luau
Net.flush()
```

Sends every pending batch now. Only needed with `manual = true`; otherwise this
happens once per frame on Heartbeat.

```luau
Net.onAbuse(function(player, reason)
    warn(`{player}: {reason}`)
end)
```

Fires when a received batch fails validation, or a rate limit is exceeded. On
the server this means a client sent something the schema does not permit, which
no honest client can do — the same compiler wrote both sides. Log it, and
consider it a signal.

Rate limits are declared in the schema (`rate 10`) and enforced on the receiving
side, per player, with a token bucket. An over-budget packet is dropped and
reported, never queued.

---

Next: [performance](performance.md) · [security](security.md) · [schema reference](schema.md)
