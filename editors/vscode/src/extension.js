const vscode = require("vscode")

const { DiagnosticRunner } = require("./diagnostics")
const { completion, hover } = require("./providers")

function activate(context) {
	const output = vscode.window.createOutputChannel("BTYN")
	context.subscriptions.push(output)

	context.subscriptions.push(
		vscode.languages.registerCompletionItemProvider(
			"btyn",
			completion,
			// Retrigger on the characters that start a new context, so the list
			// appears without anyone reaching for Ctrl+Space.
			":",
			" ",
			"[",
			";"
		),
		vscode.languages.registerHoverProvider("btyn", hover)
	)

	const runner = new DiagnosticRunner(output)
	context.subscriptions.push(runner)

	context.subscriptions.push(
		vscode.workspace.onDidOpenTextDocument((document) => runner.run(document)),
		vscode.workspace.onDidChangeTextDocument((event) => runner.schedule(event.document)),
		vscode.workspace.onDidSaveTextDocument((document) => runner.run(document)),
		vscode.workspace.onDidCloseTextDocument((document) => runner.collection.delete(document.uri)),
		vscode.workspace.onDidChangeConfiguration((event) => {
			if (!event.affectsConfiguration("btyn")) return
			// A settings change is the moment to retry after a missing toolchain.
			runner.reset()
			for (const document of vscode.workspace.textDocuments) {
				runner.run(document)
			}
		})
	)

	for (const document of vscode.workspace.textDocuments) {
		runner.run(document)
	}
}

function deactivate() {}

module.exports = { activate, deactivate }
