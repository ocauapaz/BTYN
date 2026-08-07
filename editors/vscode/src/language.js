// The BTYN language model: what exists, what it costs, and what it is for.
//
// Completion and hover both read from here, so a type's description is written
// once. Byte sizes mirror cli/Ast.luau — if that file changes, this one has to
// follow, and test/language.test.js checks the two agree.

/** Primitive types, keyed by name. `bytes` is the wire cost of one value. */
const PRIMITIVES = {
	u8: { bytes: 1, detail: "0 to 255", doc: "Unsigned 8-bit integer." },
	u16: { bytes: 2, detail: "0 to 65535", doc: "Unsigned 16-bit integer." },
	u32: { bytes: 4, detail: "0 to 4294967295", doc: "Unsigned 32-bit integer." },
	i8: { bytes: 1, detail: "-128 to 127", doc: "Signed 8-bit integer." },
	i16: { bytes: 2, detail: "-32768 to 32767", doc: "Signed 16-bit integer." },
	i32: { bytes: 4, detail: "-2147483648 to 2147483647", doc: "Signed 32-bit integer." },
	f32: { bytes: 4, detail: "single precision", doc: "32-bit float. Consider `fixed` or `angle` first — a quantised value is usually smaller and precise enough." },
	f64: { bytes: 8, detail: "double precision", doc: "64-bit float. Rarely needed; position almost never justifies it." },

	bool: {
		bytes: 0,
		detail: "1 bit",
		doc: "Costs one **bit**, not one byte. Every boolean in a packet shares a bitfield at the front, so 32 flags cost 4 bytes and a single store.",
	},

	entity: {
		bytes: 4,
		detail: "u32 id",
		doc: "A `u32` whose meaning is yours.\n\nPrefer this over `Instance`: an Instance reference cannot live in a buffer, costs real bandwidth, and arrives `nil` when the receiver has not streamed the object in yet.",
	},

	vec3: { bytes: 12, detail: "3 x f32", doc: "A `Vector3`." },
	cframe: { bytes: 18, detail: "position + quantised rotation", doc: "A `CFrame`. Position as 3 x f32, rotation as quantised euler angles." },
	color3: { bytes: 3, detail: "one byte per channel", doc: "A `Color3`." },
	unit: {
		bytes: 6,
		detail: "quantised unit vector",
		doc: "A `Vector3` known to be unit length, each component quantised to `i16`. Use for directions and facings instead of `vec3`.",
	},
	angle: {
		bytes: 2,
		detail: "quantised radians",
		doc: "Radians quantised across `[-pi, pi]`. Two bytes instead of the four an `f32` would take, and finer than anything a player perceives.",
	},

	Instance: {
		bytes: 2,
		detail: "sidecar reference",
		doc: "An index into a reference array carried alongside the payload.\n\nWorks, but prefer `entity`. Instance references cost bandwidth, arrive `nil` when the receiver has not loaded the object, and give up the serialise-once broadcast path.",
	},

	string: {
		bytes: null,
		detail: "string(n) — cap required",
		doc: "The cap is **mandatory**. An uncapped string is an uncapped packet, which is both a bandwidth leak and a free amplification primitive.\n\nCosts one length byte up to 255, two beyond, plus the content.",
		snippet: "string(${1:24})",
	},

	fixed: {
		bytes: null,
		detail: "fixed(min, max, bytes)",
		doc: "A float quantised into a fixed range. `bytes` is 1, 2 or 4.\n\nTwo bytes gives 65536 steps across the range — usually the right answer when you were about to reach for `f32`.",
		snippet: "fixed(${1:-1}, ${2:1}, ${3:2})",
	},
}

/** Declaration keywords, with a snippet body for each. */
const DECLARATIONS = {
	event: {
		doc: "Reliable, ordered, batched once per frame.",
		snippet: "event ${1:Name} from ${2|client,server|} {\n\t${3:field}: ${4:u8},\n}",
	},
	unreliable: {
		doc: "Sent over `UnreliableRemoteEvent`. May arrive out of order or not at all — use it when a lost packet is invisible.\n\nThe compiler rejects one that cannot fit the payload cap, because the engine drops an oversized unreliable payload silently.",
		snippet: "unreliable ${1:Name} from ${2|server,client|} {\n\t${3:field}: ${4:vec3},\n}",
	},
	request: {
		doc: "Request and reply over the same two remotes. No `RemoteFunction` is involved, so a slow handler never blocks replication behind it.",
		snippet: "request ${1:Name} from ${2|client,server|} {\n\t${3:field}: ${4:u16},\n} -> {\n\tok: bool,\n}",
	},
	channel: {
		doc: "Delta-encoded replicated state with an explicit audience. Only changed fields go out, and only to the players that matter.\n\nAlways server to client, so it takes no `from`.",
		snippet: "channel ${1:Name} priority ${2|normal,high,low|} {\n\t${3:field}: ${4:u8},\n}",
	},
	struct: { doc: "A reusable field group, laid out recursively.", snippet: "struct ${1:Name} { ${2:x}: ${3:i16} }" },
	enum: {
		doc: "One byte on the wire (two past 256 variants), a string union in Luau.",
		snippet: "enum ${1:Name} { ${2:First}, ${3:Second} }",
	},
	config: {
		doc: "Output paths and compiler options.",
		snippet: 'config {\n\tserver = "${1:src/Server/Net.luau}"\n\tclient = "${2:src/Client/Net.luau}"\n}',
	},
}

/** Trailing modifiers on a declaration header. */
const MODIFIERS = {
	from: { doc: "Which side sends. Decides which half of the API each side receives." },
	rate: { doc: "Per-player token bucket on the receiving side, in packets per second. An over-budget packet is dropped and reported through `onAbuse`." },
	priority: { doc: "What gets deferred when a client is over its per-frame byte budget. `low` defers first; `high` never defers." },
}

