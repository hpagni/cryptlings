--!strict
-- CRYPTLINGS: NIGHT SHIFT — client bootstrap (Stage 0 loader, CONTRACTS v1 §A).
-- FROZEN after Stage 0: adding a controller file NEVER requires touching this.
-- Requires every ModuleScript directly under Controllers/, registers each in the
-- Controllers registry (Controllers.Get(name)), calls :Init(registry) on all
-- (alphabetical, must not yield), then :Start() on all (spawned). Defensive:
-- missing/broken modules are warned and skipped so the place always runs
-- mid-construction. Mobile-first (SOP §3.2): controllers must keep the
-- join-to-playing path light — defer heavy work out of Init.

local function safeRequire(moduleScript: ModuleScript): any
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(`[Client] failed to require {moduleScript:GetFullName()}: {result}`)
		return nil
	end
	return result
end

type ControllerEntry = { name: string, controller: any }
local controllers: { ControllerEntry } = {}

local registry: any = nil
local controllersModule = script:FindFirstChild("Controllers")
if controllersModule ~= nil and controllersModule:IsA("ModuleScript") then
	registry = safeRequire(controllersModule)
	for _, child in controllersModule:GetChildren() do
		if child:IsA("ModuleScript") then
			local controller = safeRequire(child)
			if type(controller) == "table" then
				table.insert(controllers, { name = child.Name, controller = controller })
			elseif controller ~= nil then
				warn(`[Client] controller {child.Name} did not return a table — skipped`)
			end
		end
	end
end

table.sort(controllers, function(a, b)
	return a.name < b.name
end)

-- Register everything before any Init so Controllers.Get works from Init on.
if type(registry) == "table" and type(registry._register) == "function" then
	for _, entry in controllers do
		registry._register(entry.name, entry.controller)
	end
end

-- Init phase: alphabetical, synchronous, controllers must not yield here.
-- Each controller receives the registry: function Controller:Init(registry)
-- so it can registry.Get("OtherController") without requiring siblings.
for _, entry in controllers do
	local init = entry.controller.Init
	if type(init) == "function" then
		local ok, err = pcall(init, entry.controller, registry)
		if not ok then
			warn(`[Client] {entry.name}:Init() failed: {err}`)
		end
	end
end

-- Start phase: spawned, may yield/run forever.
for _, entry in controllers do
	local start = entry.controller.Start
	if type(start) == "function" then
		task.spawn(function()
			local ok, err = pcall(start, entry.controller)
			if not ok then
				warn(`[Client] {entry.name}:Start() failed: {err}`)
			end
		end)
	end
end

print(`[Client] Rescue the Brainrots! — booted {#controllers} controller(s)`)
