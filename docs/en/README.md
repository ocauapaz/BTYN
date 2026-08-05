---
permalink: /en/
title: Getting started
lang: en
---

# BTYN documentation

**English** · [Português](../pt-br/README.md)

- **[Schema language](schema.md)** — declarations, types, config
- **[Generated API](api.md)** — what you call on each side
- **[Performance](performance.md)** — the engine's limits, what BTYN does, what you should do
- **[Security](security.md)** — what buffers do and do not protect

## Getting started

Install the toolchain ([Rojo](https://rojo.space), [Lune](https://lune-org.github.io/docs)):

```bash
rokit install
```

Write a schema. `net.btyn`:

```btyn
config {
    server = "src/Server/Net.luau"
    client = "src/Client/Net.luau"
}

event Attack from client rate 10 {
    target: entity,
    combo:  u8,
}

event Damaged from server {
    victim: entity,
    amount: u16,
}
```

Compile it:

```bash
lune run cli/main -- net.btyn
```

Make sure `src/` is in your game as a module named `BTYN` — see
`default.project.json` for the mapping, or point `runtime` somewhere else in
your `config` block.

Use it:

```luau
-- src/Server/init.server.luau
local Net = require(script.Parent.Net)

Net.Attack.on(function(player, data)
    -- Validate the meaning; the schema already validated the shape.
    local target = entities[data.target]
    if not target or not inReach(player, target) then
        return
    end

    local amount = weaponDamage(player)   -- server-held, never sent
    target.hp -= amount

    Net.Damaged.all({ victim = data.target, amount = amount })
end)
```

```luau
-- src/Client/init.client.luau
local Net = require(script.Parent.Net)

Net.Damaged.on(function(data)
    showHitmarker(data.victim, data.amount)
end)

mouse.Button1Down:Connect(function()
    Net.Attack.fire({ target = currentTarget, combo = combo })
end)
```

## Where to go next

Reaching for **state replication** rather than events — health bars, nameplates,
NPC positions — go to [channels](api.md#channels). Delta encoding and interest
management are where the bandwidth savings actually live.

Worried about **bandwidth**, read [performance](performance.md). The techniques
section matters more than any library choice, including this one.

Before **shipping**, read [security](security.md), particularly the part about
what BTYN cannot do for you.
