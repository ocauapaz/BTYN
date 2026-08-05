// Tokenises sample schemas with the same engine VS Code uses, and asserts the
// scopes that come out.
//
// A TextMate grammar is a pile of regex with order-dependent behaviour, so
// eyeballing colours in an editor is not a test. The cases below pin the parts
// most likely to break: BTYN has no reserved words, which means every keyword
// is matched positionally and a field named `rate` or `from` must survive.
//
//     node test/grammar.test.js

const fs = require("fs")
const path = require("path")
const oniguruma = require("vscode-oniguruma")
const textmate = require("vscode-textmate")

const ROOT = path.join(__dirname, "..")
const GRAMMAR = path.join(ROOT, "syntaxes", "btyn.tmLanguage.json")

let passed = 0
let failed = 0
const failures = []

async function createRegistry() {
	const wasm = fs.readFileSync(
		path.join(ROOT, "node_modules", "vscode-oniguruma", "release", "onig.wasm")
	)
	await oniguruma.loadWASM(wasm.buffer)

	return new textmate.Registry({
		onigLib: Promise.resolve({
			createOnigScanner: (sources) => new oniguruma.OnigScanner(sources),
			createOnigString: (str) => new oniguruma.OnigString(str),
		}),
		loadGrammar: async (scopeName) => {
			if (scopeName !== "source.btyn") return null
			return textmate.parseRawGrammar(fs.readFileSync(GRAMMAR, "utf8"), GRAMMAR)
		},
	})
}

/** Tokenises source, returning [{ text, scopes }] with whitespace dropped. */
function tokenise(grammar, source) {
	const out = []
	let state = textmate.INITIAL

	for (const line of source.split("\n")) {
		const result = grammar.tokenizeLine(line, state)
		for (const token of result.tokens) {
			const text = line.substring(token.startIndex, token.endIndex)
			if (text.trim() === "") continue
			out.push({ text, scopes: token.scopes })
		}
		state = result.ruleStack
	}

	return out
}

/**
 * Asserts that `text` in `source` carries a scope containing `scopeFragment`.
 * `occurrence` picks which match when the text appears more than once.
 */
function check(grammar, label, source, text, scopeFragment, occurrence = 1) {
	const tokens = tokenise(grammar, source)
	const matches = tokens.filter((token) => token.text === text)

	if (matches.length < occurrence) {
		failed++
		failures.push(
			`${label}\n  token '${text}' #${occurrence} not found\n  got: ${tokens
				.map((t) => `'${t.text}'`)
				.join(" ")}`
		)
		return
	}

	const token = matches[occurrence - 1]
	const hit = token.scopes.some((scope) => scope.includes(scopeFragment))

	if (hit) {
		passed++
		console.log(`  \x1b[32mpass\x1b[0m  ${label}`)
	} else {
		failed++
		failures.push(`${label}\n  '${text}' expected a scope containing '${scopeFragment}'\n  got: ${token.scopes.join(", ")}`)
		console.log(`  \x1b[31mFAIL\x1b[0m  ${label}`)
	}
}

/** Asserts that no token in `source` carries a scope containing `scopeFragment`. */
function checkAbsent(grammar, label, source, scopeFragment) {
	const tokens = tokenise(grammar, source)
	const offender = tokens.find((token) => token.scopes.some((scope) => scope.includes(scopeFragment)))

	if (!offender) {
		passed++
		console.log(`  \x1b[32mpass\x1b[0m  ${label}`)
	} else {
		failed++
		failures.push(`${label}\n  '${offender.text}' unexpectedly carries '${scopeFragment}'\n  scopes: ${offender.scopes.join(", ")}`)
		console.log(`  \x1b[31mFAIL\x1b[0m  ${label}`)
	}
}

