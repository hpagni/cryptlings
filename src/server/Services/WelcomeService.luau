--!strict
-- CRYPTLINGS: NIGHT SHIFT — WelcomeService (R7 Fix #1 + Fix #4, server lane A).
-- Drives the unified FIRST-EVER flow, ONCE EVER per account, SEPARATE from the
-- in-shift OnboardingBeat (OnboardingService owns stats.firstShiftDone; this owns
-- profile.onboarding). The two coexist and never break each other.
--
-- On profile load, if WelcomeGate.shouldShow(onboarding, stats) is true:
--   (1) grant ONE guaranteed-Rare starter case so it is waiting in the locker
--       (idempotent via onboarding.starterCaseGranted),
--   (2) set onboarding.welcomeShown = true,
--   (3) FireClient ShowWelcome (empty payload) — the client shows the kid-friendly
--       welcome panel and then runs the StarterGuide step machine.
--
-- AT-MOST-ONCE across rejoin/crash: every flag is PERSISTED (via
-- PlayerDataService.Update) BEFORE ShowWelcome is fired, and the starter-case
-- grant is claimed atomically inside an Update before the case is inserted, so a
-- rejoin-before-open never double-grants. No server completion remote is required:
-- grant-once + welcomeShown is the gate.
--
-- Lifecycle (matches OnboardingService): poll loaded profiles each tick; a
-- per-session `settled` set stops re-scanning a player once handled, and is
-- cleared on PlayerRemoving.
--
-- Optional siblings consumed via pcall (degrade gracefully when absent):
--   PlayerDataService.Get/IsLoaded/Update/WithLock
--   LockerService.AddCases

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local WelcomeGate = require(Shared:WaitForChild("Logic"):WaitForChild("WelcomeGate"))

local SCAN_INTERVAL_SECONDS = 1
local STARTER_CASE_TIER = 3 -- mid-tier stub (matches the foundation contract)
local STARTER_GUARANTEED_RARITY = "Rare" -- 5 in-pool members; never mega

--------------------------------------------------------------------------------
-- Lazy sibling resolution (pcall-require; a missing module degrades the feature,
-- never the boot — house pattern shared with the other services).
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

local WelcomeService = {}

-- Players already handled this server (shown or determined to never show). Stops
-- the scan loop from re-reading their profile. Cleared on PlayerRemoving.
local settled: { [Player]: boolean } = {}

local showWelcomeRemote: RemoteEvent? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Builds the guaranteed-Rare starter CaseStub (mirrors MonetizationService's
-- buildBundleStubs: source = "bundle" is valid per LockerService.VALID_SOURCES).
-- Sets guaranteedRarity = "Rare" instead of mega, so UnboxService forces a Rare
-- WITHOUT the mega grab-lock and the disclosed odds stay untouched.
local function buildStarterStub(): Types.CaseStub
	return {
		uid = HttpService:GenerateGUID(false),
		tier = STARTER_CASE_TIER,
		lineId = RarityTable.LINE_ID,
		acquiredAt = os.time(),
		source = "bundle" :: Types.CaseSource,
		guaranteedRarity = STARTER_GUARANTEED_RARITY,
	}
end

-- The full once-ever sequence under the player's WithLock mutex so a concurrent
-- rejoin/handler can never interleave. Persists every flag BEFORE returning;
-- ShowWelcome is fired by the caller only after this returns show == true.
-- Returns (handled, show): `handled` true means this player is settled forever
-- this server (veteran or panel persisted); `show` true means fire ShowWelcome.
local function runOnce(player: Player, dataService: any): (boolean, boolean)
	local handled = false
	local show = false
	local okLock = dataService.WithLock(player, function()
		local data = dataService.Get(player) :: Types.ProfileData?
		if data == nil then
			return -- profile dropped mid-flight; try again next tick (not settled)
		end
		if not WelcomeGate.shouldShow(data.onboarding, data.stats) then
			-- Settle ONLY if the player is genuinely past the welcome. A brand-new
			-- player still INSIDE the intro floor has shouldShow == false (because
			-- introFloorDone is still false) — settling them here would mean the
			-- panel never fires once the intro completes. shouldEnterIntro is true
			-- exactly for that "still owes the intro" case, so don't settle then.
			handled = not WelcomeGate.shouldEnterIntro(data.onboarding, data.stats)
			return
		end

		-- (1) Grant the starter case FIRST so it is waiting in the locker. Claim
		-- the grant atomically inside Update (set starterCaseGranted) so a crash
		-- mid-flight cannot double-grant on rejoin; only a freshly-claimed grant
		-- inserts a case.
		-- SKIP the grant when the intro already banked boxes for this player
		-- (introBoxesBanked == true): the earned intro boxes substitute for the
		-- starter case. The panel + StarterGuide still run normally below. When
		-- introBoxesBanked is false (graceful-failure fallthrough or intro
		-- disabled) keep the original grant behavior exactly.
		if data.onboarding.introBoxesBanked ~= true and data.onboarding.starterCaseGranted == false then
			local claimed = dataService.Update(player, function(d: Types.ProfileData)
				d.onboarding.starterCaseGranted = true
			end) == true
			if claimed then
				local locker = getSibling("LockerService")
				if locker ~= nil and type(locker.AddCases) == "function" then
					pcall(locker.AddCases, player, { buildStarterStub() })
				end
			end
		end

		-- (2) Mark the panel shown (persisted) BEFORE the client is told.
		local marked = dataService.Update(player, function(d: Types.ProfileData)
			d.onboarding.welcomeShown = true
		end) == true
		if marked then
			handled = true
			show = true
		end
	end)

	if not okLock then
		return false, false
	end
	return handled, show
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function WelcomeService:Init()
	local ok, err = pcall(function()
		showWelcomeRemote = Remotes.GetEvent("ShowWelcome")
	end)
	if not ok then
		warn(`[WelcomeService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		settled[player] = nil
	end)
end

function WelcomeService:Start()
	while true do
		task.wait(SCAN_INTERVAL_SECONDS)
		local dataService = getSibling("PlayerDataService")
		if dataService == nil or type(dataService.IsLoaded) ~= "function" then
			continue
		end
		for _, player in Players:GetPlayers() do
			if settled[player] == true then
				continue
			end
			if not dataService.IsLoaded(player) then
				continue -- profile still loading; try next tick
			end

			-- runOnce persists every flag before returning; `show` is true exactly
			-- once, when the panel should be shown now. `handled` means the
			-- in-profile flags are settled (veteran or panel persisted) so the
			-- scan loop never re-reads this player. A dropped/raced profile leaves
			-- both false so we retry next tick.
			local handled, show = runOnce(player, dataService)
			if handled then
				settled[player] = true
			end

			if show and showWelcomeRemote ~= nil and player:IsDescendantOf(Players) then
				-- Empty payload (forward-compat); owner-only FireClient.
				pcall(function()
					(showWelcomeRemote :: RemoteEvent):FireClient(player)
				end)
			end
		end
	end
end

return WelcomeService
