--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShelfService (Stage 5 "Display shelf rooms";
-- SOP §3.1 ⑤, §1.2, §3.2 friend-visitable hubs, §4.2; contracts §B, §D, §H, §I).
--
-- Slot model over profile.shelf.slots ({[slotId]: cryptlingId}): starter lot
-- slots s1..s8; the HOUSING_* upgrades (profile.housing.tier, written by
-- MonetizationService receipts) widen the lot to 12 (House) / 24 (2-Story) /
-- 60 (Mansion) and GetShelf reports housingTier so the lot builder can swap
-- in the right structure.
--
-- Placing DISPLAYS an owned Cryptling without consuming it: a slot is valid
-- when collection[cryptlingId] >= (copies of that id already displayed) + 1.
-- misprint_trophy is placeable — it sits in the collection like any other id
-- (Starter Pack exclusive shelf item; displaying it is its whole point, §4.2).
--
-- LAZY RECONCILE (no cross-module hooks — Stage 4 trading never calls us):
-- on profile load, on every Place/Remove, and on room build (GetShelf) we
-- prune slots whose displayed count exceeds the CURRENT collection count, so
-- a Cryptling traded away empties its slot on the next reconcile. Excess
-- copies are pruned highest-numbered slot first (deterministic).
--
-- AUTO-FILL (SOP §4.4 — load path ONLY, never Place/Remove): after the
-- load-time reconcile, empty valid slots within the current tier capacity are
-- topped up rarest-first from spare collection copies not already displayed.
-- Deterministic order: rarity desc (RARITY_ORDER reversed), then cryptlingId
-- asc, then lowest empty slot index first ("floor 1 front row first").
-- Occupied slots are NEVER overwritten — player pins are sacred.
--
-- Public API (lot builder / later stages):
--   ShelfService.GetShelf(ownerUserId) -> ShelfSnapshot?
--       {ownerUserId, slots, housingTier, maxSlots} after a fresh reconcile;
--       nil when the owner is not in this server or not yet loaded.
--   ShelfService.GetMaxSlots(player) -> number   -- 8 / 12 / 24 / 60 by tier
--   ShelfService.GetHousingTier(player) -> number -- tier of record
--       (ShelfRoomBuilder probes this name to pick the lot structure)
--   ShelfService.Place(player, slotId, cryptlingId) -> {ok, err?}
--   ShelfService.Remove(player, slotId) -> {ok, err?}
--       Also serve the Shelf.Place / Shelf.Remove remotes (contract §B).
--       err: "NOT_LOADED" | "BAD_SLOT" | "TIER_LOCKED" | "UNKNOWN_CRYPTLING"
--            | "NOT_OWNED" | "INTERNAL"
--
-- Fires ShelfChanged (S->all, contract §B) {ownerUserId, slots} after any
-- mutation (including reconcile pruning) and once when a profile loads, so
-- visiting clients always hold a current snapshot; the same payload goes to
-- ShelfRoomBuilder.NotifyShelfChanged so 3D displays update instantly (a
-- server module cannot listen to an S->C remote). Late joiners pull the same
-- snapshots once via Shelf.GetAll (contract §B). Analytics: shelf_place.
--
-- Test hook (specs only — never call from production code):
--   ShelfService.SetHousingTierForTest(player, tier: number?) -- nil clears

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

-- Slot-tier sizes (§G of record). [tier 0] = starter lot; tiers 1..3 come
-- from HOUSING_TIER_SLOTS.
local SHELF_BASE_SLOTS: number = (GameConstants :: any).SHELF_BASE_SLOTS or 8
local HOUSING_TIER_SLOTS: { number } = (GameConstants :: any).HOUSING_TIER_SLOTS or { 12, 24, 60 }
local HOUSING_MAX_TIER: number = (GameConstants :: any).HOUSING_MAX_TIER or 3
local HOUSING_MAX_SLOTS: number = (GameConstants :: any).HOUSING_MAX_SLOTS or 60

local function slotsForTier(tier: number): number
	if tier <= 0 then
		return SHELF_BASE_SLOTS
	end
	return HOUSING_TIER_SLOTS[math.min(tier, HOUSING_MAX_TIER)] or SHELF_BASE_SLOTS
end