/** Keys accepted inside a `config` block. */
const CONFIG_KEYS = {
	server: { detail: "required", doc: "Where to write the server module." },
	client: { detail: "required", doc: "Where to write the client module." },
	types: { detail: "optional", doc: "Where to write shared type definitions." },
	runtime: {
		detail: 'default: game:GetService("ReplicatedStorage"):WaitForChild("BTYN")',
		doc: "Luau expression the generated files use to reach the BTYN runtime.",
	},
	budget: { detail: "default: 40000", doc: "Soft per-client outbound budget in bytes per second." },
	unreliable_cap: {
		detail: "default: 800",
		doc: "Largest unreliable payload in bytes.\n\nRoblox does not publish this number; community measurement puts it near 1000. The default sits below that on purpose — undershooting costs a few bytes, overshooting costs silent data loss. Measure on your own place before raising it.",
	},
	max_packets_per_batch: {
		detail: "default: 256",
		doc: "Most packets one received batch may carry, enforced on the server only.\n\nThe smallest packet is a single opcode byte, so without a ceiling one payload becomes tens of thousands of handler calls in a frame — an amplification the per-packet rate limits cannot see, because they are only reached once the work has already been done.",
	},
	remotes: {
		detail: 'default: "BTYN"',
		doc: "Where the two remotes live, as a `/`-separated path under `ReplicatedStorage`.\n\nPoints at an existing framework folder when the project would rather not carry a stray instance at the root.",
	},
	request_timeout: { detail: "default: 10", doc: "Seconds before an unanswered request fails." },
	write_checks: {
		detail: "default: true",
		doc: "Validate on the way out as well as in.\n\nThe receiving side always validates — that is the trust boundary. This only controls the sending side, where it buys catching `hp = 300` at the call site instead of watching it truncate to 44.",
	},
	manual: { detail: "default: false", doc: "Flush by hand instead of once per frame on Heartbeat." },
	typescript: { detail: "not implemented", doc: "roblox-ts declaration output. Setting this to `true` currently fails the build rather than silently emitting nothing." },
}

const DIRECTIONS = {
	client: "The client sends, the server receives.",
	server: "The server sends, the client receives.",
}

const PRIORITIES = {
	low: "Deferred first when a client is over its byte budget. For cosmetic state.",
	normal: "The default.",
	high: "Never deferred. For state a player cannot play without.",
}

/** Strips comments and string bodies so brace scanning cannot be fooled. */
function neutralise(text) {
	return text
		.replace(/--\[\[[\s\S]*?\]\]/g, (m) => " ".repeat(m.length))
		.replace(/--[^\n]*/g, (m) => " ".repeat(m.length))
		.replace(/"(?:[^"\\\n]|\\.)*"/g, (m) => " ".repeat(m.length))
}

/**
 * Names of every struct and enum declared in the document, so completion can
 * offer the types you actually defined rather than only the built-ins.
 */
function declaredTypes(text) {
	const clean = neutralise(text)
	const found = []

	for (const match of clean.matchAll(/\b(struct|enum)\s+([A-Za-z_]\w*)/g)) {
		found.push({ kind: match[1], name: match[2] })
	}

	return found
}

/**
 * The header of the innermost block still open at `offset`, or null at top
 * level. Used to tell a `config` body apart from a packet body.
 */
function enclosingHeader(text, offset) {
	const clean = neutralise(text.slice(0, offset))
	const stack = []

	for (let index = 0; index < clean.length; index++) {
		const char = clean[index]
		if (char === "{") {
			// Everything since the previous brace or newline is the header.
			const lineStart = Math.max(clean.lastIndexOf("\n", index), clean.lastIndexOf("}", index)) + 1
			stack.push(clean.slice(lineStart, index).trim())
		} else if (char === "}") {
			stack.pop()
		}
	}

	return stack.length > 0 ? stack[stack.length - 1] : null
}

/**
 * What the cursor is positioned to receive.
 *
 * Returns one of: "config-key", "direction", "priority", "type", "declaration".
 */
function contextAt(text, offset) {
	const linePrefix = text.slice(text.lastIndexOf("\n", offset - 1) + 1, offset)
	const cleanPrefix = neutralise(linePrefix)

	// A comment swallows the rest of the line.
	if (/--/.test(linePrefix.slice(0, cleanPrefix.length ? cleanPrefix.search(/\S|$/) : 0)) || cleanPrefix !== linePrefix) {
		if (/--/.test(linePrefix)) return "none"
	}

	if (/\bfrom\s+\w*$/.test(cleanPrefix)) return "direction"
	if (/\bpriority\s+\w*$/.test(cleanPrefix)) return "priority"

	const header = enclosingHeader(text, offset)
	if (header !== null && /(^|\s)config$/.test(header)) {
		// Only before the `=`; after it comes a value, not a key.
		return /=\s*\S*$/.test(cleanPrefix) ? "none" : "config-key"
	}

	// After a colon, and after `[` or `;` inside an array type.
	if (/:\s*[\w]*$/.test(cleanPrefix)) return "type"
	if (/[\[]\s*\w*$/.test(cleanPrefix)) return "type"
	if (/->\s*$/.test(cleanPrefix)) return "none"

	if (header === null) return "declaration"
	return "none"
}

module.exports = {
	PRIMITIVES,
	DECLARATIONS,
	MODIFIERS,
	CONFIG_KEYS,
	DIRECTIONS,
	PRIORITIES,
	neutralise,
	declaredTypes,
	enclosingHeader,
	contextAt,
}
