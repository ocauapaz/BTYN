--!strict
--[[
	Minimal assert-based test harness.

	No framework: BTYN's tests are pure-Luau round trips and golden strings, and
	a dependency would buy nothing here.
]]

local harness = {}

type Case = {
	name: string,
	fn: () -> (),
}

local suites: { { name: string, cases: { Case } } } = {}
local current: { name: string, cases: { Case } }? = nil

function harness.suite(name: string)
	current = { name = name, cases = {} }
	table.insert(suites, current :: any)
end

function harness.test(name: string, fn: () -> ())
	assert(current, "call harness.suite() before harness.test()")
	table.insert((current :: any).cases, { name = name, fn = fn })
end

function harness.eq(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "values differ"}\n  expected: {tostring(expected)}\n  actual:   {tostring(actual)}`, 2)
	end
end

function harness.ok(value: any, message: string?)
	if not value then
		error(message or "expected a truthy value", 2)
	end
end

--[[
	Asserts that `fn` raises, and that the rendered message contains `needle`.
	Compiler errors are a feature, so the tests pin their wording.
]]
function harness.raises(fn: () -> (), needle: string, message: string?)
	local ok, err = pcall(fn)
	if ok then
		error(`{message or "expected an error"}, but the call succeeded`, 2)
	end

	local text = if type(err) == "table" and (err :: any).rendered
		then (err :: any).rendered
		else tostring(err)

	if not string.find(text, needle, 1, true) then
		error(`{message or "wrong error"}\n  expected to contain: {needle}\n  actual:\n{text}`, 2)
	end
end

--[[
	Deep table comparison, used for codec round trips.
]]
function harness.deepEq(actual: any, expected: any, path: string?)
	local where = path or "value"

	if type(expected) ~= type(actual) then
		error(`{where}: type mismatch, expected {type(expected)} got {type(actual)}`, 2)
	end

	if type(expected) ~= "table" then
		if actual ~= expected then
			error(`{where}: expected {tostring(expected)} got {tostring(actual)}`, 2)
		end
		return
	end

	for key, value in expected do
		harness.deepEq(actual[key], value, `{where}.{tostring(key)}`)
	end
	for key in actual do
		if expected[key] == nil then
			error(`{where}.{tostring(key)}: unexpected extra key`, 2)
		end
	end
end

--[[
	Runs every registered suite. Returns the process exit code.
]]
function harness.run(): number
	local passed = 0
	local failed = 0
	local failures: { string } = {}

	for _, suite in suites do
		print(`\n  {suite.name}`)
		for _, case in suite.cases do
			local ok, err = pcall(case.fn)
			if ok then
				passed += 1
				print(`    \27[32mpass\27[0m  {case.name}`)
			else
				failed += 1
				print(`    \27[31mFAIL\27[0m  {case.name}`)
				table.insert(failures, `{suite.name} > {case.name}\n{tostring(err)}`)
			end
		end
	end

	print("")
	if failed > 0 then
		for _, failure in failures do
			print(`\27[31m----\27[0m {failure}\n`)
		end
		print(`\27[31m{failed} failed\27[0m, {passed} passed`)
		return 1
	end

	print(`\27[32m{passed} passed\27[0m`)
	return 0
end

return harness
