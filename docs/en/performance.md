---
title: Performance
lang: en
---

# Performance

[← Docs index](README.md)

## The limits you are actually working against

| | | |
|---|---|---|
| Bandwidth per client | ~50 KB/s before throttling | Going over delays *all* replication — characters, physics, properties — not just your packets |
| Overhead per remote call | ~9 bytes | 100 small messages a frame is ~900 bytes of pure header |
| Client request rate | ~500/s, shared across remotes of a kind | Remote spam is throttled before you notice |
| Unreliable payload | dropped above the cap | No error. The packet simply never arrives |
| Safe send rate | degrades above ~60 Hz | Batching per frame is not optional |

The 50 KB/s is shared with the engine's own character and physics replication.
Only part of it is yours to spend.

## What BTYN does about it

### Two remotes, batched per frame

Every packet in a frame goes into one send. Header overhead is paid twice a
frame instead of once per message, and ordinary gameplay traffic stops being
able to reach the request-rate limit.

### Constant offsets

A fixed-size packet compiles to a straight line with no cursor and no type
dispatch:

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

This is what a compiler buys. A runtime schema has to walk a table and branch on
each field's type every single call; there is nothing left here to walk.

### Packed booleans

Every boolean in a packet shares a bitfield at the front. 32 flags cost 4 bytes
and one `writeu32`. This is the case where the gap between a compiled and an
interpreted schema is widest.

### One bounds check per packet

Sizes are known, so a fixed packet is validated once on entry rather than before
every field. Faster *and* safer than checking nothing.

### Serialise-once broadcast

`all`, `list` and `except` encode the packet a single time into a scratch buffer
and `buffer.copy` it into each recipient's batch. Forty players cost one
serialisation and forty memcpys.

### One allocation per flush

Streams are reused across frames and grow by doubling. The only allocation on
the send path is the exactly-sized buffer handed to the remote, once per flush.

### Delta encoding and interest management

Covered in [the API guide](api.md#channels). Two effects, and the second is
larger: send only what changed, and only to players it matters to.

## Techniques that matter more than any library

In rough order of impact. A library optimises the generic case; these are about
your specific one, and they win by more.

**1. Do not send.** The cheapest packet is the one that does not exist. Replicate
only what is in a player's radius of relevance, send on change rather than on a
timer, and let the client derive whatever it can derive.

**2. Lower the rate.** Plenty of things running at 60 Hz look identical at 10 Hz
with client interpolation. NPC movement is the classic: six updates a second,
interpolated, is indistinguishable from sixty in play.

**3. Quantise.** Position rarely needs `f64`. Angles fit in one or two bytes.
Health fits in a `u8` if the maximum is 100. Use `fixed(min, max, bytes)` and
`angle` rather than reaching for `f32` by reflex.

**4. Bitpack.** 32 booleans fit in a `u32` — BTYN does this for you. Enums
become a byte.

**5. Delta encode.** Send what changed, behind a mask. That is what channels are.

**6. Opcodes, never strings.** Never send `"FireballCast"`. BTYN assigns every
packet a numeric opcode at compile time; you never see a name on the wire.

**7. Be careful with `Instance`.** References are expensive and arrive `nil`
when the receiver has not streamed the object in. Prefer `entity`.

## Measuring

Trust your own game over anyone's benchmark, including this page. Use the
**MicroProfiler's network profiler** and the network stats panel, at a realistic
player count, and watch three things:

- **KB/s received per client** — target comfortably under 50
- **CPU time in serialisation per frame**
- **Memory growth across a long session**

`--check` tells you what the compiler knows statically:

```bash
lune run cli/main -- net.btyn --check
```

```
  [9    ] Muzzle         unreliable     server -> client  18 B

  largest unreliable packet: 19 B of the 800 B cap
```

There is a headless codec benchmark in the repo:

```bash
lune run bench/run
```

```
  fixed, 3 fields             7 B   encode     8.0M/s   decode    10.9M/s
  32 booleans                 4 B   encode     1.3M/s   decode     1.6M/s
  quantised vec3 + unit      18 B   encode     3.2M/s   decode     3.4M/s
  dynamic string              6 B   encode     4.0M/s   decode     7.1M/s
```

It measures CPU and wire size for the generated codecs, with payloads that vary
every iteration. It deliberately does **not** claim to be a library comparison —
that needs the other libraries and a real place to run them in. Note the 4 bytes
for 32 booleans; that is the number worth looking at on that row.

### On benchmarks

Networking benchmarks in this ecosystem are unusually easy to get wrong. A
widely circulated result once showed a library sending almost nothing, because
it XORed against a previous frame that was identical — the payload was constant,
so the deltas were all zero. It was measuring a bug.

If you benchmark:

- Use data that **changes every frame**. Constant payloads flatter any delta or
  XOR scheme enormously.
- **Measure memory**, not just throughput and frame rate.
- Watch for **batching that moves bytes outside your measurement window** rather
  than removing them.
- Compare like with like: bandwidth differences between buffer-based libraries
  are typically under 3%. The real spread is in CPU.

---

Next: [security](security.md) · [compiler and editor](cli.md) · [schema reference](schema.md) · [API](api.md)
