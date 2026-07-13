--!strict
-- CRYPTLINGS: NIGHT SHIFT — TestEZ bootstrap (Stage 4 integration).
-- ONLY mounted by test.project.json (which also maps DevPackages/ — wally's
-- dev-dependency realm — into ReplicatedStorage.DevPackages). The production
-- default.project.json maps neither, so neither TestEZ nor this Script can
-- ever ship in a release build.
--
-- Usage:
--   $env:Path = "$env:USERPROFILE\.rokit\bin;" + $env:Path
--   wally install                       # populates DevPackages/ (testez)
--   rojo build test.project.json -o cryptlings-tests.rbxlx
--   open the place in Studio, press Run (F8) — results print to the Output.
--
-- Runs every spec under ServerScriptService.Server.Tests. The specs themselves
-- warn-and-skip cleanly when optional fixtures (mock profiles, DataStore
-- access) are unavailable, so a plain Run always completes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local devPackages = ReplicatedStorage:WaitForChild("DevPackages", 10)
local testez = if devPackages ~= nil then devPackages:FindFirstChild("testez") else nil
if testez == nil or not testez:IsA("ModuleScript") then
	warn(
		"[TestBootstrap] ReplicatedStorage.DevPackages.testez not found — run `wally install`"
			.. " and build with test.project.json"
	)
	return
end

local server = ServerScriptService:WaitForChild("Server", 10)
local tests = if server ~= nil then server:FindFirstChild("Tests") else nil
if tests == nil then
	warn("[TestBootstrap] ServerScriptService.Server.Tests not found — nothing to run")
	return
end

-- Let the Stage 0 loader finish booting services (specs require live siblings
-- like PlayerDataService in mock mode) before the suite starts.
task.wait(1)

local TestEZ = require(testez) :: any
local results = TestEZ.TestBootstrap:run({ tests })
if results ~= nil and results.failureCount ~= nil then
	print(
		`[TestBootstrap] done — {results.successCount} passed, {results.failureCount} failed, {results.skippedCount} skipped`
	)
end
