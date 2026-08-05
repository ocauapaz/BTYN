// Live diagnostics, produced by running the real compiler.
//
// Nothing about the schema rules is reimplemented here. The compiler already
// knows every rule and already reports a line, a column and a span; this runs
// it with --json and turns the result into squiggles. Anything else would be a
// second implementation to keep in sync, and it would disagree eventually.

const { execFile } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")
const vscode = require("vscode")

/** Walks up from a file looking for the compiler entry point. */
function findCompiler(startDir) {
	let dir = startDir

	for (let depth = 0; depth < 12; depth++) {
		const candidate = path.join(dir, "cli", "main.luau")
		if (fs.existsSync(candidate)) {
			return { root: dir, script: "cli/main" }
		}

		const parent = path.dirname(dir)
		if (parent === dir) break
		dir = parent
	}

	return null
}

class DiagnosticRunner {
	constructor(output) {
		this.collection = vscode.languages.createDiagnosticCollection("btyn")
		this.output = output
		this.timers = new Map()
		// Set once the toolchain is known to be missing, so a machine without
		// Lune gets one explanation instead of a message per keystroke.
		this.disabledReason = null
	}

	dispose() {
		this.collection.dispose()
		for (const timer of this.timers.values()) clearTimeout(timer)
	}

	settings() {
		const config = vscode.workspace.getConfiguration("btyn")
		return {
			enabled: config.get("diagnostics.enabled", true),
			lunePath: config.get("lunePath", "lune"),
			compilerPath: config.get("compilerPath", ""),
		}
	}

	/** Debounced so typing does not spawn a compiler per keystroke. */
	schedule(document, delay = 400) {
		if (document.languageId !== "btyn") return

		const key = document.uri.toString()
		clearTimeout(this.timers.get(key))
		this.timers.set(
			key,
			setTimeout(() => {
				this.timers.delete(key)
				this.run(document)
			}, delay)
		)
	}

	run(document) {
		if (document.languageId !== "btyn") return

		const settings = this.settings()
		if (!settings.enabled || this.disabledReason) {
			this.collection.delete(document.uri)
			return
		}

		const documentDir = path.dirname(document.uri.fsPath)
		let root
		let script

		if (settings.compilerPath) {
			const resolved = path.resolve(settings.compilerPath)
			if (!fs.existsSync(resolved)) {
				this.disable(`btyn.compilerPath points at '${resolved}', which does not exist.`)
				return
			}
			root = path.dirname(path.dirname(resolved))
			script = path.relative(root, resolved).replace(/\.luau$/, "").replace(/\\/g, "/")
		} else {
			const found = findCompiler(documentDir)
			if (!found) {
				// Not an error: plenty of people open a .btyn file outside the
				// repo that compiles it. Highlighting still works.
				this.collection.delete(document.uri)
				return
			}
			root = found.root
			script = found.script
		}

		// Compile the buffer as it is now, not as it was last saved, so errors
		// appear while typing.
		//
		// The scratch file goes in the OS temp directory rather than beside the
		// document: --json writes no output, so relative paths in the schema's
		// config are never resolved, and a crashed process must not leave a
		// stray .btyn in someone's repository.
		const scratch = path.join(os.tmpdir(), `btyn-check-${process.pid}-${Date.now()}.btyn`)

		let wrote = false
		try {
			fs.writeFileSync(scratch, document.getText())
			wrote = true
		} catch (error) {
			this.output.appendLine(`could not write scratch file: ${error.message}`)
			return
		}

		execFile(
			settings.lunePath,
			["run", script, "--", scratch, "--json"],
			{ cwd: root, timeout: 10000, windowsHide: true },
			(error, stdout, stderr) => {
				if (wrote) {
					try {
						fs.unlinkSync(scratch)
					} catch {}
				}

				if (error && error.code === "ENOENT") {
					this.disable(
						`Lune was not found on PATH (tried '${settings.lunePath}'). ` +
							"Install it, or set btyn.lunePath, or turn off btyn.diagnostics.enabled."
					)
					return
				}

				if (error && !stdout) {
					this.output.appendLine(`compiler failed: ${error.message}`)
					if (stderr) this.output.appendLine(stderr.trim())
					return
				}

				let payload
				try {
					// Lune may print warnings before the JSON; take the last line
					// that parses, which is the payload.
					const lines = stdout.trim().split("\n")
					payload = JSON.parse(lines[lines.length - 1])
				} catch {
					this.output.appendLine(`could not parse compiler output:\n${stdout}`)
					return
				}

				this.publish(document, payload)
			}
		)
	}

	publish(document, payload) {
		if (payload.ok) {
			this.collection.delete(document.uri)
			return
		}

		const diagnostics = []

		for (const entry of payload.diagnostics || []) {
			const line = Math.max((entry.line || 1) - 1, 0)
			const column = Math.max((entry.column || 1) - 1, 0)
			const length = Math.max(entry.length || 1, 1)

			// Clamp to the line: a span from a stale compile can outrun the
			// buffer while it is being edited.
			const lineLength = line < document.lineCount ? document.lineAt(line).text.length : column + length
			const start = Math.min(column, Math.max(lineLength, 0))
			const end = Math.min(column + length, Math.max(lineLength, start + 1))

			const range = new vscode.Range(line, start, line, end)

			let message = entry.message
			if (entry.label) message += `\n${entry.label}`
			if (entry.help) message += `\n\nhelp: ${entry.help}`

			const diagnostic = new vscode.Diagnostic(range, message, vscode.DiagnosticSeverity.Error)
			diagnostic.source = "btyn"
			diagnostics.push(diagnostic)
		}

		this.collection.set(document.uri, diagnostics)
	}

	disable(reason) {
		this.disabledReason = reason
		this.output.appendLine(reason)
		this.collection.clear()
		vscode.window.showWarningMessage(`BTYN: ${reason}`)
	}

	/** Clears the one-shot disable so a fixed setup is picked up. */
	reset() {
		this.disabledReason = null
	}
}

module.exports = { DiagnosticRunner, findCompiler }
