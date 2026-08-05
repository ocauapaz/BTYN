---
title: Troubleshooting
lang: en
---

# Troubleshooting

[← Docs index](README.md)

Symptoms in the order people actually hit them.

## `Infinite yield possible on 'ReplicatedStorage:WaitForChild("BTYN")'`

The runtime is not in the game, or not where the generated code looks for it.

The generated modules reach the runtime through the `runtime` config key, which
defaults to `ReplicatedStorage.BTYN`. Something has to put `src/` there. In this
repository that is `default.project.json`:

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

Which produces:

```
ReplicatedStorage
└── BTYN              (ModuleScript, from src/init.luau)
    ├── Stream
    ├── Transport
    ├── Channel
    ├── RateLimiter
    └── Request
```

If your game keeps packages elsewhere, point the schema at them instead of
moving anything:

```btyn
config {
    runtime = "game.ReplicatedStorage.Packages.BTYN"
}
```

The value is a Luau expression pasted into a `require` on both sides, so
anything that resolves works.

## `attempt to call a nil value` on `Net.Something.fire` or `.on`

You are on the wrong side of `from`.

The generated API is deliberately asymmetric — each side gets only the half it
takes part in, so calling the wrong one fails loudly instead of silently doing
nothing.

| Declaration | Client gets | Server gets |
|---|---|---|
| `event X from client` | `.fire` | `.on` |
| `event X from server` | `.on` | `.to` `.all` `.list` `.except` |
| `request X from client` | `.call` `.try` | `.on` |
| `request X from server` | `.on` | `.call` `.try` |
| `channel X` | `.on` `.onRemove` `.get` | `.of` |

If you meant the other direction, change `from` in the schema and recompile.

## `btyn: unknown opcode 7` arriving in `onAbuse`

The two sides were built from different versions of the schema.

Opcodes are assigned by sorted packet name, so adding a packet called `Aaa`
renumbers everything after it. That is fine — both files are written by the same
run — but it means **the server and client modules must ship together**. A
server updated without its client, or a client cached from a previous build,
will disagree about what opcode 7 means.

Recompile and deploy both. If you see this in production, check that whatever
copies the generated files does not treat them as two independent artifacts.

## A channel sends nothing

Its audience is empty, which is the default.

```luau
local health = Net.Health.of(id)
health.set({ hp = 100 })     -- goes nowhere: nobody is listening
```

A channel replicates to the players you name and to nobody else — that is the
interest management, and an empty default is the safe one. Say who cares:

```luau
health.audience(playersWithin(120, position))
```

Players entering the audience get a keyframe automatically; players leaving are
told to drop the entity.

## Nothing sends at all, and `manual = true`

With `manual` set, nothing flushes on its own. Call it:

```luau
Net.flush()
```

Batches accumulate until you do. If you set `manual` to control *when* traffic
goes out, make sure every path that can queue a packet reaches a flush —
including the ones that only run occasionally.

## `btyn: 'hp' is not a field of this channel`

A typo in `set`, or a field that is on a different channel. The error names the
key it was given; the schema's `channel` block is the list of what is legal.

This is checked at runtime rather than by the type system because `set` takes a
partial table, and Luau cannot express "some subset of these keys" tightly
enough to catch it at the call site.

## A value arrives truncated or clamped

Either the declared type is too narrow, or writing checks are off.

Writing `300` into a `u8` truncates to `44`. With `write_checks` on — the
default — you get an error at the call site instead:

```
btyn: hp must be between 0 and 255, got 300
```

If you turned `write_checks` off for release builds and something is arriving
wrong, turn it back on in a development build and reproduce there. The
receiving side always validates regardless of that setting, so the packet would
be rejected in flight rather than delivered wrong — check `onAbuse`.

Quantised types are lossy by design: `fixed(-1, 1, 2)` has ~65536 steps across
its range, `angle` resolves to about 0.0001 radians, and `unit` is normalised on
arrival. If you need the exact float back, use `f32`.

## A request always times out

Three causes, in order of likelihood.

**The responder returned `nil`.** That is the rejection path, and it reaches the
caller as a failure rather than a timeout — `call` throws, `try` returns
`false`. If you meant to answer, return a table.

**The responder threw.** Its handler runs inside a `pcall`, so an error becomes
a rejection. Check the server output for the error itself.

**Nothing is flushing.** See `manual` above. Requests ride the ordinary batch,
so a request sent with no flush never leaves.

The deadline is `request_timeout`, default 10 seconds. A reply arriving after it
is dropped rather than delivered late.

## `exceeded its rate limit` on traffic that looks reasonable

The bucket holds one second of budget. `rate 10` allows a burst of ten and
refills at ten per second — so ten calls in one frame are fine, and twenty are
not, even though twenty over two seconds would be.

If a legitimate burst is larger than the sustained rate, raise the rate to cover
the burst rather than the average. If the burst is a loop, consider whether it
should be one packet carrying an array instead of many packets.

## `batch carries more than 256 packets`

A client sent more packets in one frame than the ceiling allows. From an
ordinary client this does not happen: a busy frame of input is a handful of
packets.

If you have a legitimate case — a building game committing a large edit as many
small packets — raise the ceiling:

```btyn
config { max_packets_per_batch = 1024 }
```

Prefer restructuring first. One packet carrying `[Edit; 512]` costs a fraction
of 512 packets carrying one edit each, in both bytes and CPU.

## An `Instance` field arrives `nil`

The receiver has not streamed that object in, or it was destroyed between send
and receive.

This is inherent to Instance references, not something BTYN can fix — it is why
`entity` exists. A `u32` id your game owns always arrives, means the same thing
on both sides, and costs four bytes with no sidecar array. Prefer it.

## `typescript` output fails the build

```
error: `typescript` output is not implemented yet
```

It is not implemented, and failing is deliberate — accepting the flag and
quietly emitting nothing would leave a roblox-ts build to discover the missing
declarations much later. Remove the key. The generated Luau is fully typed and
usable from Luau today.

## Studio does not see a recompile

Rojo syncs files it is watching. Check that the paths in your `config` block sit
inside the tree `default.project.json` maps, and that `rojo serve` is running.
Compiling writes the files whether or not anything is syncing them.

Running the compiler in `--watch` beside `rojo serve` is the setup this is
designed for — see [compiler and editor](cli.md).

## Something else

The [Studio integration test](https://github.com/ocauapaz/BTYN/tree/main/tests/studio)
exercises every packet kind against real remotes and prints byte counts as it
goes. Running it in a scratch place is often faster than instrumenting your own
game, and its numbers reconcile against what `--check` predicts.

---

Next: [compiler and editor](cli.md) · [API](api.md) · [security](security.md)
