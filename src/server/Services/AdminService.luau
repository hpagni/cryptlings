--!strict
-- CRYPTLINGS: NIGHT SHIFT — AdminService (R4-1 "/unlockall" admin stack;
-- LOBBY_SOP_ADDENDUM_3 §R4-1, LOBBY_BUILD_PLAN_R4 WP1.1).
--
-- The single AUTHORITY for "who is an admin" plus the admin mutations
-- (session grant/revoke and the unlock-everything sweep). AdminCommands (chat
-- capture) has ZERO authority of its own: every mutation here re-asserts the
-- actor FIRST LINE, and MonetizationService.GrantSkuForAdmin gates again at
-- the grant itself — defense in depth, so no future code path can bypass auth.
--
-- IsAdmin(userId) layers, evaluated in order (R4-1 §2):
--   1. RunService:IsStudio() — also covers the unpublished-place quirk where
--      game.CreatorId == 0.
--   2. Creator: CreatorType.User and userId == game.CreatorId. Group-owned
--      branch shipped anyway: rank >= GROUP_ADMIN_RANK (254), resolved ONCE
--      per player at PlayerAdded (spawned — GetRankInGroup is a yielding web
--      call, never in the per-command hot path); cache cleared on
--      PlayerRemoving.
--   3. AdminConfig.Admins[userId] — the permanent allowlist; ships by editing
--      that file. No persistence layer by design.
--   4. sessionAdmins[userId] — /admin grants; in-memory only, lost on server
--      shutdown by design.
--
-- UnlockAll walks PriceLadder.Rows through MonetizationService.GrantSkuForAdmin
-- (lazy sibling — house pattern): rows with wiredInMvp == false are skipped;
-- housing is granted ONLY via the 3-step chain in order HOUSING_HOUSE ->
-- HOUSING_TWO_STORY_UP -> HOUSING_MANSION_UP_TWO_STORY (the requiresHousingTier
-- refusal in the receipt handler makes the order load-bearing; dataService
-- updates are synchronous, so each grant satisfies the next prerequisite) and
-- the redundant direct/skip housing rows count as skipped. A declined SKU
-- (compliance gate, unloaded profile) is logged, counted skipped, and the
-- sweep continues — it never aborts.
--
-- Every mutation prints one greppable `[ADMIN]` line (Developer Console audit).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminConfig = require(Shared:WaitForChild("Config"):WaitForChild("AdminConfig"))
local PriceLadder = require(Shared:WaitForChild("Economy"):WaitForChild("PriceLadder")) :: any

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local GROUP_ADMIN_RANK = 254 -- group-owned branch: owner (255) + top admins

-- The 3-step housing upgrade chain, granted strictly IN THIS ORDER (tier
-- prerequisites 0 -> 1 -> 2, ending at housing.tier 3).
local HOUSING_CHAIN = table.freeze({ "HOUSING_HOUSE", "HOUSING_TWO_STORY_UP", "HOUSING_MANSION_UP_TWO_STORY" })
local HOUSING_CHAIN_SET: { [string]: boolean } = {
	HOUSING_HOUSE = true,
	HOUSING_TWO_STORY_UP = true,
	HOUSING_MANSION_UP_TWO_STORY = true,
}

-- The redundant direct/skip housing rows: the chain already lands tier 3, so
-- the generic loop skips (and counts) these instead of granting them.
local HOUSING_REDUNDANT: { [string]: boolean } = {
	HOUSING_TWO_STORY = true,
	HOUSING_MANSION = true,
	HOUSING_MANSION_UP_HOUSE = true,
}

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades the feature, never the boot)
--------------------------------------------------------------------------------

local siblingCache: { [string]: any } = {}

local function getSibling(name: string): any
	local cached = siblingCache[name]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		return cached
	end
	local container = script.Parent
	local module = container and container:FindFirstChild(name)
	local result: any = nil
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, required = pcall(require, module)
		if ok and type(required) == "table" then
			result = required
		end
	end
	siblingCache[name] = if result ~= nil then result else false
	return result
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

export type AdminResult = { ok: boolean, err: string? }
export type UnlockAllResult = { ok: boolean, granted: number, skipped: number, err: string? }

local AdminService = {}

-- /admin session grants — in-memory ONLY; die with the server by design.
local sessionAdmins: { [number]: boolean } = {}

-- Group-owned branch: userId -> (rank >= GROUP_ADMIN_RANK), resolved once at
-- PlayerAdded (the web call yields), cleared on PlayerRemoving.
local groupAdminCache: { [number]: boolean } = {}

--------------------------------------------------------------------------------
-- IsAdmin — the permission ladder (R4-1 §2). Never yields.
--------------------------------------------------------------------------------

function AdminService.IsAdmin(userId: number): boolean
	if type(userId) ~= "number" then
		return false
	end
	if RunService:IsStudio() then
		return true -- layer 1; also covers unpublished places (CreatorId == 0)
	end
	if game.CreatorType == Enum.CreatorType.User then
		if userId == game.CreatorId then
			return true -- layer 2: personal-owned creator
		end
	elseif game.CreatorType == Enum.CreatorType.Group then
		if groupAdminCache[userId] == true then
			return true -- layer 2 (group branch): cached rank >= 254
		end
	end
	if AdminConfig.Admins[userId] == true then
		return true -- layer 3: shipped allowlist
	end
	return sessionAdmins[userId] == true -- layer 4: /admin session grant
