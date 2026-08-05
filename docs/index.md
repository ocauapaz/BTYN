---
title: A networking compiler for Roblox
lang: en
---

<div class="hero" markdown="1">

# BTYN

<p class="lead">You write a schema; it writes the fastest correct Luau for that exact schema, for both sides. Two remotes for your whole game, batched once per frame.</p>

</div>

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

<ul class="cards">
<li><a href="{{ site.baseurl }}/en/"><strong>Getting started</strong><span>Install, write a schema, compile it.</span></a></li>
<li><a href="{{ site.baseurl }}/en/schema/"><strong>Schema language</strong><span>Declarations, types, config.</span></a></li>
<li><a href="{{ site.baseurl }}/en/api/"><strong>Generated API</strong><span>What you call on each side.</span></a></li>
<li><a href="{{ site.baseurl }}/en/performance/"><strong>Performance</strong><span>The engine's limits, and what to do about them.</span></a></li>
<li><a href="{{ site.baseurl }}/en/security/"><strong>Security</strong><span>What buffers do and do not protect.</span></a></li>
<li><a href="{{ site.baseurl }}/pt-br/"><strong>Português</strong><span>Documentação completa em português.</span></a></li>
</ul>

## Why

Roblox gives you about 50 KB/s per client before it throttles *all* replication,
charges roughly 9 bytes of header per remote call, and silently discards an
oversized `UnreliableRemoteEvent` payload. The known answer is one reliable
remote plus one unreliable one, batched per frame, with hand-written `buffer`
serialisation. That works, and it is tedious and easy to get wrong.

BTYN is that answer, generated.

## What a compiler buys over a runtime schema

**Constant offsets.** A fixed-size packet compiles to a straight line, with no
cursor variable and no per-field type dispatch:

```luau
local function writeAttack(b: buffer, o: number, v: Attack, refs: { Instance }): number
    local w1 = 0
    if v.crit then w1 += 1 end
    if v.stun then w1 += 2 end
    buffer.writeu8(b, o, w1)
    buffer.writeu32(b, o + 1, v.target)
    buffer.writeu8(b, o + 5, v.combo)
    return 6
end
```

**Packed booleans.** 32 flags become one `u32` store, not 32 byte writes.

**One bounds check.** Sizes are known, so a packet is validated once on entry
instead of per field — faster *and* safer than checking nothing.

**Real types.** Luau has no mapped types, so a table-based schema *cannot* infer
its own payload type. A compiler just writes it out.

**Oversize caught at build time.** The compiler knows every packet's worst case
and fails the build if an `unreliable` cannot fit the payload cap, rather than
letting the engine drop it in production without a word.

## What it does that the libraries do not

- **Interest management.** Channels carry an explicit audience. The cheapest
  packet is the one never sent, and a player joining an audience gets a keyframe
  automatically.
- **Priority budgets.** When a client is over its per-frame byte budget,
  low-priority deltas defer and coalesce. Nothing is lost, and the throttle is
  never reached.
- **Serialise-once broadcast.** A filtered broadcast encodes one time and
  memcpys into each recipient's batch.
- **Mandatory caps.** An uncapped `string` or array is a compile error, not a
  default.

## Measured in a running game

The [Studio integration test](https://github.com/ocauapaz/BTYN/tree/main/tests/studio)
checks the claims against real RemoteEvents rather than a benchmark harness:

| | |
|---|---|
| 25 client packets (5 Attacks, 20 Chats) | left in **2** remote fires |
| 3 unreliable Aims | left in **1** |
| Health keyframe → delta of one field | 9 B → **7 B** |
| Re-setting a field to the value it holds | sent **nothing** |
| 20 Chats against `rate 2` | 2 decoded, 18 reported |
| Remotes in the whole place | **2** |

Every figure reconciles exactly with what `--check` predicts for the schema.