-- Profile-load reconcile poll (build-local sub-tunables; house pattern, see
-- LockerService.INVITER_LOAD_POLL_SECONDS). Bounded by the player leaving.
local PROFILE_LOAD_POLL_SECONDS = 0.5
local PROFILE_LOAD_TIMEOUT_SECONDS = 120

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades that feature, never the shelf math). MonetizationService is a
-- Stage 6 module — until it ships, OwnsPass safely defaults to false.
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

-- PlayerDataService with the surface this service relies on, or nil.
local function getDataService(): any
	local dataService = getSibling("PlayerDataService")
	if
		dataService ~= nil
		and type(dataService.Get) == "function"
		and type(dataService.IsLoaded) == "function"
		and type(dataService.Update) == "function"
	then
		return dataService
	end
	return nil
end

local function track(player: Player, event: string, props: { [string]: any }?)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

--------------------------------------------------------------------------------
-- Service
--------------------------------------------------------------------------------

local ShelfService = {}

-- Reconciled shelf state handed to the lot builder (GetShelf).
export type ShelfSnapshot = {
	ownerUserId: number,
	slots: { [string]: string }, -- {[slotId]: cryptlingId}
	housingTier: number,
	maxSlots: number,
}

type Result = { ok: boolean, err: string? }

-- Test-only housing-tier override (SetHousingTierForTest). nil = read profile.
local housingTierOverride: { [Player]: number } = {}

-- Housing tier of record: profile.housing.tier (written only by
-- MonetizationService receipts). Non-yielding (plain profile read).
local function housingTierOf(player: Player): number
	local override = housingTierOverride[player]
	if override ~= nil then
		return override
	end
	local dataService = getDataService()
	if dataService ~= nil and dataService.IsLoaded(player) then
		local data = dataService.Get(player)
		if type(data) == "table" and type((data :: any).housing) == "table" then
			local tier = (data :: any).housing.tier
			if type(tier) == "number" then
				return math.clamp(math.floor(tier), 0, HOUSING_MAX_TIER)
			end
		end
	end
	return 0
end

--------------------------------------------------------------------------------
-- Slot ids — canonical "s1".."s24"; leading zeros rejected so a given slot has
-- exactly one key form in the profile table
--------------------------------------------------------------------------------

local function slotIndexOf(slotId: string): number?
	local digits = string.match(slotId, "^s(%d+)$")
	if digits == nil or string.sub(digits, 1, 1) == "0" then
		return nil
	end
	local index = tonumber(digits)
	if index == nil or index < 1 or index > HOUSING_MAX_SLOTS then
		return nil
	end
	return index
end

--------------------------------------------------------------------------------
-- Reconcile — the lazy pruning pass (runs INSIDE PlayerDataService.Update)
--------------------------------------------------------------------------------

-- Prunes shelf slots so that, per cryptlingId, displayed count <= current
-- collection count (covers Cryptlings traded away in Stage 4), and drops any
-- malformed slot key / unknown cryptling id defensively. Excess copies are
-- removed highest-numbered slot first. Returns true when anything changed.
-- Pure over the profile table: never yields, safe inside Update.
local function reconcileSlots(data: Types.ProfileData): boolean
	local slots = data.shelf.slots
	local changed = false

	-- Pass 1: structural validity, and bucket displayed slots per cryptlingId.
	local displayed: { [string]: { number } } = {}
	for slotId, cryptlingId in pairs(slots) do
		local index = if type(slotId) == "string" then slotIndexOf(slotId) else nil
		local valid = index ~= nil and type(cryptlingId) == "string" and RarityTable.GetCryptling(cryptlingId) ~= nil
		if not valid then
			slots[slotId] = nil
			changed = true
		else
			local bucket = displayed[cryptlingId]
			if bucket == nil then
				bucket = {}
				displayed[cryptlingId] = bucket
			end
			table.insert(bucket, index :: number)
		end
	end

	-- Pass 2: per id, prune displayed copies down to the owned count.
	for cryptlingId, indices in pairs(displayed) do
		local owned = data.collection[cryptlingId] or 0
		local excess = #indices - owned
		if excess > 0 then
			table.sort(indices, function(a, b)
				return a > b -- highest-numbered slots empty first
			end)
			for i = 1, excess do
				slots[`s{indices[i]}`] = nil
			end
			changed = true
		end
	end

	return changed
end

