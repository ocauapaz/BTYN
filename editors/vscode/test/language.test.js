// Tests for the language model behind completion and hover.
//
// This is pure JS with no vscode dependency, which is why the context logic
// lives in language.js rather than inline in the providers — the part most
// likely to be wrong is the part that can be tested.
//
//     node test/language.test.js

const fs = require("fs")
const path = require("path")
const lang = require("../src/language")

let passed = 0
let failed = 0
const failures = []

function ok(label, condition, detail) {
	if (condition) {
		passed++
		console.log(`  \x1b[32mpass\x1b[0m  ${label}`)
	} else {
		failed++
		failures.push(`${label}${detail ? `\n  ${detail}` : ""}`)
		console.log(`  \x1b[31mFAIL\x1b[0m  ${label}`)
	}
}

/** Runs contextAt with the cursor where the source contains a | marker. */
function contextOf(sourceWithCursor) {
	const offset = sourceWithCursor.indexOf("|")
	const source = sourceWithCursor.replace("|", "")
	return lang.contextAt(source, offset)
}

function eq(label, actual, expected) {
	ok(label, actual === expected, `expected '${expected}', got '${actual}'`)
}

console.log("\n  Context detection")
eq("top level offers declarations", contextOf("|"), "declaration")
eq("after a closed declaration", contextOf("event A from client { a: u8 }\n|"), "declaration")
eq("after a colon offers types", contextOf("event A from client { hp: | }"), "type")
eq("mid-word after a colon", contextOf("event A from client { hp: u|"), "type")
eq("inside an array type", contextOf("event A from client { ids: [| }"), "type")
eq("after 'from'", contextOf("event A from | {"), "direction")
eq("mid-word after 'from'", contextOf("event A from cli|"), "direction")
eq("after 'priority'", contextOf("channel H priority | {"), "priority")
eq("inside a config block", contextOf('config {\n\t|\n}'), "config-key")
eq("after a config key's equals", contextOf('config {\n\tserver = |\n}'), "none")
eq("inside a packet body offers nothing", contextOf("event A from client {\n\t|\n}"), "none")
eq("after the reply arrow", contextOf("request B from client { a: u8 } -> |"), "none")
eq("inside a line comment", contextOf("-- hp: |"), "none")

console.log("\n  Declared types")
{
	const source = `
		struct Vec2i { x: i16, y: i16 }
		enum Team { Red, Blue }
		event A from client { at: Vec2i, team: Team }
	`
	const declared = lang.declaredTypes(source)
	ok("finds a struct", declared.some((d) => d.kind === "struct" && d.name === "Vec2i"))
	ok("finds an enum", declared.some((d) => d.kind === "enum" && d.name === "Team"))
	eq("finds exactly two", declared.length, 2)
}

{
	// A commented-out declaration is not in scope and must not be offered.
	const source = "-- struct Ghost { x: u8 }\nstruct Real { x: u8 }"
	const declared = lang.declaredTypes(source)
	ok("ignores a commented-out declaration", !declared.some((d) => d.name === "Ghost"))
	ok("still finds the live one", declared.some((d) => d.name === "Real"))
}

console.log("\n  Block scanning")
{
	// Braces inside comments and strings must not shift the block stack, or
	// every context after them is wrong.
	const source = 'config {\n\t-- a { brace in a comment\n\tserver = "a { brace in a string.luau"\n\t'
	eq("braces in comments and strings are ignored", lang.enclosingHeader(source, source.length), "config")
}
{
	const source = "event A from client {\n\t"
	eq("packet header is captured", lang.enclosingHeader(source, source.length), "event A from client")
}
{
	const source = "event A from client { a: u8 }\n"
	eq("a closed block leaves top level", lang.enclosingHeader(source, source.length), null)
}

console.log("\n  Agreement with the compiler")
{
	// The extension states byte sizes in hover cards. If they drift from
	// cli/Ast.luau the documentation lies, which is worse than omitting it.
	const astPath = path.join(__dirname, "..", "..", "..", "cli", "Ast.luau")
	const ast = fs.readFileSync(astPath, "utf8")

	const block = ast.slice(ast.indexOf("Ast.PRIMITIVE_SIZES"), ast.indexOf("Ast.PARAMETRIC"))
	const sizes = {}
	for (const match of block.matchAll(/^\s*(\w+)\s*=\s*(\d+)\s*,/gm)) {
		sizes[match[1]] = Number(match[2])
	}

	ok("parsed the compiler's size table", Object.keys(sizes).length >= 15, `got ${Object.keys(sizes).length} entries`)

	for (const [name, size] of Object.entries(sizes)) {
		const info = lang.PRIMITIVES[name]
		if (!info) {
			ok(`${name} is documented`, false, "present in Ast.luau but missing from language.js")
			continue
		}
		ok(`${name} costs ${size} byte(s)`, info.bytes === size, `Ast.luau says ${size}, language.js says ${info.bytes}`)
	}

	// The parametric types have no fixed size and must say so.
	for (const name of ["string", "fixed"]) {
		ok(`${name} has no fixed size`, lang.PRIMITIVES[name] && lang.PRIMITIVES[name].bytes === null)
	}
}

console.log("\n  Config keys agree with the compiler")
{
	const mainPath = path.join(__dirname, "..", "..", "..", "cli", "Analyze.luau")
	const analyze = fs.readFileSync(mainPath, "utf8")
	const block = analyze.slice(analyze.indexOf("local CONFIG_KEYS"), analyze.indexOf("local DEFAULT_RUNTIME"))

	const keys = [...block.matchAll(/"(\w+)"/g)].map((m) => m[1])
	ok("parsed the compiler's key list", keys.length >= 8, `got ${keys.length}`)

	for (const key of keys) {
		ok(`config key '${key}' is documented`, key in lang.CONFIG_KEYS)
	}
	for (const key of Object.keys(lang.CONFIG_KEYS)) {
		ok(`documented key '${key}' is real`, keys.includes(key), "language.js offers a key the compiler rejects")
	}
}

console.log("")
if (failed > 0) {
	for (const failure of failures) console.log(`\x1b[31m----\x1b[0m ${failure}\n`)
	console.log(`\x1b[31m${failed} failed\x1b[0m, ${passed} passed`)
	process.exit(1)
}
console.log(`\x1b[32m${passed} passed\x1b[0m`)
