<img src="icon.png" width="78" align="right" alt="">

# BTYN for VS Code

Highlighting, completion, hover and live diagnostics for `.btyn` networking
schemas.

## What you get

**Syntax highlighting.** A TextMate grammar that respects the language's own
rule: BTYN has no reserved words, so `from`, `rate` and `event` are matched by
position and a field legitimately named `rate` stays a field.

**Completion**, aware of where the cursor is:

| Context | Suggests |
|---|---|
| after `:` | every primitive, **plus the structs and enums declared in that file** |
| after `from ` | `client`, `server` |
| after `priority ` | `low`, `normal`, `high` |
| inside `config { }` | the ten valid keys, each with its default |
| at top level | the declaration keywords, as full snippets |

The first row is the one that earns its keep — it offers `Vec2i` and `Team`
because you declared them above, which no generic word-completion can do.

**Hover** showing what a type costs on the wire:

> **`u8`** — 1 byte
>
> **`bool`** — 1 bit. Every boolean in a packet shares a bitfield at the front,
> so 32 flags cost 4 bytes and a single store.
>
> **`entity`** — 4 bytes. Prefer this over `Instance`, which cannot live in a
> buffer, costs real bandwidth, and arrives `nil` when the receiver has not
> streamed the object in yet.

Hovering a struct or enum you declared shows its definition.

**Diagnostics**, by running the real compiler as you type. Nothing about the
schema rules is reimplemented here — the compiler already knows every rule and
reports a line, a column and a span, so this runs it with `--json` and turns the
result into squiggles. A second implementation would disagree eventually.

It compiles the buffer as it stands, not the last save, so an error appears
before you reach for Ctrl+S. Errors carry their `help:` line through:

```
unknown type 'u9'
not a known type

help: did you mean 'u8'?
```

Diagnostics need [Lune](https://lune-org.github.io/docs) on your PATH and the
compiler somewhere above the file you are editing. Without either, highlighting
and completion still work and nothing complains twice.

| Setting | Default | |
|---|---|---|
| `btyn.diagnostics.enabled` | `true` | Turn the compiler pass off |
| `btyn.lunePath` | `lune` | Where to find Lune |
| `btyn.compilerPath` | *auto* | Path to `cli/main.luau`; empty finds the nearest one above the file |

## Install

```bash
cd editors/vscode
npx @vscode/vsce package --skip-license
code --install-extension btyn-0.1.0.vsix
```

Then restart VS Code, or run `Developer: Reload Window`.

Copying the folder into `~/.vscode/extensions/` does **not** work on its own:
VS Code keeps a registry in `extensions.json` and ignores directories that are
not in it. `code --install-extension` is what writes that entry.

To confirm it took, `Extensions: Show Installed Extensions` should list **BTYN**,
and the language indicator in the status bar should read `BTYN` when a `.btyn`
file is open.

## The file icon

VS Code has no additive file-icon API. An extension can only contribute a whole
icon theme, and activating one replaces whatever you were using — there is no
way to inject a single icon into someone else's theme. So there are two routes,
and the right one depends on whether you already have a theme you like.

**If you already use an icon theme** (Material, vscode-icons, charmed-icons, …),
patch the BTYN icon into it and keep everything else:

```bash
node ~/.vscode/extensions/btyn.btyn-0.1.0/scripts/patch-icon-theme.js
```

It reads `workbench.iconTheme` from your settings, finds the extension that owns
it, and adds the icon to every variant that extension ships — so switching
between its light and dark flavours keeps working. The original files are backed
up first:

```bash
node scripts/patch-icon-theme.js --undo
```

Updating the patched extension replaces its files, so re-run the patch if the
icon ever disappears. That is the cost of the route; nothing else is touched.

**If you have no icon theme you care about**, select the bundled one instead —
`Preferences: File Icon Theme` → **BTYN**. Self-contained and never breaks on an
update, but it is deliberately minimal: the logo on `.btyn`, and neutral
fallbacks for everything else. It is not an attempt to replace a real icon set.

## What it highlights

The one thing worth knowing: **BTYN has no reserved words.** `from`, `rate`,
`event` and `channel` are matched by position, so a field legitimately named
`rate` stays a field:

```btyn
event Attack from client rate 10 {
    rate: u8,     -- a field, not a keyword
    from: u8,     -- also fine
}
```

The grammar mirrors that rule rather than keyword-matching blindly, and the
test suite pins it.

| Element | Scope |
|---|---|
| `event` `unreliable` `request` `channel` `struct` | `keyword.declaration` |
| declaration name | `entity.name.type` |
| `from` `rate` `priority` | `keyword.other.modifier` |
| `client` `server` `low` `normal` `high` | `constant.language` |
| `u8` … `Instance` `string` `fixed` | `support.type.primitive` |
| struct and enum references | `entity.name.type` |
| enum variants | `constant.other.enum` |
| field names | `variable.other.member` |
| known `config` keys | `support.type.property-name` |
| unknown `config` keys | `invalid.deprecated` |
| `->` `..` `?` | `keyword.operator` |

An unrecognised `config` key is deliberately marked invalid — a typo'd
`serverr` is a compile error, and it should look wrong before you run the
compiler.

## Snippets

`config`, `event`, `eventrate`, `unreliable`, `request`, `channel`, `struct`,
`enum`, `string`, `array`, `ranged`, `fixed`.

The `string` and `array` snippets include the cap, because it is mandatory in
the language — an uncapped string is an uncapped packet.

## Tests

```bash
npm install
npm test
```

**Grammar** — a TextMate grammar is a pile of order-dependent regex, so
eyeballing colours is not a test. This runs the same tokeniser VS Code uses and
asserts the resulting scopes: every declaration form, the contextual-keyword
cases, comment handling (a commented-out declaration must highlight nothing),
and that every token in `examples/net.btyn` receives a scope.

**Language model** — the context detection behind completion lives in
`src/language.js` with no `vscode` import precisely so it can be tested. Covers
each cursor context, and that braces inside comments and strings do not fool the
block scanner.

It also checks the model against the compiler: every byte size in a hover card
is compared to `cli/Ast.luau`, and the offered `config` keys to
`cli/Analyze.luau`. A hover that quotes a stale byte count is worse than one
that says nothing, so the two are made to agree by test rather than by memory.