--------------------------------------------------------------------------------
-- Auto-fill — deterministic rarest-first default display (SOP §4.4). Runs
-- ONLY inside the load-time reconcile, so the Place/Remove tier-capacity
-- contracts ("9th slot rejected at tier 0") are untouched.
--------------------------------------------------------------------------------

-- Rarity rank per RARITY_ORDER position (Common = 1 .. Mythical = 7); a
-- higher rank is rarer, so auto-fill sorts rank descending.
local rarityRank: { [string]: number } = {}
for index, rarity in RarityTable.RARITY_ORDER do
	rarityRank[rarity] = index
end

local function rarityRankOf(cryptlingId: string): number
	local def = RarityTable.GetCryptling(cryptlingId)
	if def ~= nil and type(def.rarity) == "string" then
		return rarityRank[def.rarity] or 0
	end
	return 0
end

-- Fills EMPTY valid slots (s1..s<maxSlots>) with spare owned copies the
-- player is not already displaying, rarest first. Spare = collection count
-- minus displayed count (computed AFTER reconcileSlots, so auto-fill can
-- never mint a display beyond the owned count). Never overwrites an occupied
-- slot. Pure over the profile table: never yields, safe inside Update.
-- Returns true when anything was placed.
local function autoFillSlots(data: Types.ProfileData, maxSlots: number): boolean
	local slots = data.shelf.slots

	-- Empty valid slot indices, ascending (lowest index = front row).
	local emptyIndices: { number } = {}
	for index = 1, maxSlots do
		if slots[`s{index}`] == nil then
			table.insert(emptyIndices, index)
		end
	end
	if #emptyIndices == 0 then
		return false
	end

	-- Displayed copies per id (slots were just reconciled: entries are valid).
	local displayedCount: { [string]: number } = {}
	for _, cryptlingId in pairs(slots) do
		displayedCount[cryptlingId] = (displayedCount[cryptlingId] or 0) + 1
	end

	-- Spare owned copies per known id; junk collection entries are skipped
	-- defensively (same posture as reconcileSlots).
	local spareById: { [string]: number } = {}
	local candidateIds: { string } = {}
	for cryptlingId, owned in pairs(data.collection) do
		if
			type(cryptlingId) == "string"
			and type(owned) == "number"
			and RarityTable.GetCryptling(cryptlingId) ~= nil
		then
			local spare = math.floor(owned) - (displayedCount[cryptlingId] or 0)
			if spare > 0 then
				spareById[cryptlingId] = spare
				table.insert(candidateIds, cryptlingId)
			end
		end
	end
	if #candidateIds == 0 then
		return false
	end

	-- Deterministic fill order: rarity desc, then id asc.
	table.sort(candidateIds, function(a, b)
		local rankA, rankB = rarityRankOf(a), rarityRankOf(b)
		if rankA ~= rankB then
			return rankA > rankB -- rarest first
		end
		return a < b -- then id asc (total order: ids are unique keys)
	end)

	local cursor = 1
	local changed = false
	for _, cryptlingId in candidateIds do
		local spare = spareById[cryptlingId]
		while spare > 0 and cursor <= #emptyIndices do
			slots[`s{emptyIndices[cursor]}`] = cryptlingId
			cursor += 1
			spare -= 1
			changed = true
		end
		if cursor > #emptyIndices then
			break
		end
	end
	return changed
end

--------------------------------------------------------------------------------
-- ShelfChanged push (S->all, contract §B) — visitors render from this
--------------------------------------------------------------------------------

local function fireShelfChanged(ownerUserId: number, slots: { [string]: string })
	-- Same payload to the room builder first (3D displays), then to clients.
	local builder = getSibling("ShelfRoomBuilder")
	if builder ~= nil and type(builder.NotifyShelfChanged) == "function" then
		local notified, notifyErr = pcall(builder.NotifyShelfChanged, ownerUserId, slots)
		if not notified then
			warn(`[ShelfService] NotifyShelfChanged failed for {ownerUserId}: {notifyErr}`)
		end
	end
	local ok, err = pcall(function()
		Remotes.GetEvent("ShelfChanged"):FireAllClients({
			ownerUserId = ownerUserId,
			slots = slots,
		})
	end)
	if not ok then
		warn(`[ShelfService] ShelfChanged push failed for {ownerUserId}: {err}`)
	end
end

