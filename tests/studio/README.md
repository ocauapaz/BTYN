# Studio integration test

The headless suite (`lune run tests/run`) covers the compiler, the codecs and —
against stand-ins for the Roblox globals — the transport's own rejections. What
it cannot cover is the part that needs a running engine: real RemoteEvents, real
batching across a frame, and the actual byte counts on the wire. That is what
these two scripts are for.

## Setup

Place them in a Studio place alongside the runtime and a compiled schema:

| Path | Contents |
|---|---|
| `ReplicatedStorage.BTYN` | `src/init.luau`, with `Stream`, `Transport`, `Channel`, `RateLimiter`, `Request` as children |
| `ServerScriptService.Net` | generated server module |
| `ReplicatedStorage.Net` | generated client module |
| `ServerScriptService.TestServer` | `TestServer.luau` as a `Script` |
| `StarterPlayer.StarterPlayerScripts.TestClient` | `TestClient.luau` as a `LocalScript` |

Compile `examples/net.btyn` first — the scripts exercise the packets it
declares. Then press Play and read the output.

## What it proves

Results from a run against `examples/net.btyn`:

```
[client]   <- reliable batch: 22 B     Health keyframe (9) + Nameplate keyframe (13)
[client]   <- reliable batch: 10 B     Buy reply
[client]   <- reliable batch:  4 B     Buy rejection, no body
[client]   <- reliable batch:  7 B     Health delta — only hp crossed
[client]   <- reliable batch: 24 B     Damaged (12) + Announce (12)
[client]   <- unreliable batch: 19 B   Muzzle
[client]   <- reliable batch:  5 B     Health removal

[server]   reliable   : 4 fires, 278 B
[server]   unreliable : 1 fires, 15 B
[server]   Attack     : 5 decoded
[server]   Chat       : 2 decoded
[server]   abuse      : 18 reports
```

- **Batching.** 25 client-to-server packets (5 Attacks, 20 Chats) left in
  **2** remote fires. 3 unreliable Aims left in **1**.
- **Two remotes.** The whole place contains `ReplicatedStorage.BTYN.R` and
  `.U`, and nothing else.
- **Delta encoding.** The Health keyframe costs 9 B; changing only `hp` costs
  7 B. Re-setting a field to the value it already holds sends nothing at all.
- **Interest management.** Clearing the audience produces a 5 B removal and the
  client drops the entity.
- **Rate limiting.** 20 Chats against `rate 2` yielded 2 decoded and 18 abuse
  reports.
- **Requests.** A handler that yields 100 ms replied in ~115 ms without
  stalling anything else in the batch. The rejection path costs 4 B.
- **Types.** `vec3`, `unit`, `angle`, enums as strings, nested structs, and
  bitfield-packed booleans all round-tripped through a real remote.
- **Refusals.** Four hand-built payloads, of the kind only an exploiter sends
  and the generated API cannot express: a 4096-packet batch against the ceiling
  of 256, a reliable-only packet pushed down the unreliable remote, an unknown
  opcode, and a payload that is not a buffer. Each is refused as one abuse
  report and none reaches a handler. `tests/transport.spec.luau` pins the same
  four headlessly; this confirms they survive a real wire.

Every figure above reconciles exactly against what `--check` predicts for the
schema. If a change makes them stop reconciling, something regressed.

## A bug this caught

The first run decoded `pitch = -0.25` as `6.0331`. The `angle` codec encoded
into `[0, 2pi)` while its own documentation said `[-pi, pi]` — the same
direction, but not the same number, which breaks any comparison or
interpolation done on the result.

The headless property tests had missed it because the value generator only
produced positive angles. Both the codec and the generator were fixed, and
`tests/codec.spec.luau` now pins negative angles and the wrap boundaries
explicitly.
