--!strict
-- CRYPTLINGS: NIGHT SHIFT — CursorUnlock (R4-2, LOBBY_SOP_ADDENDUM_3).
-- Refcounted first-person cursor release for menus. The PlayerModule camera
-- re-asserts MouseBehavior.LockCenter EVERY frame from its render-step bind at
-- Enum.RenderPriority.Camera.Value (200), so a one-shot Default write is
-- clobbered within one frame. This module binds ONE render step at 201 (after
-- the camera, so the override wins) that forces Default each frame while any
-- menu token is held. Token SET (not a counter): double-acquire/double-release
-- are idempotent; the cursor stays free until the LAST open menu releases.
-- No restore code is needed — the camera script re-asserts LockCenter on the
-- next frame after the bind is removed. While Default is forced, mouse deltas
-- stop driving the camera, so the view doesn't spin under the menu.
-- Touch no-op via the per-step MouseEnabled check (NOT a TouchEnabled gate —
-- tablets attach mice mid-session). MouseIconEnabled is never touched.
-- BindToRenderStep throws on duplicate names: this module is the single owner
-- of the bind. No Modal-GuiButton hack, no CameraMinZoomDistance bumps.
--
-- Public API (Controllers.Get("CursorUnlock")):
--   CursorUnlock.acquire(token: string)  -- token = the calling module's name
--   CursorUnlock.release(token: string)  -- every gui-hiding path must release

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local BIND_NAME = "CryptlingsCursorUnlock"
local PRIORITY = Enum.RenderPriority.Camera.Value + 1 -- 201: AFTER the camera's 200

local CursorUnlock = {}
local openTokens: { [string]: true } = {} -- token SET, not a counter: double-release idempotent
local bound = false

local function step()
	if UserInputService.MouseEnabled then -- touch no-op; handles tablet mouse hot-plug
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

function CursorUnlock.acquire(token: string)
	if openTokens[token] then
		return
	end
	openTokens[token] = true
	if not bound then
		bound = true
		RunService:BindToRenderStep(BIND_NAME, PRIORITY, step)
	end
end

function CursorUnlock.release(token: string)
	if not openTokens[token] then
		return
	end
	openTokens[token] = nil
	if bound and next(openTokens) == nil then
		bound = false
		RunService:UnbindFromRenderStep(BIND_NAME)
		-- No restore code: the camera script re-asserts LockCenter next frame.
	end
end

return CursorUnlock