end

--------------------------------------------------------------------------------
-- Mutations — ALL first-line assert the actor (defense in depth with the
-- GrantSkuForAdmin gate). Denials are logged with the same [ADMIN] prefix.
--------------------------------------------------------------------------------

function AdminService.Grant(target: Player, actorUserId: number): AdminResult
	if not AdminService.IsAdmin(actorUserId) then
		print(`[ADMIN] {tostring(actorUserId)} denied admin-grant (NOT_ADMIN)`)
		return { ok = false, err = "NOT_ADMIN" }
	end
	if typeof(target) ~= "Instance" or not target:IsA("Player") then
		return { ok = false, err = "BAD_TARGET" }
	end
	sessionAdmins[target.UserId] = true
	print(`[ADMIN] {actorUserId} admin {target.UserId} ({target.Name}) — session grant`)
	return { ok = true }
end

function AdminService.Revoke(target: Player, actorUserId: number): AdminResult
	if not AdminService.IsAdmin(actorUserId) then
		print(`[ADMIN] {tostring(actorUserId)} denied admin-revoke (NOT_ADMIN)`)
		return { ok = false, err = "NOT_ADMIN" }
	end
	if typeof(target) ~= "Instance" or not target:IsA("Player") then
		return { ok = false, err = "BAD_TARGET" }
	end
	if game.CreatorType == Enum.CreatorType.User and target.UserId == game.CreatorId then
		print(`[ADMIN] {actorUserId} unadmin {target.UserId} refused (IS_CREATOR)`)
		return { ok = false, err = "IS_CREATOR" }
	end
	sessionAdmins[target.UserId] = nil
	print(`[ADMIN] {actorUserId} unadmin {target.UserId} ({target.Name}) — session revoke`)
	return { ok = true }
end

-- Grants every wired SKU to `target` via MonetizationService.GrantSkuForAdmin
-- (which re-gates the actor at the mutation). May yield (receipt pipeline);
-- call from chat/command threads only, never from Init.
function AdminService.UnlockAll(target: Player, actorUserId: number): UnlockAllResult
	if not AdminService.IsAdmin(actorUserId) then
		print(`[ADMIN] {tostring(actorUserId)} denied unlockall (NOT_ADMIN)`)
		return { ok = false, granted = 0, skipped = 0, err = "NOT_ADMIN" }
	end
	if typeof(target) ~= "Instance" or not target:IsA("Player") then
		return { ok = false, granted = 0, skipped = 0, err = "BAD_TARGET" }
	end
	local monetization = getSibling("MonetizationService")
	if monetization == nil or type(monetization.GrantSkuForAdmin) ~= "function" then
		return { ok = false, granted = 0, skipped = 0, err = "NO_MONETIZATION" }
	end

	local granted = 0
	local skipped = 0
	local function grantSku(sku: string)
		local result = monetization.GrantSkuForAdmin(target, sku, actorUserId)
		if type(result) == "table" and result.ok == true then
			granted += 1
		else
			-- Compliance-declined / not-loaded SKUs count as skipped; the sweep
			-- never aborts (R4-1 §5: a declined lootbox SKU is correct behavior).
			skipped += 1
			local why = if type(result) == "table" then tostring(result.err) else "ERROR"
			print(`[ADMIN] {actorUserId} unlockall {target.UserId} skipped {sku} ({why})`)
		end
	end

	-- Generic sweep: not-wired rows and the redundant housing rows are counted
	-- skipped; the chain rows are deferred so housing lands strictly in order.
	for _, row in PriceLadder.Rows :: { any } do
		if row.wiredInMvp ~= true or HOUSING_REDUNDANT[row.sku] == true then
			skipped += 1
		elseif HOUSING_CHAIN_SET[row.sku] ~= true then
			grantSku(row.sku)
		end
	end

	-- Housing chain LAST, strictly ordered: each synchronous grant raises
	-- housing.tier to satisfy the next step's requiresHousingTier refusal.
	for _, sku in HOUSING_CHAIN do
		grantSku(sku)
	end

	print(`[ADMIN] {actorUserId} unlockall {target.UserId} granted={granted} skipped={skipped}`)
	return { ok = true, granted = granted, skipped = skipped }
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

-- Group-owned branch only: resolve the yielding rank check once per player.
local function cacheGroupRank(player: Player)
	if game.CreatorType ~= Enum.CreatorType.Group then
		return
	end
	local ok, rank = pcall(function()
		return player:GetRankInGroup(game.CreatorId)
	end)
	if ok and type(rank) == "number" then
		groupAdminCache[player.UserId] = rank >= GROUP_ADMIN_RANK
	end
end

function AdminService:Init()
	-- No yields (loader contract): the rank resolution is spawned.
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(cacheGroupRank, player)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		groupAdminCache[player.UserId] = nil
		-- sessionAdmins is deliberately NOT cleared: a session grant survives a
		-- rejoin into the SAME server and dies with the server (R4-1 §2.4).
	end)
end

function AdminService:Start()
	-- Players who joined before this service loaded (loader races PlayerAdded).
	for _, player in Players:GetPlayers() do
		task.spawn(cacheGroupRank, player)
	end
end

return AdminService
