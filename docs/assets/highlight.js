// Syntax highlighting for the code blocks on this site.
//
// Rouge ships no lexer for either language here: `btyn` is ours, and `luau`
// falls back to plain text because Rouge only knows `lua` — which would mangle
// the type annotations that appear in almost every example. GitHub Pages will
// not load custom Rouge lexers, so both are done here instead.
//
// One ordered pass, first rule wins. An earlier version chained regex replaces
// and used sentinel characters to protect comments and strings from later
// passes, which works right up until a sentinel appears in real content.
;(function () {
	function escape(text) {
		return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
	}

	/**
	 * Walks `source` once, trying each rule at the current position and taking
	 * the first that matches there. Anything unmatched is emitted as-is, so an
	 * incomplete rule set degrades to plain text rather than losing characters.
	 */
	function tokenise(source, rules) {
		var out = ""
		var pos = 0

		outer: while (pos < source.length) {
			for (var i = 0; i < rules.length; i++) {
				var rule = rules[i]
				rule.re.lastIndex = pos
				var m = rule.re.exec(source)

				if (m && m.index === pos && m[0].length > 0) {
					out += rule.render ? rule.render(m) : '<span class="' + rule.cls + '">' + escape(m[0]) + "</span>"
					pos += m[0].length
					continue outer
				}
			}

			out += escape(source[pos])
			pos++
		}

		return out
	}

	function span(cls, text) {
		return '<span class="' + cls + '">' + escape(text) + "</span>"
	}

	// Sticky so each test is anchored at the cursor rather than searching ahead.
	function re(pattern) {
		return new RegExp(pattern, "y")
	}

	var BTYN_RULES = [
		{ re: re("--\\[\\[[\\s\\S]*?\\]\\]|--[^\\n]*"), cls: "c" },
		{ re: re('"(?:[^"\\\\\\n]|\\\\.)*"'), cls: "str" },
		{
			// A declaration keyword only counts when a name follows it, which is
			// what keeps a field called `event` from looking like one.
			re: re("\\b(event|unreliable|request|channel|struct|enum)(\\s+)([A-Za-z_]\\w*)"),
			render: function (m) {
				return span("k", m[1]) + m[2] + span("t", m[3])
			},
		},
		{ re: re("\\bconfig\\b(?=\\s*\\{)"), cls: "k" },
		{
			re: re("\\b(from)(\\s+)(client|server)\\b"),
			render: function (m) {
				return span("m", m[1]) + m[2] + span("v", m[3])
			},
		},
		{
			re: re("\\b(priority)(\\s+)(low|normal|high)\\b"),
			render: function (m) {
				return span("m", m[1]) + m[2] + span("v", m[3])
			},
		},
		{ re: re("\\brate\\b(?=\\s+\\d)"), cls: "m" },
		{
			// Field name, only when a colon follows.
			re: re("([A-Za-z_]\\w*)(\\s*)(?=:)"),
			render: function (m) {
				return span("f", m[1]) + m[2]
			},
		},
		{
			re: re("\\b(u8|u16|u32|i8|i16|i32|f32|f64|bool|entity|vec3|cframe|color3|unit|angle|string|fixed|Instance)\\b"),
			cls: "ty",
		},
		{ re: re("\\b[A-Z]\\w*\\b"), cls: "t" },
		{ re: re("\\b\\d+(?:\\.\\d+)?\\b"), cls: "n" },
		{ re: re("->|\\.\\.|\\?|="), cls: "o" },
	]

	var LUAU_KEYWORDS =
		"\\b(local|function|end|if|then|else|elseif|for|in|while|do|repeat|until|return|break|continue|and|or|not|export|type|self)\\b"

	var LUAU_RULES = [
		{ re: re("--\\[\\[[\\s\\S]*?\\]\\]|--[^\\n]*"), cls: "c" },
		{ re: re("\\[(=*)\\[[\\s\\S]*?\\]\\1\\]"), cls: "str" },
		// Backtick strings interpolate, but the braces read fine as string text.
		{ re: re("`(?:[^`\\\\]|\\\\.)*`"), cls: "str" },
		{ re: re('"(?:[^"\\\\\\n]|\\\\.)*"'), cls: "str" },
		{ re: re("'(?:[^'\\\\\\n]|\\\\.)*'"), cls: "str" },
		{ re: re("\\b(nil|true|false)\\b"), cls: "v" },
		{
			re: re("\\b(function)(\\s+)([A-Za-z_][\\w.:]*)"),
			render: function (m) {
				return span("k", m[1]) + m[2] + span("fn", m[3])
			},
		},
		{ re: re(LUAU_KEYWORDS), cls: "k" },
		{
			// `buffer.writeu8(` — the library reads better with the namespace
			// distinguished from the call.
			re: re("\\b([A-Za-z_]\\w*)(\\.)([A-Za-z_]\\w*)(?=\\s*\\()"),
			render: function (m) {
				return span("ns", m[1]) + m[2] + span("fn", m[3])
			},
		},
		{ re: re("\\b[A-Za-z_]\\w*(?=\\s*\\()"), cls: "fn" },
		{
			// Type annotation or return type: everything after a colon up to
			// what cannot be part of a type.
			re: re("(:)(\\s*)([A-Za-z_][\\w.]*)"),
			render: function (m) {
				return m[1] + m[2] + span("ty", m[3])
			},
		},
		{ re: re("\\b\\d+(?:\\.\\d+)?(?:e[-+]?\\d+)?\\b"), cls: "n" },
		{ re: re("\\+=|-=|\\*=|/=|\\.\\.|==|~=|<=|>=|->|[-+*/%<>#=]"), cls: "o" },
	]

	var LANGUAGES = { btyn: BTYN_RULES, luau: LUAU_RULES, lua: LUAU_RULES }

	var blocks = document.querySelectorAll("pre > code[class*='language-']")

	for (var i = 0; i < blocks.length; i++) {
		var block = blocks[i]
		var match = /language-([a-z]+)/.exec(block.className)
		if (!match) continue

		var rules = LANGUAGES[match[1]]
		if (!rules) continue

		block.innerHTML = tokenise(block.textContent, rules)
		block.classList.add("hl")
	}
})()