--------------------------------------------------------------------------------
-- Place / Remove — also serve the Shelf.Place / Shelf.Remove remotes
--------------------------------------------------------------------------------

-- Displays an owned Cryptling in a slot valid for the player's tier. Never
-- consumes the copy: validity is collection[id] >= already-displayed + 1
-- (the target slot's current occupant excluded, so re-placing the same id in
-- the same slot is a clean no-op overwrite).
function ShelfService.Place(player: Player, slotId: string, cryptlingId: string): Result
	if type(slotId) ~= "string" or type(cryptlingId) ~= "string" then
		return { ok = false, err = "BAD_SLOT" }
	end
	local slotIndex = slotIndexOf(slotId)
	if slotIndex == nil then
		return { ok = false, err = "BAD_SLOT" }
	end
	if RarityTable.GetCryptling(cryptlingId) == nil then
		return { ok = false, err = "UNKNOWN_CRYPTLING" }
	end

	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return { ok = false, err = "NOT_LOADED" }
	end

	-- Slots beyond the current housing tier's capacity are rejected here.
	if slotIndex > slotsForTier(housingTierOf(player)) then
		return { ok = false, err = "TIER_LOCKED" }
	end

	local placed = false
	local snapshot: { [string]: string } = {}
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		reconcileSlots(data) -- prune first so stale displays never pad the count

		local slots = data.shelf.slots
		local displayedElsewhere = 0
		for otherSlotId, displayedId in pairs(slots) do
			if displayedId == cryptlingId and otherSlotId ~= slotId then
				displayedElsewhere += 1
			end
		end
		if (data.collection[cryptlingId] or 0) < displayedElsewhere + 1 then
			return -- not enough owned copies to display one more
		end

		slots[slotId] = cryptlingId
		placed = true
		snapshot = table.clone(slots)
	end) == true

	if not updated then
		return { ok = false, err = "INTERNAL" }
	end
	if not placed then
		return { ok = false, err = "NOT_OWNED" }
	end

	fireShelfChanged(player.UserId, snapshot)
	track(player, "shelf_place", { slotId = slotId, cryptlingId = cryptlingId })
	return { ok = true }
end

-- Clears a slot. Idempotent: removing an already-empty (but valid) slot is ok.
function ShelfService.Remove(player: Player, slotId: string): Result
	if type(slotId) ~= "string" or slotIndexOf(slotId) == nil then
		return { ok = false, err = "BAD_SLOT" }
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return { ok = false, err = "NOT_LOADED" }
	end

	local mutated = false
	local snapshot: { [string]: string } = {}
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		local pruned = reconcileSlots(data)
		local hadEntry = data.shelf.slots[slotId] ~= nil
		data.shelf.slots[slotId] = nil
		mutated = pruned or hadEntry
		snapshot = table.clone(data.shelf.slots)
	end) == true

	if not updated then
		return { ok = false, err = "INTERNAL" }
	end
	if mutated then
		fireShelfChanged(player.UserId, snapshot)
	end
	return { ok = true }
end

--------------------------------------------------------------------------------
-- GetShelf — the room builder's lookup (reconciles on every call, so a room
-- build never displays a Cryptling the owner no longer holds)
--------------------------------------------------------------------------------

function ShelfService.GetShelf(ownerUserId: number): ShelfSnapshot?
	if type(ownerUserId) ~= "number" then
		return nil
	end
	local owner = Players:GetPlayerByUserId(ownerUserId)
	if owner == nil then
		return nil -- friend-visitable hubs are same-server (§3.2)
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(owner) then
		return nil
	end

	local housingTier = housingTierOf(owner)

	local pruned = false
	local snapshot: { [string]: string }? = nil
	dataService.Update(owner, function(data: Types.ProfileData)
		pruned = reconcileSlots(data)
		snapshot = table.clone(data.shelf.slots)
	end)
	if snapshot == nil then
		return nil
	end
	local slots = snapshot :: { [string]: string }
	if pruned then
		fireShelfChanged(ownerUserId, slots) -- a prune is a mutation: push it
	end

	return {
		ownerUserId = ownerUserId,
		slots = slots,
		housingTier = housingTier,
		maxSlots = slotsForTier(housingTier),
	}
end

-- Slot capacity for the player's current housing tier (8 / 12 / 24 / 60).
function ShelfService.GetMaxSlots(player: Player): number
	return slotsForTier(housingTierOf(player))
