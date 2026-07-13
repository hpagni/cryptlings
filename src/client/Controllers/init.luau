--!strict
-- CRYPTLINGS: NIGHT SHIFT — client controller registry (CONTRACTS v1 §A).
-- Controller ModuleScripts live as children of this module (one per file, names
-- ending "Controller", "UI", or "HUD"). The Stage 0 loader (init.client.luau)
-- requires and registers every child, then runs Init/Start — controllers reach
-- each other via Controllers.Get(name) instead of requiring siblings directly.

local Controllers = {}

local registered: { [string]: any } = {}

-- Loader-only. Controllers never call this.
function Controllers._register(name: string, controller: any)
	registered[name] = controller
end

-- Returns the controller's public table, or nil if absent/broken. All
-- controllers are registered before any Init runs, so Get is safe from Init on.
function Controllers.Get(name: string): any
	return registered[name]
end

-- Polls for late registration (defensive; normally Get suffices). Returns nil
-- after timeout (default 5s).
function Controllers.WaitFor(name: string, timeout: number?): any
	local deadline = os.clock() + (timeout or 5)
	while os.clock() < deadline do
		local controller = registered[name]
		if controller ~= nil then
			return controller
		end
		task.wait()
	end
	return nil
end

function Controllers.GetAll(): { [string]: any }
	return table.clone(registered)
end

return Controllers
