--!strict
-- CRYPTLINGS: NIGHT SHIFT — ExtractionService (Stage 1 "Run loop"; SOP §3.1 ①, §1.2).
-- The loading-dock trigger: stand on a tagged "ExtractionDock" part for the hold
-- time during an active shift and your carried cases bank to your profile locker
-- as sealed CaseStubs (source="run") — boxes only open AFTER you escape (§1.1).
-- Pay: contract §G formula (5 x tier per banked case + 10 extraction bonus),
-- times ShiftService.GetPayMultiplier (PASS_2X_PAY).
--
-- Writes banked cases directly to profile.locker.cases via PlayerDataService
-- .Update (contract I: LockerService is pure logic over that same field — no
-- rewiring needed). Sets stats.secondExtractionAt when extractions hit 2 (the
-- Stage 6 starter-pack trigger reads it). Fires CoreLoop funnel step 3 and the
-- owner-only ExtractionResult remote. Extracted players wait out the shift at
-- the hub (ShiftService.MarkExtracted).
--
-- R2 session scoping (Lobby SOP Addendum 1 Change 6.5 / WP4.3): every tagged
-- dock resolves to its owning session — ancestor model stamped with the
-- "SessionId" attribute by FloorGenService.Generate — cross-checked against
-- ShiftService.GetSessionOf(player). A player banks ONLY on a dock belonging
-- to THEIR session and only while that session is Active. When the facade
-- lacks GetSessionOf the global shift.IsActive() gate survives as the legacy
-- fallback (house rule: degrade to today's global behavior).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

--------------------------------------------------------------------------------
-- Stage-1 local tuning (not in GameConstants v1 — flagged to the integrator)
--------------------------------------------------------------------------------

local EXTRACTION_HOLD_SECONDS = 3 -- spec: player inside the dock 3s -> banked
local SCAN_INTERVAL_SECONDS = 0.25
local DOCK_HORIZONTAL_MARGIN_STUDS = 1 -- forgiving edge (mobile-first, §3.2)
local DOCK_HEIGHT_STUDS = 8 -- how far above the dock pad still counts

-- CollectionService tag shared with FloorGenService / ShiftService's fallback floor.
local TAG_EXTRACTION_DOCK = "ExtractionDock"
-- Model attribute FloorGenService stamps on session floors (R2 Change 6).
local ATTR_SESSION_ID = "SessionId"

--------------------------------------------------------------------------------
-- Lazy sibling resolution
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

local function track(player: Player, event: string, props: { [string]: any }?)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

local function funnelStep(player: Player, step: number, stepName: string)
	local analytics = getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.FunnelStep) == "function" then
		pcall(analytics.FunnelStep, player, step, stepName)
	end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local ExtractionService = {}

local dwellSeconds: { [Player]: number } = {}
local extractionResultRemote: RemoteEvent? = nil

--------------------------------------------------------------------------------
-- Dock geometry
--------------------------------------------------------------------------------

local function isInsideDock(dock: BasePart, position: Vector3): boolean
	local relative = dock.CFrame:PointToObjectSpace(position)
	local half = dock.Size / 2
	return math.abs(relative.X) <= half.X + DOCK_HORIZONTAL_MARGIN_STUDS
		and math.abs(relative.Z) <= half.Z + DOCK_HORIZONTAL_MARGIN_STUDS
		and relative.Y >= -half.Y - 1
		and relative.Y <= half.Y + DOCK_HEIGHT_STUDS
end

local function getActiveDocks(): { BasePart }
	local docks: { BasePart } = {}
	for _, instance in CollectionService:GetTagged(TAG_EXTRACTION_DOCK) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			table.insert(docks, instance)
		end
	end
	return docks
end

-- R2 (WP4.3): ancestor-walk a dock to the floor model carrying the "SessionId"
-- attribute. Legacy floors (the pre-handle shim path and ShiftService's greybox
-- fallback) carry no stamp — or an empty one — and resolve to nil.
local function getDockSessionId(dock: BasePart): string?
	local node: Instance? = dock
	while node ~= nil and node ~= Workspace do
		local attr = node:GetAttribute(ATTR_SESSION_ID)
		if type(attr) == "string" and attr ~= "" then
			return attr
		end
		node = node.Parent
	end
	return nil