async function main() {
	const registry = await createRegistry()
	const grammar = await registry.loadGrammar("source.btyn")

	console.log("\n  Declarations")
	check(grammar, "event keyword", "event Attack from client { a: u8 }", "event", "keyword.declaration")
	check(grammar, "event name", "event Attack from client { a: u8 }", "Attack", "entity.name.type")
	check(grammar, "unreliable keyword", "unreliable Muzzle from server { a: u8 }", "unreliable", "keyword.declaration")
	check(grammar, "request keyword", "request Buy from client { a: u8 } -> { b: u8 }", "request", "keyword.declaration")
	check(grammar, "channel keyword", "channel Health { hp: u8 }", "channel", "keyword.declaration")
	check(grammar, "struct keyword", "struct Vec2i { x: i16 }", "struct", "keyword.declaration")

	console.log("\n  Modifiers")
	check(grammar, "from keyword", "event A from client { a: u8 }", "from", "keyword.other.modifier")
	check(grammar, "direction value", "event A from client { a: u8 }", "client", "constant.language.direction")
	check(grammar, "rate keyword", "event A from client rate 10 { a: u8 }", "rate", "keyword.other.modifier")
	check(grammar, "priority keyword", "channel H priority high { a: u8 }", "priority", "keyword.other.modifier")
	check(grammar, "priority value", "channel H priority high { a: u8 }", "high", "constant.language.priority")

	console.log("\n  Contextual keywords stay usable as field names")
	// BTYN has no reserved words. If these regress, a schema that legally uses
	// them as fields will look broken in the editor.
	check(grammar, "field named 'rate'", "event A from client { rate: u8 }", "rate", "variable.other.member")
	check(grammar, "field named 'from'", "event A from client { from: u8 }", "from", "variable.other.member", 2)
	check(grammar, "field named 'event'", "event A from client { event: u8 }", "event", "variable.other.member", 2)
	check(grammar, "field named 'priority'", "channel H { priority: u8 }", "priority", "variable.other.member")
	check(grammar, "field named 'channel'", "event A from client { channel: u8 }", "channel", "variable.other.member")
	check(grammar, "field named 'string'", "event A from client { string: u8 }", "string", "variable.other.member")

	console.log("\n  Types")
	check(grammar, "primitive u8", "event A from client { a: u8 }", "u8", "support.type.primitive")
	check(grammar, "primitive entity", "event A from client { a: entity }", "entity", "support.type.primitive")
	check(grammar, "primitive vec3", "event A from client { a: vec3 }", "vec3", "support.type.primitive")
	check(grammar, "primitive string", "event A from client { a: string(24) }", "string", "support.type.primitive")
	check(grammar, "primitive fixed", "event A from client { a: fixed(-1, 1, 2) }", "fixed", "support.type.primitive")
	check(grammar, "Instance escape hatch", "event A from client { a: Instance }", "Instance", "support.type.primitive")
	check(grammar, "user struct reference", "event A from client { at: Vec2i }", "Vec2i", "entity.name.type")

	console.log("\n  Fields and operators")
	check(grammar, "field name", "event A from client { target: entity }", "target", "variable.other.member")
	check(grammar, "colon separator", "event A from client { a: u8 }", ":", "punctuation.separator.key-value")
	check(grammar, "reply arrow", "request B from client { a: u8 } -> { b: u8 }", "->", "keyword.operator.reply")
	check(grammar, "range operator", "event A from client { hp: u8(0..100) }", "..", "keyword.operator.range")
	check(grammar, "optional marker", "event A from client { a: u8? }", "?", "keyword.operator.optional")
	check(grammar, "array separator", "event A from client { a: [u16; 100] }", ";", "punctuation.separator")
	check(grammar, "number literal", "event A from client rate 10 { a: u8 }", "10", "constant.numeric")

	console.log("\n  Enums")
	check(grammar, "enum keyword", "enum Team { Red, Blue }", "enum", "keyword.declaration.enum")
	check(grammar, "enum name", "enum Team { Red, Blue }", "Team", "entity.name.type.enum")
	check(grammar, "variant is a constant", "enum Team { Red, Blue }", "Red", "constant.other.enum")
	check(grammar, "second variant", "enum Team { Red, Blue }", "Blue", "constant.other.enum")

	console.log("\n  Config")
	check(grammar, "config keyword", 'config { server = "a.luau" }', "config", "keyword.control.config")
	check(grammar, "known key", 'config { server = "a.luau" }', "server", "support.type.property-name")
	// The quotes tokenise separately from the body, so the body is what to check.
	check(grammar, "string value", 'config { server = "a.luau" }', "a.luau", "string.quoted")
	check(grammar, "boolean value", "config { manual = true }", "true", "constant.language.boolean")
	check(grammar, "numeric value", "config { budget = 40000 }", "40000", "constant.numeric")
	// A typo'd key is flagged rather than silently looking correct.
	check(grammar, "unknown key is flagged", 'config { serverr = "a.luau" }', "serverr", "invalid")

	console.log("\n  Comments")
	// The `--` marker tokenises apart from the body, so the body is checked.
	check(grammar, "line comment", "-- a note", " a note", "comment.line")
	check(grammar, "block comment body", "--[[ note ]]", " note ", "comment.block")
	check(grammar, "block comment spans lines", "--[[ one\ntwo ]]", "two ", "comment.block")

	// The real risk: a commented-out declaration lighting up as if it were live.
	checkAbsent(
		grammar,
		"a commented-out declaration highlights nothing",
		"-- event Attack from client { hp: u8 }",
		"keyword.declaration"
	)
	checkAbsent(
		grammar,
		"a block-commented declaration highlights nothing",
		"--[[ event Attack from client ]]",
		"keyword.declaration"
	)
	checkAbsent(grammar, "a type name inside a comment is not a type", "-- takes a vec3", "support.type")

	console.log("\n  Real schema")
	const example = fs.readFileSync(path.join(ROOT, "..", "..", "examples", "net.btyn"), "utf8")
	const tokens = tokenise(grammar, example)
	const unscoped = tokens.filter((token) => token.scopes.length === 1)

	if (unscoped.length === 0) {
		passed++
		console.log(`  \x1b[32mpass\x1b[0m  every token in examples/net.btyn is scoped`)
	} else {
		failed++
		failures.push(
			`examples/net.btyn has ${unscoped.length} unscoped token(s): ${unscoped
				.slice(0, 12)
				.map((t) => `'${t.text}'`)
				.join(" ")}`
		)
		console.log(`  \x1b[31mFAIL\x1b[0m  every token in examples/net.btyn is scoped`)
	}

	console.log("")
	if (failed > 0) {
		for (const failure of failures) {
			console.log(`\x1b[31m----\x1b[0m ${failure}\n`)
		}
		console.log(`\x1b[31m${failed} failed\x1b[0m, ${passed} passed`)
		process.exit(1)
	}

	console.log(`\x1b[32m${passed} passed\x1b[0m`)
}

main().catch((error) => {
	console.error(error)
	process.exit(1)
})
