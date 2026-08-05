--!strict
--[[
	Loads a runtime module outside Roblox.

	The runtime is the half of BTYN that cannot be required headlessly: it
	reaches for `script.Parent` and for Roblox globals that Lune has no
	equivalent for. Rather than leave it to a Studio script nobody remembers to
	run, the requires are rewritten to injected values and the globals are
	shadowed by locals of the same name.

	That last trick is what makes `Transport` testable at all: a `local game`
	declared at the top of the chunk wins over the global for every reference
	below it, so the module runs against a stand-in without knowing it.
]]

local fs = require("@lune/fs")

local loader = {}

--[[
	`task` is a Roblox global with no Lune equivalent. Only `spawn` is reached
	from the modules under test, and only ever to start a thread or resume a
	parked one.
]]
local TASK_SHIM = [[
local task = {
	spawn = function(target, ...)
		if type(target) == "thread" then
			coroutine.resume(target, ...)
		else
			coroutine.wrap(target)(...)
		end
	end,
}
]]

--[[
	Loads `src/<name>.luau`.

	`stubs` replaces `require(script.Parent.X)` by key. `globals` declares
	locals that shadow the real globals — pass `game`, `Instance` and friends
	here.
]]
function loader.load(name: string, stubs: { [string]: any }, globals: { [string]: any }?): any
	local source = fs.readFile(`src/{name}.luau`)

	local declarations: { string } = {}
	local values: { any } = {}

	local dependencies: { string } = {}
	for dependency in stubs do
		table.insert(dependencies, dependency)
	end
	table.sort(dependencies)

	for _, dependency in dependencies do
		source = string.gsub(source, `require%(script%.Parent%.{dependency}%)`, `STUB_{dependency}`)
		table.insert(declarations, `STUB_{dependency}`)
		table.insert(values, stubs[dependency])
	end

	if globals then
		local names: { string } = {}
		for globalName in globals do
			table.insert(names, globalName)
		end
		table.sort(names)

		for _, globalName in names do
			table.insert(declarations, globalName)
			table.insert(values, globals[globalName])
		end
	end

	local header = if #declarations > 0 then `local {table.concat(declarations, ", ")} = ...\n` else ""
	local chunk = assert(loadstring(TASK_SHIM .. header .. source, name))
	return (chunk :: any)(table.unpack(values, 1, #values))
end

return loader
