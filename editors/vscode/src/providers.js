// Completion and hover, both driven by the model in language.js.

const vscode = require("vscode")
const lang = require("./language")

/** Renders a type's hover card: what it is, and what it costs on the wire. */
function typeDocumentation(name, info) {
	const md = new vscode.MarkdownString()
	md.appendCodeblock(name, "btyn")

	if (info.bytes === 0) {
		md.appendMarkdown("\n**1 bit** on the wire\n\n")
	} else if (info.bytes !== null) {
		md.appendMarkdown(`\n**${info.bytes} byte${info.bytes === 1 ? "" : "s"}** on the wire\n\n`)
	}

	md.appendMarkdown(info.doc)
	return md
}

const completion = {
	provideCompletionItems(document, position) {
		const text = document.getText()
		const offset = document.offsetAt(position)
		const context = lang.contextAt(text, offset)

		if (context === "none") return undefined

		const items = []

		if (context === "declaration") {
			for (const [name, info] of Object.entries(lang.DECLARATIONS)) {
				const item = new vscode.CompletionItem(name, vscode.CompletionItemKind.Keyword)
				item.insertText = new vscode.SnippetString(info.snippet)
				item.documentation = new vscode.MarkdownString(info.doc)
				items.push(item)
			}
			return items
		}

		if (context === "direction") {
			for (const [name, doc] of Object.entries(lang.DIRECTIONS)) {
				const item = new vscode.CompletionItem(name, vscode.CompletionItemKind.EnumMember)
				item.documentation = new vscode.MarkdownString(doc)
				items.push(item)
			}
			return items
		}

		if (context === "priority") {
			for (const [name, doc] of Object.entries(lang.PRIORITIES)) {
				const item = new vscode.CompletionItem(name, vscode.CompletionItemKind.EnumMember)
				item.documentation = new vscode.MarkdownString(doc)
				items.push(item)
			}
			return items
		}

		if (context === "config-key") {
			for (const [name, info] of Object.entries(lang.CONFIG_KEYS)) {
				const item = new vscode.CompletionItem(name, vscode.CompletionItemKind.Property)
				item.detail = info.detail
				item.documentation = new vscode.MarkdownString(info.doc)
				items.push(item)
			}
			return items
		}

		// context === "type"
		for (const [name, info] of Object.entries(lang.PRIMITIVES)) {
			const item = new vscode.CompletionItem(name, vscode.CompletionItemKind.TypeParameter)
			item.detail = info.detail
			item.documentation = typeDocumentation(name, info)
			if (info.snippet) {
				item.insertText = new vscode.SnippetString(info.snippet)
			}
			// Sort the cheap integers above the exotic types.
			item.sortText = info.bytes !== null && info.bytes <= 4 ? `0${name}` : `1${name}`
			items.push(item)
		}

		// The valuable part: types this very file declares.
		for (const declared of lang.declaredTypes(text)) {
			const item = new vscode.CompletionItem(declared.name, vscode.CompletionItemKind.Struct)
			item.detail = `${declared.kind} declared in this file`
			item.sortText = `0${declared.name}`
			items.push(item)
		}

		return items
	},
}

const hover = {
	provideHover(document, position) {
		const range = document.getWordRangeAtPosition(position, /[A-Za-z_]\w*/)
		if (!range) return undefined

		const word = document.getText(range)
		const text = document.getText()

		const primitive = lang.PRIMITIVES[word]
		if (primitive) {
			return new vscode.Hover(typeDocumentation(word, primitive), range)
		}

		const declaration = lang.DECLARATIONS[word]
		if (declaration) {
			const md = new vscode.MarkdownString()
			md.appendCodeblock(word, "btyn")
			md.appendMarkdown(`\n${declaration.doc}`)
			return new vscode.Hover(md, range)
		}

		const modifier = lang.MODIFIERS[word]
		if (modifier) {
			const md = new vscode.MarkdownString()
			md.appendCodeblock(word, "btyn")
			md.appendMarkdown(`\n${modifier.doc}`)
			return new vscode.Hover(md, range)
		}

		// Only treat a config key as one when the cursor is actually in a
		// config block; `manual` and `types` are plausible field names.
		if (lang.CONFIG_KEYS[word]) {
			const header = lang.enclosingHeader(text, document.offsetAt(position))
			if (header !== null && /(^|\s)config$/.test(header)) {
				const info = lang.CONFIG_KEYS[word]
				const md = new vscode.MarkdownString()
				md.appendCodeblock(`${word}  -- ${info.detail}`, "btyn")
				md.appendMarkdown(`\n${info.doc}`)
				return new vscode.Hover(md, range)
			}
		}

		// A struct or enum declared in this file: show its definition.
		const declared = lang.declaredTypes(text).find((entry) => entry.name === word)
		if (declared) {
			const clean = lang.neutralise(text)
			const start = clean.search(new RegExp(`\\b${declared.kind}\\s+${word}\\b`))
			if (start >= 0) {
				const open = clean.indexOf("{", start)
				const close = clean.indexOf("}", open)
				const body = close > open ? text.slice(start, close + 1) : text.slice(start, open)

				const md = new vscode.MarkdownString()
				md.appendCodeblock(body.trim(), "btyn")
				md.appendMarkdown(
					declared.kind === "enum"
						? "\nOne byte on the wire (two past 256 variants), a string union in Luau."
						: "\nA reusable field group, laid out recursively. Its booleans pack into their own bitfield."
				)
				return new vscode.Hover(md, range)
			}
		}

		return undefined
	},
}

module.exports = { completion, hover }