end

-- A dock belongs to the player when its stamped SessionId matches their
-- session's id; unstamped (legacy) docks fall back to floor-root containment,
-- and when even the floor root is unknown the check degrades to today's
-- any-dock behavior (house rule).
local function dockMatchesSession(
	dock: BasePart,
	dockSessionId: string?,
	playerSessionId: string?,
	playerFloorRoot: Instance?
): boolean
	if dockSessionId ~= nil then
		return dockSessionId == playerSessionId
	end
	if playerFloorRoot ~= nil then
		return dock:IsDescendantOf(playerFloorRoot)
	end
	return true
end

--------------------------------------------------------------------------------
-- Extraction
--------------------------------------------------------------------------------

local function extract(player: Player)
	local shift = getSibling("ShiftService")
	if shift == nil then
		return
	end
	-- R2 (WP4.3): a player banks only while THEIR session is Active. The global
	-- any-session gate survives as the fallback when the facade lacks GetSessionOf.
	if type(shift.GetSessionOf) == "function" then
		local okSession, session = pcall(shift.GetSessionOf, player)
		if not okSession or session == nil or (session :: any).state ~= "Active" then
			return
		end
	elseif type(shift.IsActive) ~= "function" or not shift.IsActive() then
		return
	end
	if type(shift.HasExtracted) == "function" and shift.HasExtracted(player) then
		return
	end

	-- ">= 0 cases": extracting empty-handed still banks the shift (bonus pay only).
	local taken: { { uid: string, tier: number } } = {}
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.TakeAllCarried) == "function" then
		taken = caseService.TakeAllCarried(player) or {}
	end

	local multiplier = 1
	if type(shift.GetPayMultiplier) == "function" then
		local result = shift.GetPayMultiplier(player)
		if type(result) == "number" then
			multiplier = result
		end
	end

	local now = os.time()
	local stubs: { { [string]: any } } = {}
	local bankedCaseUids: { string } = {}
	local pay = GameConstants.SHIFT_PAY_EXTRACTION_BONUS
	for _, case in taken do
		pay += GameConstants.SHIFT_PAY_PER_CASE_TIER * case.tier
		table.insert(stubs, {
			uid = case.uid,
			tier = case.tier,
			lineId = "line1",
			acquiredAt = now,
			source = "run",
			mega = case.mega == true or nil, -- guarantees a Mythical when opened
			guaranteedRarity = case.guaranteedRarity, -- preserve any forced rarity (e.g. intro boxes); nil-safe, behaves as before when absent
		})
		table.insert(bankedCaseUids, case.uid)
	end
	pay = math.floor(pay * multiplier)

	local extractionCount = 0
	local saved = false
	local dataService = getSibling("PlayerDataService")
	if dataService ~= nil and type(dataService.Update) == "function" then
		saved = dataService.Update(player, function(data)
			for _, stub in stubs do
				table.insert(data.locker.cases, stub)
			end
			data.stats.extractions += 1
			data.stats.casesBanked += #stubs
			data.shiftPay += pay
			if data.stats.extractions == 2 and data.stats.secondExtractionAt == 0 then
				data.stats.secondExtractionAt = now -- Stage 6 starter-pack trigger reads this
			end
			extractionCount = data.stats.extractions
		end) == true
	end
	if not saved then
		warn(`[ExtractionService] failed to bank {#stubs} case(s) for {player.Name} (profile not loaded?)`)
	elseif #stubs > 0 then
		-- Surface the freshly banked cases on the owner's LockerChanged stream.
		-- LockerService owns the push (this service only writes the field);
		-- spawned because the snapshot path may yield on a VIP-pass lookup.
		local locker = getSibling("LockerService")
		if locker ~= nil and type(locker.NotifyLockerChanged) == "function" then
			task.spawn(function()
				pcall(locker.NotifyLockerChanged, player)
			end)
		end

		-- Best Employees metric (R2 Addendum 1 Change 2): banked-at-extraction
		-- crates only — credited strictly when saved == true and #stubs > 0
		-- (exploit-resistant; this branch is exactly that). pcall-fenced so a
		-- board/stats failure never touches the banking path.
		local sessionStats = getSibling("SessionStatsService")
		if sessionStats ~= nil and type(sessionStats.AddCrates) == "function" then
			pcall(sessionStats.AddCrates, player, #stubs)
		end
	end

	if type(shift.MarkExtracted) == "function" then
		shift.MarkExtracted(player) -- extracted players wait at the hub
	end

	funnelStep(player, 3, "extraction") -- CoreLoop funnel step 3 (§3.4)
	track(player, "extraction", { cases = #stubs, shiftPay = pay })

	if extractionResultRemote ~= nil then
		extractionResultRemote:FireClient(player, {
			extracted = true,
			bankedCaseUids = bankedCaseUids,
			shiftPay = pay,
			extractionCount = extractionCount,
		})
	end
end

--------------------------------------------------------------------------------
-- Dock scan loop
--------------------------------------------------------------------------------

local function scan()
	local shift = getSibling("ShiftService")
	if shift == nil or type(shift.IsActive) ~= "function" or not shift.IsActive() then
		-- No session anywhere is Active — nobody can bank; drop all dwell.
		if next(dwellSeconds) ~= nil then
			table.clear(dwellSeconds)
		end
		return
	end

	local docks = getActiveDocks()
	if #docks == 0 then
		return
	end

	-- R2 (WP4.3): with the session facade live, resolve each dock's owning
	-- session once per sweep; a player may only dwell on THEIR session's dock.
	local scoped = type(shift.GetSessionOf) == "function"
	local dockSessionIds: { [BasePart]: string } = {}
	if scoped then
		for _, dock in docks do
			local sessionId = getDockSessionId(dock)
			if sessionId ~= nil then
				dockSessionIds[dock] = sessionId
			end
		end
	end

	for _, player in Players:GetPlayers() do
		local eligible = type(shift.IsParticipant) == "function" and shift.IsParticipant(player)
		if eligible and type(shift.HasExtracted) == "function" and shift.HasExtracted(player) then
			eligible = false
		end
		if eligible and type(shift.IsDowned) == "function" and shift.IsDowned(player) then
			eligible = false -- downed players must be revived (or looted) first
		end

		-- R2 (WP4.3) session scope: their own session must be Active; pin the
		-- session id + floor root the per-dock match below verifies against.
		local playerSessionId: string? = nil
		local playerFloorRoot: Instance? = nil
		if eligible and scoped then
			local okSession, session = pcall(shift.GetSessionOf, player)
			if okSession and session ~= nil and (session :: any).state == "Active" then
				local id = (session :: any).id
				if type(id) == "string" then
					playerSessionId = id
				end
				if type(shift.GetFloorRootFor) == "function" then
					local okRoot, floorRoot = pcall(shift.GetFloorRootFor, player)
					if okRoot and typeof(floorRoot) == "Instance" then
						playerFloorRoot = floorRoot
					end
				end
			else
				eligible = false
			end
		end

		local root: BasePart? = nil
		if eligible then
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			if humanoid ~= nil and humanoid.Health > 0 and rootPart ~= nil and rootPart:IsA("BasePart") then
				root = rootPart
			else
				eligible = false
			end
		end

		local inside = false
		if eligible and root ~= nil then
			for _, dock in docks do
				local belongs = not scoped
					or dockMatchesSession(dock, dockSessionIds[dock], playerSessionId, playerFloorRoot)
				if belongs and isInsideDock(dock, root.Position) then
					inside = true
					break
				end
			end
		end

		if inside then
			local dwell = (dwellSeconds[player] or 0) + SCAN_INTERVAL_SECONDS
			if dwell >= EXTRACTION_HOLD_SECONDS then
				dwellSeconds[player] = nil
				extract(player)
			else
				dwellSeconds[player] = dwell
			end
		else
			dwellSeconds[player] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function ExtractionService:Init()
	local ok, err = pcall(function()
		extractionResultRemote = Remotes.GetEvent("ExtractionResult")
	end)
	if not ok then
		warn(`[ExtractionService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		dwellSeconds[player] = nil
	end)
end

function ExtractionService:Start()
	while true do
		task.wait(SCAN_INTERVAL_SECONDS)
		local ok, err = pcall(scan)
		if not ok then
			warn(`[ExtractionService] dock scan failed: {err}`)
		end
	end
end

return ExtractionService
