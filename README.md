<img src="assets/logo.svg" width="78" align="right" alt="">

# BTYN

**English** · [Português](README.pt-BR.md) · [Español](README.es.md) · [中文](README.zh-CN.md)

[![CI](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml/badge.svg)](https://github.com/ocauapaz/BTYN/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-8570FF)](LICENSE)

A networking compiler for Roblox. You write a schema; it writes the fastest
correct Luau for that exact schema, for both sides.

**[Documentation →](https://ocauapaz.github.io/BTYN/)**

```btyn
event Attack from client rate 10 {
    target: entity,
    combo:  u8,
    heavy:  bool,
}

unreliable Muzzle from server {
    at:  vec3,
    dir: unit,
}

channel Health priority high {
    hp:     u8(0..100),
    downed: bool,
}
```

```luau
-- server
Net.Attack.on(function(player, data)
    -- data.target: number, data.combo: number, data.heavy: boolean
end)

Net.Muzzle.all({ at = origin, dir = facing })

local health = Net.Health.of(entityId)
health.set({ hp = 80 })
health.audience(playersInRange)
```

```luau
-- client
Net.Attack.fire({ target = id, combo = 2, heavy = false })
Net.Muzzle.on(function(data) spawnFlash(data.at, data.dir) end)
Net.Health.on(function(id, state) updateBar(id, state.hp) end)
```

## Why

Roblox gives you about 50 KB/s per client before it throttles *all* replication,
charges roughly 9 bytes of header per remote call, and silently discards an
oversized `UnreliableRemoteEvent` payload. The known answer is one reliable
remote plus one unreliable one, batched per frame, with hand-written `buffer`
serialisation. That works, and it is tedious and easy to get wrong.

BTYN is that answer, generated. Your whole game uses two remotes. Packets batch
into one send per frame. Every field is packed by a codec written for its exact
type, with no runtime schema walking.

### What a compiler buys over a runtime schema

| | |
|---|---|
| **Constant offsets** | A fixed-size packet compiles to a straight line of `buffer.writeu32(b, o + 4, v.target)`. No cursor variable, no per-field type dispatch. |
| **Packed booleans** | 32 flags become one `u32` store, not 32 byte writes. |
| **One bounds check** | Sizes are known, so a packet is validated once on entry instead of per field. |
| **Real types** | Luau has no mapped types, so a table-based schema *cannot* infer its own payload type. A compiler just writes `export type Attack = { target: number, ... }`. |
| **Oversize caught at build time** | The compiler knows every packet's worst case and fails the build if an `unreliable` cannot fit the payload cap — rather than letting the engine drop it in production without a word. |

### What it does that the libraries do not

- **Interest management.** Channels carry an explicit audience. The cheapest
  packet is the one never sent, and a player joining an audience gets a keyframe
  automatically.
- **Priority budgets.** Each channel declares a priority. When a client is over
  its per-frame byte budget, low-priority deltas defer and coalesce; nothing is
  lost, and the throttle is never reached.
- **Serialise-once broadcast.** A filtered broadcast encodes one time and
  memcpys into each recipient's batch.
- **Mandatory caps.** An uncapped `string` or array is a compile error, not a
  default. Unbounded input is how a packet becomes an amplification primitive.

## Quick start

Requires [Rojo](https://rojo.space) and [Lune](https://lune-org.github.io/docs),
both pinned in `rokit.toml`:

```bash
rokit install
```

Put `src/` into your game as a module named `BTYN`, write a schema, and compile:

```bash
lune run cli/main -- net.btyn
```

Inspect it without writing anything — sizes, opcodes, and how close your largest
unreliable packet sits to the cap:

```bash
lune run cli/main -- net.btyn --check
```

```
btyn: net.btyn is valid — 9 packet(s), 1 byte opcodes

  [0    ] Aim            unreliable     client -> server  4 B
  [2    ] Attack         event          client -> server  6 B  rate 10/s
  [3,4  ] Buy            request        client -> server  3 B -> 6-70 B  rate 4/s
  [7,8  ] Health         channel/high   server -> client  3 B
  [9    ] Muzzle         unreliable     server -> client  18 B

  largest unreliable packet: 19 B of the 800 B cap
```

Add `--watch` to recompile on save.

## Editor support

A [VS Code extension](editors/vscode/) with highlighting, context-aware
completion, hover showing each type's wire cost, and live diagnostics from the
compiler itself:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

## Security

Buffers are obfuscation, not security. They make a RemoteSpy dump unreadable and
nothing more; an exploiter with an afternoon decodes your format.

What actually protects you is the server deciding, not the client. BTYN
guarantees the *shape* of what arrives — type, range, length, finiteness — which
eliminates a real class of attack: malformed payloads, giant strings, unbounded
arrays, `NaN` poisoning a physics or economy calculation. It cannot guarantee
that a player was allowed to deal that damage, at that range, off that cooldown.
That part is yours.

[Read the security guide →](https://ocauapaz.github.io/BTYN/en/security)

## Tests

Everything except the two RemoteEvents is pure Luau, which keeps the bulk of the
system testable headlessly — including the generated code, which is loaded and
round-tripped rather than merely inspected.

```bash
lune run tests/run      # compiler and codecs
lune run bench/run      # codec throughput and wire sizes
```

The part that needs a running engine is covered by the
[Studio integration test](tests/studio/): it verifies that 25 packets leave in
2 remote fires, that a channel delta costs 7 B against a 9 B keyframe, and that
every wire size reconciles with what `--check` predicts.

## Status

Working: events (reliable and unreliable), requests, channels with delta
encoding and interest management, per-player rate limiting, every type in the
[schema reference](https://ocauapaz.github.io/BTYN/en/schema), `--watch`, and
the VS Code extension.

Not built yet: roblox-ts `.d.ts` output and the Studio plugin. `typescript =
true` fails the build rather than silently emitting nothing.

## License

[MIT](LICENSE)
