---
title: Security
lang: en
---

# Security

[← Docs index](README.md)

## Buffers are not security

Serialising to a buffer is obfuscation. It makes a RemoteSpy dump unreadable and
raises the effort required, and that is the entire benefit. An exploiter willing
to spend an afternoon on your format will decode it.

Any library selling buffer serialisation as a security feature is selling you
something it does not have. BTYN included — what follows is what it actually
gives you.

## What actually protects you

### The server decides

Nothing replaces this. The client asks; the server rules. Damage, currency,
progression, inventory, cooldowns — all of it decided server-side, from
server-held state.

BTYN makes this the path of least resistance: a `from client` event gives the
client `.fire` and only `.fire`. There is no API for the client to assert state.
But the design is yours, and no schema can enforce it.

### Shape validation on receipt

This is the real, concrete security win over raw remotes, and it is not small.
Every field is validated before your code runs:

- **Bounds** — a packet claiming to be longer than the batch it arrived in is
  rejected
- **Ranges** — `u8(0..100)` rejects 200 on arrival, not after it reaches your
  damage formula
- **Lengths** — `string(24)` and `[u16; 100]` reject anything longer, so there is
  no unbounded allocation from a hostile sender
- **Finiteness** — `NaN` and infinity are rejected on every float, including the
  components of `vec3` and the position of a `cframe`, which closes the classic
  route to poisoning a physics or economy calculation
- **Enums** — an index outside the declared variants is rejected
- **Directions** — a `unit` is normalised on arrival. The raw encoding allows a
  vector of magnitude 1.73, which a hitscan trusting the name would turn into
  73% of extra reach
- **Instances** — an `Instance` field is checked to actually hold one. The
  sidecar array that carries them is sender-controlled, and nothing else stops a
  client putting a string or a table where your type says `Instance`
- **Batch size** — a batch carrying more than `max_packets_per_batch` packets
  (256 by default) is refused. The smallest packet is a single opcode byte, so
  without a ceiling one payload becomes tens of thousands of handler calls in a
  frame — an amplification the per-packet rate limits cannot see, because they
  are only reached once the work has already been done
- **Channels** — a packet has to arrive on the remote its schema declares. Both
  remotes feed the same dispatch table, so otherwise a client could send
  anything down either one and help itself to both of the engine's throttles

Caps are mandatory in the schema for exactly this reason. An uncapped `string`
is not a convenience, it is an amplification primitive, so BTYN makes it a
compile error rather than a default.

Together this eliminates a whole class of attack: malformed payloads, giant
strings, unbounded arrays, `NaN` poisoning, and batch amplification. It is the
largest genuine security difference between a schema-validated transport and
hand-rolled remotes.

What it does **not** validate is `entity`. That type is a bare `u32` naming
something your game owns, and only your game knows which ids a given player may
name — see the handler example below.

### Rate limiting

```btyn
event Attack from client rate 10 { target: entity }
```

A token bucket per player per packet, enforced on the receiving side. Without
one, a single client can consume the engine's ~500 requests/second budget and
degrade the server for everyone.

An over-budget packet is dropped and reported — never queued, because queueing
an abusive sender just moves the cost somewhere less visible.

The rate must be greater than zero. A bucket that never refills would hand out
its initial burst and then refuse the packet forever, which reads as the event
being broken rather than as the limit it is, so it is a compile error.

Leaving `rate` off a client-sent packet is a compile **warning**. It still
builds — a schema in progress has every right to be incomplete — but it is the
one item on the checklist below that the compiler can check for you, so it
does.

```luau
Net.onAbuse(function(player, reason)
    warn(`{player}: {reason}`)
end)
```

`onAbuse` also fires on validation failure. On the server that means a client
sent something the schema does not permit, which an honest client cannot do —
the same compiler wrote both sides. It is a strong signal, worth logging and
worth acting on.

### A smaller surface

Two remotes for the whole game, named `R` and `U`, instead of eighty helpfully
named ones. An exploiter enumerating remotes learns nothing from the names, and
there is no per-feature endpoint to probe in isolation.

The client module also carries only its own half of the protocol — no reader for
packets the server never sends it, no writer for packets it never sends.

### The engine's own separation

`UnreliableRemoteEvent` has its own internal throttle, separate from the
reliable path. Abuse of the unreliable channel cannot take down general
replication with it — another reason to keep cosmetic traffic on `unreliable`
and consequential traffic on `event`.

### Replies are bound to their peer

A `request` from the server carries a correlation id, and the registry holding
those ids is shared across every player on the server. A reply is only accepted
from the player the request was actually sent to. Without that binding, ids
being sequential, any client could answer — or blind-scan every id and answer —
a question the server asked somebody else.

A forged reply is dropped as silently as a late one. An attacker learns nothing
from the difference.

## Handlers run on their own thread

Your handler is resumed on a fresh thread rather than inline in the batch walk.
An error in one handler cannot discard the rest of the batch or be misreported
as the sender's abuse, and a handler that yields cannot stall the packets
behind it.

The trade is that two handlers in the same batch have no completion order if
the first one yields. If a pair of packets is only safe in sequence — a charge
and its release — validate before you yield, or carry the ordering in the
payload rather than relying on arrival.

## What BTYN cannot do for you

The schema guarantees `amount` is a `u16` in the range you declared. Only you
can guarantee that this player could deal that damage, to that target, at that
distance, off that cooldown, in that game state.

Semantic validation is the part that actually stops cheating, and it lives in
your handlers:

```luau
Net.Attack.on(function(player, data)
    -- The schema proved the shape. Everything below is yours.
    local attacker = characterOf(player)
    if not attacker then return end
    if not onCooldown:ready(player) then return end

    local target = entities[data.target]
    if not target then return end
    if (target.position - attacker.position).Magnitude > MAX_REACH then return end

    applyDamage(target, weaponDamage(player))   -- server-held, never sent
end)
```

Note the last line: the damage number comes from server state, not from the
packet. If a value can be derived server-side, it should never be on the wire at
all — a field that does not exist cannot be forged.

## Checklist

- [ ] Every consequential decision is made server-side from server-held state
- [ ] Values the server can derive are not sent by the client
- [ ] Client-to-server packets carry a `rate` (the compiler warns when they do not)
- [ ] Every `entity` id is checked for existence and ownership before it is used
- [ ] `onAbuse` is wired to your logging
- [ ] Ranges are declared (`u8(0..100)`) rather than left wide
- [ ] Caps are as tight as the real data, not just tight enough to compile
- [ ] Handlers validate ownership, distance, cooldown and game state
- [ ] `write_checks` is on, or deliberately off with a reason

---

Next: [schema reference](schema.md) · [API](api.md) · [troubleshooting](troubleshooting.md) · [performance](performance.md)
