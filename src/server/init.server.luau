--!strict
-- CRYPTLINGS: NIGHT SHIFT — server bootstrap (Stage 0 loader, CONTRACTS v1 §A).
-- FROZEN after Stage 0: adding a service file NEVER requires touching this file.
-- Boot order: Remotes.InitServer() -> require all ModuleScripts directly under
-- Services/ -> :Init() on all (alphabetical, must not yield) -> :Start() on all
-- (spawned; may yield). Defensive: a missing or broken module is warned and
-- skipped so the place always builds and runs mid-construction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function safeRequire(moduleScript: ModuleScript): any
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(`[Server] failed to require {moduleScript:GetFullName()}: {result}`)
		return nil
	end
	return result
end

--------------------------------------------------------------------------------
-- 1) Remotes — created before any service so Init can Get them safely.
--------------------------------------------------------------------------------

do
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local net = shared and shared:FindFirstChild("Net")
	local remotesModule = net and net:FindFirstChild("Remotes")
	if remotesModule ~= nil and remotesModule:IsA("ModuleScript") then
		local remotes = safeRequire(remotesModule)
		if type(remotes) == "table" and type(remotes.InitServer) == "function" then
			local ok, err = pcall(remotes.InitServer)
			if not ok then
				warn(`[Server] Remotes.InitServer failed: {err}`)
			end
		end
	else
		warn("[Server] Shared.Net.Remotes not found — skipping remote creation (mid-construction build?)")
	end
end

--------------------------------------------------------------------------------
-- 2) Services — one module per file directly under Services/.
--------------------------------------------------------------------------------

type ServiceEntry = { name: string, service: any }
local services: { ServiceEntry } = {}

local servicesFolder = script:FindFirstChild("Services")
if servicesFolder ~= nil then
	for _, child in servicesFolder:GetChildren() do
		if child:IsA("ModuleScript") then
			local service = safeRequire(child)
			if type(service) == "table" then
				table.insert(services, { name = child.Name, service = service })
			elseif service ~= nil then
				warn(`[Server] service {child.Name} did not return a table — skipped`)
			end
		end
	end
end

table.sort(services, function(a, b)
	return a.name < b.name
end)

-- Init phase: alphabetical, synchronous, services must not yield here.
for _, entry in services do
	local init = entry.service.Init
	if type(init) == "function" then
		local ok, err = pcall(init, entry.service)
		if not ok then
			warn(`[Server] {entry.name}:Init() failed: {err}`)
		end
	end
end

-- Start phase: spawned, may yield/run forever.
for _, entry in services do
	local start = entry.service.Start
	if type(start) == "function" then
		task.spawn(function()
			local ok, err = pcall(start, entry.service)
			if not ok then
				warn(`[Server] {entry.name}:Start() failed: {err}`)
			end
		end)
	end
end

print(`[Server] Rescue the Brainrots! — booted {#services} service(s)`)
