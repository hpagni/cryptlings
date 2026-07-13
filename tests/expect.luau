--!strict
-- CRYPTLINGS: NIGHT SHIFT — tiny assert helpers for the lune suites
-- (tests/run.luau). Pure Luau. Every helper raises with a labeled message so
-- the runner can print exactly which expectation broke.

local Expect = {}

function Expect.ok(condition: boolean, label: string)
	if not condition then
		error(label, 2)
	end
end

function Expect.eq(got: any, want: any, label: string)
	if got ~= want then
		error(`{label}: expected {tostring(want)}, got {tostring(got)}`, 2)
	end
end

function Expect.neq(got: any, banned: any, label: string)
	if got == banned then
		error(`{label}: value must not be {tostring(banned)}`, 2)
	end
end

function Expect.near(got: number, want: number, tolerance: number, label: string)
	if math.abs(got - want) > tolerance then
		error(`{label}: expected {want} ± {tolerance}, got {got}`, 2)
	end
end

-- Deep structural equality over plain tables (arrays + dicts, no metatables).
local function deepEquals(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deepEquals(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

Expect.deepEquals = deepEquals

function Expect.deepEq(got: any, want: any, label: string)
	if not deepEquals(got, want) then
		error(`{label}: deep-equality mismatch`, 2)
	end
end

return table.freeze(Expect)
