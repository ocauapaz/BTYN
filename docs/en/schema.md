---
title: Schema language
lang: en
---

# The `.btyn` schema language

[← Docs index](README.md)

A schema is a plain text file. Comments follow Luau: `--` to end of line, and
`--[[ ]]` for a block. There are no reserved words — `from`, `rate` and `event`
are matched by position, so a field may be called any of them.

## Declarations

### `event`

Reliable, ordered, batched once per frame.

```btyn
event Attack from client {
    target: entity,
    combo:  u8,
}
```

`from` is required and says who sends. It decides which half of the API each
side receives: a `from client` event gives the client `.fire` and the server
`.on`. Calling the wrong one is a type error, not a silent no-op.

### `unreliable`

Same shape, sent over `UnreliableRemoteEvent`. May arrive out of order or not at
all.

```btyn
unreliable Muzzle from server {
    at:  vec3,
    dir: unit,
}
```

Use it when a lost packet is invisible: muzzle flashes, footstep dust, aim
updates that the next one supersedes anyway. Never for anything with
consequences.

The compiler computes the worst-case size of every unreliable packet and fails
the build if it cannot fit the payload cap. This matters because the engine's
behaviour on an oversized unreliable payload is to discard it without an error.

```
error: unreliable event 'Snapshot' can reach 1003 bytes, over the 800 byte cap
  --> net.btyn:12:12
   |
12 | unreliable Snapshot from server {
   |            ^^^^^^^^ worst case is 1003 bytes
   |
help: the engine drops an oversized unreliable payload without telling you.
      Shrink the packet (quantise floats, cap arrays tighter), split it, or
      make it a reliable `event`
```

### `request`

Request and reply over the same two remotes. No `RemoteFunction` is involved —
a RemoteFunction blocks its caller, and on the server a yielding invocation
blocks replication behind it.

```btyn
request Buy from client rate 4 {
    item:     u16,
    quantity: u8(1..99),
} -> {
    ok:      bool,
    balance: u32,
    reason:  string(64),
}
```

The requester gets `.call` (yields, throws on failure) and `.try` (returns
`ok, value`). The responder gets `.on`, and its handler may yield freely — it
runs on its own thread, so a datastore call does not stall the batch.

Every request carries a deadline (`request_timeout`, default 10s). A reply that
never comes fails the call rather than stranding the thread forever.

### `channel`

Replicated state, delta-encoded, with an explicit audience. Always server to
client, so it takes no `from`.

```btyn
channel Health priority high {
    hp:     u8(0..100),
    armor:  u8,
    downed: bool,
}
```

Only changed fields go out, behind a dirty bitmask. A health tick costs one mask
byte plus one value byte, not the whole record.

`priority` is `low`, `normal` (default) or `high`. When a client is over its
per-frame byte budget, `low` defers first and `high` never defers. Deferred
deltas coalesce with the next update, so nothing is lost — only delayed.

Capped at 32 fields, which keeps the mask a single load. Splitting is better
design anyway: fields that change at different rates want different priorities.

### `struct` and `enum`

```btyn
struct Vec2i { x: i16, y: i16 }

enum Team { Red, Blue, Spectator }
```

A struct is laid out recursively and packs its own booleans internally. An enum
travels as one byte (two past 256 variants) and appears in Luau as a string
union — `"Red" | "Blue" | "Spectator"` — so call sites stay readable.

### `config`

```btyn
config {
    server = "src/Server/Net.luau"
    client = "src/Client/Net.luau"
}
```

| Key | Default | Meaning |
|---|---|---|
| `server` | *required* | Where to write the server module |
| `client` | *required* | Where to write the client module |
| `runtime` | `game:GetService("ReplicatedStorage"):WaitForChild("BTYN")` | Luau expression the generated files use to reach the runtime |
| `budget` | `40000` | Soft per-client outbound budget, bytes/second |
| `unreliable_cap` | `800` | Largest unreliable payload, bytes |
| `request_timeout` | `10` | Seconds before an unanswered request fails |
| `write_checks` | `true` | Validate on the way out as well as in |
| `manual` | `false` | Flush by hand instead of on Heartbeat |

On `unreliable_cap`: Roblox does not publish this number, and community
measurement puts it near 1000 bytes. The default sits well below that on
purpose — undershooting costs a few bytes per packet, overshooting costs silent
data loss. Measure on your own place before raising it.

On `write_checks`: the receiving side always validates, because that is the
trust boundary. This flag only controls the sending side, where the cost buys
you catching `hp = 300` at the call site instead of watching it silently
truncate to 44 and arrive as a mystery. Leave it on until a profile says
otherwise.

## Types

### Numbers

`u8` `u16` `u32` · `i8` `i16` `i32` · `f32` `f64`

Any of them takes an optional inclusive range, validated on both sides:

```btyn
hp:   u8(0..100),
temp: i16(-50..50),
```

A range that cannot fit its type is a compile error.

### `bool`

Costs one **bit**, not one byte. Every boolean in a packet is collected into a
bitfield at the front, written with one store per 32 flags.

### `entity`

A `u32` you own the meaning of. It exists as its own name to steer you away from
`Instance`, which cannot live in a buffer at all, costs real bandwidth, and
arrives `nil` when the receiver has not streamed the object in yet.

### `string(n)`

The cap is **required**. An uncapped string is an uncapped packet, which is both
a bandwidth leak and a free amplification primitive. The length prefix is one
byte up to 255, two beyond.

### `[T; n]`

An array with a required cap, same reasoning. `[u16; 100]` is at most 201 bytes.

### `T?`

Optional. When `T` is fixed-size this costs **one bit** and keeps the packet on
the constant-offset fast path — the payload bytes are always written, zeroed
when absent. When `T` is dynamic it costs a presence byte instead.

### Roblox values

| Type | Bytes | Notes |
|---|---|---|
| `vec3` | 12 | 3 × `f32` |
| `cframe` | 18 | position as 3 × `f32`, rotation as quantised euler angles |
| `color3` | 3 | one byte per channel |
| `unit` | 6 | unit vector, each component quantised to `i16` |
| `angle` | 2 | radians quantised across `[-pi, pi]` |
| `Instance` | 2 | index into a sidecar array — see below |

### `fixed(min, max, bytes)`

A float quantised into a fixed range. `bytes` is 1, 2 or 4.

```btyn
blend: fixed(-1, 1, 2),
```

Two bytes gives 65536 steps across the range, finer than anything a player
perceives. This is usually the right answer when you were about to reach for
`f32`.

### `Instance`

Buffers hold bytes, so an Instance cannot go in one. BTYN writes an index and
carries the reference alongside the payload.

It works, and you should still prefer `entity`. Instance references cost
bandwidth, and arrive `nil` when the receiver has not loaded the object yet — a
bug that only shows up on a slow connection. A broadcast carrying an `Instance`
also gives up the serialise-once fast path, because indices are relative to the
batch that holds them.

---

Next: [the generated API](api.md) · [performance](performance.md) · [security](security.md)
