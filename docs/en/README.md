---
permalink: /en/
title: Getting started
lang: en
---

# BTYN documentation

**English** · [Português](../pt-br/README.md)

- **[Schema language](schema.md)** — declarations, types, config
- **[Generated API](api.md)** — what you call on each side
- **[Compiler and editor](cli.md)** — flags, watch mode, VS Code
- **[Performance](performance.md)** — the engine's limits, what BTYN does, what you should do
- **[Security](security.md)** — what buffers do and do not protect
- **[Troubleshooting](troubleshooting.md)** — when something does not work

## Getting started

### 1. Install the toolchain

BTYN needs [Rojo](https://rojo.space) to sync files into Studio and
[Lune](https://lune-org.github.io/docs) to run the compiler. Both are pinned in
`rokit.toml`:

```bash
rokit install
```

### 2. Put the runtime in your game

The generated modules require a runtime at `ReplicatedStorage.BTYN` by default.
`default.project.json` maps `src/` there:

```json
{
  "name": "BTYN",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "BTYN": { "$path": "src" }
    }
  }
}
```

Which gives you:

```
ReplicatedStorage
└── BTYN              (ModuleScript, from src/init.luau)
    ├── Stream
    ├── Transport
    ├── Channel
    ├── RateLimiter
    └── Request
```

Keeping packages somewhere else? Leave them there and point the schema at them
instead, with the `runtime` key shown below. The value is pasted into a
`require` on both sides, so any expression that resolves works.

This is the step most first runs get wrong, and it shows up as
`Infinite yield possible on 'ReplicatedStorage:WaitForChild("BTYN")'`.

### 3. Write a schema

`net.btyn`:

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

### 4. Compile it

```bash
lune run cli/main -- net.btyn
```

```
btyn: wrote src/Server/Net.luau
btyn: wrote src/Client/Net.luau
```

While working, leave the compiler watching beside `rojo serve` so the modules
track the schema on save:

```bash
lune run cli/main -- net.btyn --watch
```

The generated files are build output. Add them to `.gitignore` unless your team
prefers reviewing generated diffs — but if you do commit them, commit **both**,
because opcodes are assigned across the whole schema and the two sides have to
agree.

### 5. Use it

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

### 6. Install the editor extension

Optional, and worth the two minutes. It gives highlighting, context-aware
completion, hover showing each type's wire cost, and the compiler's own errors
inline as you type:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

See [compiler and editor](cli.md#editor-support) for its settings.

## Where to go next

Reaching for **state replication** rather than events — health bars, nameplates,
NPC positions — go to [channels](api.md#channels). Delta encoding and interest
management are where the bandwidth savings actually live.

Worried about **bandwidth**, read [performance](performance.md). The techniques
section matters more than any library choice, including this one.

Before **shipping**, read [security](security.md), particularly the part about
what BTYN cannot do for you.

When something **does not work**, [troubleshooting](troubleshooting.md) lists
the failures in the order people hit them.
