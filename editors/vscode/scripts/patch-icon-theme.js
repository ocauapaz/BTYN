// Adds the BTYN file icon to the icon theme you already use.
//
// VS Code has no additive file-icon API: an extension can only ship a whole
// icon theme, and activating one replaces yours. If you already run a theme you
// like, this patches the BTYN icon into it instead, on your machine only.
//
//     node scripts/patch-icon-theme.js          # patch the active theme
//     node scripts/patch-icon-theme.js --undo   # restore it
//
// The original theme file is backed up next to itself before anything is
// written, and --undo restores from that backup. Updating the patched
// extension replaces its files, so re-run this afterwards.

const fs = require("fs")
const os = require("os")
const path = require("path")

const EXTENSION_ROOT = path.join(__dirname, "..")
const SOURCE_ICON = path.join(EXTENSION_ROOT, "fileicons", "icons", "btyn.svg")
const ICON_KEY = "_btyn_schema"
const BACKUP_SUFFIX = ".btyn-backup"

const undo = process.argv.includes("--undo")

function fail(message) {
	console.error(`patch-icon-theme: ${message}`)
	process.exit(1)
}

/** Locations VS Code keeps user settings, across its release channels. */
function settingsCandidates() {
	const home = os.homedir()
	const roots =
		process.platform === "win32"
			? [path.join(process.env.APPDATA || path.join(home, "AppData", "Roaming"))]
			: process.platform === "darwin"
				? [path.join(home, "Library", "Application Support")]
				: [process.env.XDG_CONFIG_HOME || path.join(home, ".config")]

	const products = ["Code", "Code - Insiders", "VSCodium", "Cursor"]
	const out = []
	for (const root of roots) {
		for (const product of products) {
			out.push(path.join(root, product, "User", "settings.json"))
		}
	}
	return out
}

function extensionsDir() {
	const home = os.homedir()
	for (const dir of [
		path.join(home, ".vscode", "extensions"),
		path.join(home, ".vscode-insiders", "extensions"),
		path.join(home, ".vscode-oss", "extensions"),
		path.join(home, ".cursor", "extensions"),
	]) {
		if (fs.existsSync(dir)) return dir
	}
	return null
}

/** Reads the active icon theme id. settings.json is JSONC, so this is matched
 *  textually rather than parsed — the goal is one value, not the whole file. */
function activeIconTheme() {
	for (const file of settingsCandidates()) {
		if (!fs.existsSync(file)) continue
		const text = fs.readFileSync(file, "utf8")
		const match = text.match(/"workbench\.iconTheme"\s*:\s*"([^"]+)"/)
		if (match) return { id: match[1], settingsFile: file }
	}
	return null
}

/** Every theme.json contributed by the extension that owns `themeId`. */
function themeFilesFor(themeId) {
	const root = extensionsDir()
	if (!root) fail("could not find a VS Code extensions directory")

	for (const entry of fs.readdirSync(root)) {
		const manifest = path.join(root, entry, "package.json")
		if (!fs.existsSync(manifest)) continue

		let pkg
		try {
			pkg = JSON.parse(fs.readFileSync(manifest, "utf8"))
		} catch {
			continue
		}

		const themes = pkg.contributes && pkg.contributes.iconThemes
		if (!Array.isArray(themes)) continue
		if (!themes.some((theme) => theme.id === themeId)) continue

		// Patch every variant the extension ships, not only the active one, so
		// switching between e.g. light and dark variants keeps the icon.
		return {
			extensionDir: path.join(root, entry),
			extensionName: entry,
			files: themes.map((theme) => path.join(root, entry, theme.path)).filter((file) => fs.existsSync(file)),
		}
	}
	return null
}

function restore(files) {
	let restored = 0
	for (const file of files) {
		const backup = file + BACKUP_SUFFIX
		if (!fs.existsSync(backup)) continue
		fs.copyFileSync(backup, file)
		fs.unlinkSync(backup)
		restored++
		console.log(`  restored ${path.basename(path.dirname(file))}/${path.basename(file)}`)
	}
	return restored
}

function patch(file) {
	const backup = file + BACKUP_SUFFIX

	// Back up the pristine file once. Re-running must not overwrite a good
	// backup with an already-patched copy.
	if (!fs.existsSync(backup)) {
		fs.copyFileSync(file, backup)
	}

	const theme = JSON.parse(fs.readFileSync(file, "utf8"))

	// Themes keep their icons beside the theme file; copying in rather than
	// pointing outside keeps the relative-path convention intact.
	const iconDir = path.join(path.dirname(file), "icons")
	fs.mkdirSync(iconDir, { recursive: true })
	fs.copyFileSync(SOURCE_ICON, path.join(iconDir, "btyn.svg"))

	theme.iconDefinitions = theme.iconDefinitions || {}
	theme.iconDefinitions[ICON_KEY] = { iconPath: "./icons/btyn.svg" }

	theme.fileExtensions = theme.fileExtensions || {}
	theme.fileExtensions.btyn = ICON_KEY

	theme.languageIds = theme.languageIds || {}
	theme.languageIds.btyn = ICON_KEY

	fs.writeFileSync(file, JSON.stringify(theme, null, 2))
	console.log(`  patched ${path.basename(path.dirname(file))}/${path.basename(file)}`)
}

function main() {
	if (!fs.existsSync(SOURCE_ICON)) {
		fail(`icon not found at ${SOURCE_ICON}`)
	}

	const active = activeIconTheme()
	if (!active) {
		fail(
			"no workbench.iconTheme found in your settings.\n" +
				"  Pick an icon theme first, or select the bundled 'BTYN' theme, which needs no patching."
		)
	}

	const target = themeFilesFor(active.id)
	if (!target) {
		fail(`could not find the extension contributing icon theme '${active.id}'`)
	}
	if (target.files.length === 0) {
		fail(`extension '${target.extensionName}' contributes '${active.id}' but no theme file exists on disk`)
	}

	console.log(`\nicon theme : ${active.id}`)
	console.log(`extension  : ${target.extensionName}\n`)

	if (undo) {
		const restored = restore(target.files)
		console.log(restored > 0 ? "\nrestored.\n" : "\nnothing to restore — no backup found.\n")
		return
	}

	for (const file of target.files) {
		patch(file)
	}

	console.log("\nReload the window to see it: Developer: Reload Window")
	console.log("Undo with: node scripts/patch-icon-theme.js --undo")
	console.log("Updating the patched extension replaces its files — re-run this if the icon disappears.\n")
}

main()