end

-- Housing tier of record (ShelfRoomBuilder probes this name to choose the
-- lot structure; honors the SetHousingTierForTest override).
function ShelfService.GetHousingTier(player: Player): number
	return housingTierOf(player)
end

--------------------------------------------------------------------------------
-- Profile-load reconcile — covers trades/changes from the player's PREVIOUS
-- session (e.g. traded away on server A, rejoined on server B), then runs
-- the SOP §4.4 auto-fill pass over whatever podiums the prune left empty
--------------------------------------------------------------------------------

local function reconcileOnLoad(player: Player)
	local dataService = getDataService()
	if dataService == nil then
		return
	end
	local deadline = os.clock() + PROFILE_LOAD_TIMEOUT_SECONDS
	while not dataService.IsLoaded(player) do
		if os.clock() >= deadline or player.Parent == nil then
			return
		end
		task.wait(PROFILE_LOAD_POLL_SECONDS)
	end

	-- Capacity for the auto-fill pass — honors the spec tier override, exactly
	-- like Place's TIER_LOCKED gate. Plain profile read, never yields.
	local capacity = slotsForTier(housingTierOf(player))

	local snapshot: { [string]: string }? = nil
	dataService.Update(player, function(data: Types.ProfileData)
		reconcileSlots(data)
		-- SOP §4.4 default selection: prune first, then top up empty podiums
		-- rarest-first so a fresh lot looks good with zero effort.
		autoFillSlots(data, capacity)
		snapshot = table.clone(data.shelf.slots)
	end)
	if snapshot ~= nil and player.Parent ~= nil then
		-- Push unconditionally on load: this is every client's first (and the
		-- room builder's fallback) snapshot of a newly arrived owner's shelf.
		fireShelfChanged(player.UserId, snapshot :: { [string]: string })
	end
end

--------------------------------------------------------------------------------
-- Test hook (specs only — contract acceptance: "9th slot rejected at tier 0"
-- without a receipt pipeline)
--------------------------------------------------------------------------------

-- Forces (0..3) or clears (nil) the housing-tier answer for one player.
function ShelfService.SetHousingTierForTest(player: Player, tier: number?)
	if tier == nil then
		housingTierOverride[player] = nil
	else
		housingTierOverride[player] = math.clamp(math.floor(tier), 0, HOUSING_MAX_TIER)
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function ShelfService:Init()
	-- Remotes already exist (init.server runs Remotes.InitServer() first).
	local ok, err = pcall(function()
		Remotes.GetFunction("Shelf.Place").OnServerInvoke = function(player: Player, slotId: any, cryptlingId: any)
			if type(slotId) ~= "string" or type(cryptlingId) ~= "string" then
				return { ok = false, err = "BAD_SLOT" }
			end
			return ShelfService.Place(player, slotId, cryptlingId)
		end
		Remotes.GetFunction("Shelf.Remove").OnServerInvoke = function(player: Player, slotId: any)
			if type(slotId) ~= "string" then
				return { ok = false, err = "BAD_SLOT" }
			end
			return ShelfService.Remove(player, slotId)
		end
		-- Late-join sync (contract §B): one ShelfChanged-shaped snapshot per
		-- loaded owner, pulled once by ShelfUI at Start. Read-only — the heavy
		-- reconcile stays on the push/mutation paths.
		Remotes.GetFunction("Shelf.GetAll").OnServerInvoke = function(_requester: Player)
			local snapshots: { { ownerUserId: number, slots: { [string]: string } } } = {}
			local dataService = getDataService()
			if dataService ~= nil then
				for _, owner in Players:GetPlayers() do
					if dataService.IsLoaded(owner) then
						local data = dataService.Get(owner)
						if
							type(data) == "table"
							and type(data.shelf) == "table"
							and type(data.shelf.slots) == "table"
						then
							table.insert(snapshots, {
								ownerUserId = owner.UserId,
								slots = table.clone(data.shelf.slots),
							})
						end
					end
				end
			end
			return snapshots
		end
	end)
	if not ok then
		warn(`[ShelfService] remote bind failed: {err}`)
	end
end

function ShelfService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(reconcileOnLoad, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(reconcileOnLoad, player) -- joins that beat service start
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		housingTierOverride[player] = nil
	end)
end

return ShelfService
