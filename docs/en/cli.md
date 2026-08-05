---
title: Compiler and editor
lang: en
---

# The compiler

[← Docs index](README.md)

One argument, one schema:

```bash
lune run cli/main -- net.btyn
```

The output paths live in the schema's own `config` block, not on the command
line, so the schema stays the single source of truth and the command never
changes as the project grows.

```
btyn: wrote src/Server/Net.luau
btyn: wrote src/Client/Net.luau
```

Missing directories along those paths are created. Both files are rewritten
every run — they are build output, so put them in `.gitignore` unless your
team prefers to review generated diffs.

## Flags

| Flag | Effect |
|---|---|
| *(none)* | Compile and write both modules |
| `--check` | Validate and report sizes, write nothing |
| `--watch` | Recompile whenever the schema changes |
| `--json` | Machine-readable diagnostics and packet data, write nothing |
| `--help`, `-h` | Usage |

`--check` and `--watch` combine: `--watch --check` re-reports sizes on every
save without touching your source tree.

### `--check`

The one to reach for when you want to know what a schema costs before
committing to it.

```bash
lune run cli/main -- net.btyn --check
```

```
btyn: net.btyn is valid — 9 packet(s), 1 byte opcodes

  [0    ] Aim            unreliable     client -> server  4 B  rate 120/s
  [2    ] Attack         event          client -> server  6 B  rate 10/s
  [3,4  ] Buy            request        client -> server  3 B -> 6-70 B  rate 4/s
  [7,8  ] Health         channel/high   server -> client  3 B

  largest unreliable packet: 19 B of the 800 B cap
```

Reading it: the bracketed numbers are opcodes — a request and a channel take
two each, one for the reply or the removal. A single size is a fixed packet; a
range means a string or array makes it vary, and the upper end is what the
`unreliable` cap is checked against.

The last line is the one to watch. It is the distance between your largest
unreliable packet and the size at which the engine starts discarding them
without an error.

### `--watch`

Polls the schema and recompiles on change. Leave it running beside
`rojo serve` and the generated modules track the schema on save.

```bash
lune run cli/main -- net.btyn --watch
```

A failed compile prints the error and keeps watching, so a typo does not cost
you the loop. Editors that delete and recreate the file on save are handled —
the watcher waits for it to come back rather than exiting.

### `--json`

For editors and tooling. Never writes files, and always exits `0` so a caller
never has to special-case a broken schema.

```bash
lune run cli/main -- net.btyn --json
```

```json
{
  "ok": true,
  "diagnostics": [],
  "warnings": [
    {
      "severity": "warning",
      "message": "'Aim' is sent by the client and has no rate limit",
      "label": "no `rate` here",
      "help": "add `rate <n>` — ...",
      "line": 52,
      "column": 12,
      "length": 3
    }
  ],
  "packets": [
    { "name": "Attack", "kind": "event", "from": "client", "opcode": 2,
      "size": 6, "maxSize": 6, "fixed": true, "rate": 10, "line": 30 }
  ],
  "opcodeBytes": 1,
  "unreliableCap": 800,
  "budget": 40000
}
```

`line` and `column` are one-based, which is what editors expect to be handed.
Consume this rather than scraping the pretty output — that output exists for
humans and is free to change shape.

## Errors and warnings

An **error** stops the build and writes nothing:

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

The analyzer collects every error it can before stopping, so one run tells you
about all of them rather than making you fix them one at a time. The parser is
the exception: once the token stream is wrong every later message is invented,
so it stops at the first syntax error.

A **warning** is printed and the build continues:

```
warning: 'Aim' is sent by the client and has no rate limit
  --> net.btyn:52:12
   |
52 | unreliable Aim from client {
   |            ^^^ no `rate` here
   |
help: add `rate <n>` — without one a single client can send this as fast as it
      likes, and only the batch ceiling of 256 packets stands in the way
```

Missing `rate` on a client-sent packet is the one item on the
[security checklist](security.md#checklist) the compiler can check for you, so
it does. A schema still under construction has every right to be incomplete,
which is why it does not fail the build.

## Exit codes

| Code | When |
|---|---|
| `0` | Compiled, or `--check` passed, or **any** `--json` run |
| `1` | Errors, or the schema file does not exist |

In CI, `--check` is the one to run: it fails the build on a bad schema without
producing files nobody is going to commit.

```yaml
- name: Validate the schema
  run: lune run cli/main -- net.btyn --check
```

# Editor support

The [VS Code extension](https://github.com/ocauapaz/BTYN/tree/main/editors/vscode)
covers `.btyn` files:

- **Highlighting** for declarations, types, modifiers and comments
- **Completion** that knows where it is — declaration keywords at top level,
  types after a `:`, config keys inside a `config` block
- **Hover** giving each type's wire cost and the reasoning behind it
- **Live diagnostics** from the compiler itself, so the squiggles are exactly
  what the build will say

It is not on the Marketplace. Build and install it from the repository:

```bash
cd editors/vscode && npx @vscode/vsce package --skip-license && code --install-extension btyn-0.1.0.vsix
```

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `btyn.diagnostics.enabled` | `true` | Run the compiler as you type |
| `btyn.lunePath` | `lune` | Path to the Lune executable |
| `btyn.compilerPath` | *(empty)* | Path to `cli/main.luau`; empty finds the nearest one above the open file |

Diagnostics shell out to `lune run <compiler> -- <file> --json`, debounced so
typing does not spawn a compiler per keystroke. If squiggles never appear, that
command is what to run by hand — most of the time Lune is not on `PATH`, which
`btyn.lunePath` fixes.

The extension needs no configuration in a normal checkout: it walks up from the
open file until it finds `cli/main.luau`.

---

Next: [troubleshooting](troubleshooting.md) · [schema reference](schema.md) · [API](api.md)
