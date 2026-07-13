--!strict
-- CRYPTLINGS: NIGHT SHIFT — LockerService (Stage 3 "Locker + 3-free-opens/day";
-- SOP §3.1 ③, §1.2, §3.3, §5.3; contracts §C, §D, §G, §I).
--
-- The 24-48h return-habit engine: players bank unlimited sealed cases in
-- profile.locker.cases but may OPEN only FREE_OPENS_PER_DAY (3) per unix day
-- (00:00 UTC), or VIP_OPENS_PER_DAY (6) with the PASS_VIP_LOCKER game pass.
-- Pure logic over profile.locker (contract §D) — banked cases are written
-- directly by ExtractionService/MonetizationService; this service never owns
-- the field, only mutates it through PlayerDataService.Update.
--
-- Public API (contract §I — later stages call these):
--   LockerService.TryConsumeOpen(player) -> (ok: boolean, opensRemaining: number,
--                                            source: ("free"|"credit")?)
--       EnsureDailyReset first; consumes freeOpensUsed before extraOpenCredits;
--       opensRemaining = freeLeft + credits; source names the pool the open
--       came from (nil when nothing was consumed) so a race refund can restore
--       the SAME pool. On cap block -> locker_cap_hit.
--       Sole caller in MVP: UnboxService's sanctioned "-- LOCKER_GATE" site.
--   LockerService.AddCases(player, {Types.CaseStub}) -> boolean
--       Appends sealed stubs to locker.cases (Stage 6 bundles / starter pack).
--   LockerService.GrantExtraOpens(player, n) -> boolean
--       +n extraOpenCredits (EXTRA_OPENING product, friend-invite reward).
--   LockerService.GetLockerState(player) -> Types.LockerState
--       Snapshot incl. nextResetAt = (lastResetDay + 1) * LOCKER_RESET_WINDOW_SECONDS.
--       Also serves the GetLockerState remote (contract §B).
--   LockerService.NotifyLockerChanged(player)
--       Pushes a fresh LockerChanged snapshot; for services that write
--       profile.locker.cases directly by contract (ExtractionService banking).
--
-- Pushes the LockerChanged remote (owner-only) after any mutation and when the
-- unix-day boundary flips while a player is online (per-minute poll).
--
-- Friend-invite reward (SOP §3.2 co-play hook): when a joining player's
-- GetJoinData().ReferredByPlayerId names an ONLINE inviter, the inviter earns
-- FRIEND_INVITE_REWARD_OPENS extra open credits — once per distinct invited
-- friend, at most FRIEND_INVITE_MAX_REWARDED (5) friends ever, recorded
-- idempotently in social.invitesRewarded BEFORE the grant.
--
-- Test hooks (Stage 4 Locker.spec only — never call from production code):
--   LockerService.SetLastResetDayForTest(player, unixDay) -> boolean
--   LockerService.SetVipForTest(player, owns: boolean?)  -- nil clears override

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LockerCore = require(Shared:WaitForChild("Logic"):WaitForChild("LockerCore"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

-- Tuning constants live in GameConstants (§G no-magic-numbers):
--   LOCKER_FLIP_POLL_SECONDS    — daily-flip poll cadence for online players
--   INVITER_LOAD_TIMEOUT_SECONDS — invite-reward wait for the inviter's profile
-- Poll cadence while waiting on the inviter's profile (sub-tunable of the
-- timeout above; nothing else reads it).
local INVITER_LOAD_POLL_SECONDS = 1

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades that feature, never the locker math). MonetizationService is a
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

-- PlayerDataService with the full surface this service relies on, or nil.
local function getDataService(): any
	local dataService = getSibling("PlayerDataService")
	if
		dataService ~= nil
		and type(dataService.Get) == "function"
		and type(dataService.IsLoaded) == "function"
		and type(dataService.Update) == "function"
		and type(dataService.EnsureDailyReset) == "function"
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

local LockerService = {}

-- Test-only VIP override (SetVipForTest). nil = ask MonetizationService.
local vipOverride: { [Player]: boolean } = {}

-- Safe pcall'd pass lookup, defaulting false (contract §I pattern). May yield
-- on a cold cache once MonetizationService ships — never call inside Update.
local function ownsVipPass(player: Player): boolean
	local override = vipOverride[player]
	if override ~= nil then
		return override
	end
	local monetization = getSibling("MonetizationService")
	if monetization ~= nil and type(monetization.OwnsPass) == "function" then
		local ok, owns = pcall(monetization.OwnsPass, player, "PASS_VIP_LOCKER")
		if ok and owns == true then
			return true
		end
	end
	return false
end

local function opensPerDayFor(player: Player): number
	return LockerCore.OpensPerDay(ownsVipPass(player))
end

-- Snapshot of profile.locker as the wire type (contract §C). The cases array
-- is cloned so callers can never mutate saved state outside Update.
local function buildLockerState(data: Types.ProfileData, perDay: number): Types.LockerState
	return {
		cases = table.clone(data.locker.cases),
		freeOpensRemaining = math.max(0, perDay - data.locker.freeOpensUsed),
		extraOpenCredits = data.locker.extraOpenCredits,
		opensPerDay = perDay,
		nextResetAt = LockerCore.NextResetAt(data.locker.lastResetDay),
	}
end

-- Zeroed state for a player whose profile is not (yet) session-locked: no
-- opens, no cases, honest clock. The locker UI treats this as "loading".
local function emptyLockerState(perDay: number): Types.LockerState
	return {
		cases = {},
		freeOpensRemaining = 0,
		extraOpenCredits = 0,
		opensPerDay = perDay,
		-- Honest clock on the SAME window math as real snapshots (LOCKER_RESET_WINDOW_SECONDS,
		-- not the unix-day boundary).
		nextResetAt = LockerCore.NextResetAt(LockerCore.WindowIndex(os.time())),
	}
end

-- Fires LockerChanged (owner-only, contract §B) with a fresh snapshot.
local function pushLockerState(player: Player)
	local dataService = getDataService()
	if dataService == nil or player.Parent == nil then
		return
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return
	end
	local state = buildLockerState(data, opensPerDayFor(player))
	local ok, err = pcall(function()
		Remotes.GetEvent("LockerChanged"):FireClient(player, state)
	end)
	if not ok then
		warn(`[LockerService] LockerChanged push failed for {player.Name}: {err}`)
	end
end

--------------------------------------------------------------------------------
-- TryConsumeOpen — contract §I; the UnboxService LOCKER_GATE lands here
--------------------------------------------------------------------------------

-- Attempts to consume one opening: daily reset first, then free opens, then
-- extra credits. Returns (ok, opensRemaining = freeLeft + credits, source)
-- where opensRemaining reflects the state AFTER any consumption and source
-- ("free"|"credit") names the pool consumed so a refund can restore the same
-- pool (never-expiring credits must not turn into windowed free opens).
function LockerService.TryConsumeOpen(player: Player): (boolean, number, string?)
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return false, 0, nil
	end

	-- Pass lookup can yield; resolve before entering the no-yield Update fn.
	local perDay = opensPerDayFor(player)

	local consumed = false
	local remaining = 0
	local source: string? = nil
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		-- LockerCore: window reset first, then free opens, then purchased
		-- extraOpenCredits (pure, lune-tested). Credits are untouched by the
		-- window reset, so a credit delta is the reliable pool tell.
		local creditsBefore = data.locker.extraOpenCredits
		consumed, remaining = LockerCore.ConsumeOpen(data.locker, perDay, LockerCore.WindowIndex(os.time()))
		if consumed then
			source = if data.locker.extraOpenCredits < creditsBefore then "credit" else "free"
		end
	end) == true

	if not updated then
		return false, 0, nil
	end
	if not consumed then
		track(player, "locker_cap_hit") -- §H: the 24-48h return-lever metric
		return false, remaining, nil
	end

	-- Deferred so the caller's own follow-up mutation (UnboxService removes the
	-- opened case right after the gate, synchronously in the common path) is
	-- already reflected in the pushed snapshot. Worst case under lock
	-- contention the snapshot is one open stale; counts are always correct.
	task.defer(pushLockerState, player)
	return true, remaining, source
end

--------------------------------------------------------------------------------
-- AddCases / GrantExtraOpens — contract §I (Stage 6 bundles, starter pack,
-- EXTRA_OPENING product, friend-invite reward)
--------------------------------------------------------------------------------

local VALID_SOURCES: { [string]: boolean } = { run = true, bundle = true, key = true, code = true }

local function isValidStub(stub: any): boolean
	return type(stub) == "table"
		and type(stub.uid) == "string"
		and stub.uid ~= ""
		and (type(stub.tier) == "number" and stub.tier % 1 == 0 and stub.tier >= 1 and stub.tier <= 6) -- 6 = rainbow box
		and type(stub.lineId) == "string"
		and type(stub.acquiredAt) == "number"
		and VALID_SOURCES[stub.source] == true
end

-- Appends sealed CaseStubs to the player's locker. Malformed stubs are skipped
-- with a warning (economy writes never half-trust their input). Returns true
-- when at least one stub landed.
function LockerService.AddCases(player: Player, stubs: { Types.CaseStub }): boolean
	if type(stubs) ~= "table" or #stubs == 0 then
		return false
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return false
	end

	local added = 0
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		for index, stub in stubs do
			if isValidStub(stub) then
				table.insert(data.locker.cases, stub)
				added += 1
			else
				warn(`[LockerService] AddCases for {player.Name}: skipping malformed stub #{index}`)
			end
		end
	end) == true

	if not updated or added == 0 then
		return false
	end
	pushLockerState(player)
	return true
end

-- Grants n extra open credits (n must be a positive integer). Credits never
-- expire and are consumed only after the day's free opens run dry.
function LockerService.GrantExtraOpens(player: Player, n: number): boolean
	if type(n) ~= "number" or n <= 0 or n % 1 ~= 0 then
		return false
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return false
	end

	local updated = dataService.Update(player, function(data: Types.ProfileData)
		data.locker.extraOpenCredits += n
	end) == true

	if not updated then
		return false
	end
	pushLockerState(player)
	return true
end

-- OPENS_RESET product: immediately refills the window's free-open allowance
-- (extraOpenCredits untouched — they never expire). Returns true on success.
function LockerService.ResetOpenAllowance(player: Player): boolean
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return false
	end

	local updated = dataService.Update(player, function(data: Types.ProfileData)
		LockerCore.ResetAllowance(data.locker, LockerCore.WindowIndex(os.time()))
	end) == true

	if not updated then
		return false
	end
	pushLockerState(player)
	return true
end

-- Pushes a fresh owner-only LockerChanged snapshot. Public for the services
-- that write profile.locker.cases directly by contract (ExtractionService's
-- run banking) so freshly banked cases surface on the live stream instead of
-- waiting for the client's refetch fallback. May yield (pass lookup) — callers
-- should task.spawn/defer it off hot paths.
function LockerService.NotifyLockerChanged(player: Player)
	pushLockerState(player)
end

--------------------------------------------------------------------------------
-- GetLockerState — public API + the GetLockerState remote (contract §B)
--------------------------------------------------------------------------------

function LockerService.GetLockerState(player: Player): Types.LockerState
	local perDay = opensPerDayFor(player)
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return emptyLockerState(perDay)
	end

	-- Apply a pending daily flip under the write lock so the snapshot (and the
	-- locker UI reading it) can never show yesterday's spent opens.
	local flipped = false
	local state: Types.LockerState? = nil
	dataService.Update(player, function(data: Types.ProfileData)
		flipped = dataService.EnsureDailyReset(data) == true
		state = buildLockerState(data, perDay)
	end)
	if state == nil then
		return emptyLockerState(perDay)
	end
	if flipped then
		pushLockerState(player) -- a reset is a mutation: push as well as reply
	end
	return state :: Types.LockerState
end

--------------------------------------------------------------------------------
-- Daily flip poll — per-minute check so players online across 00:00 UTC see
-- their free opens come back without rejoining (SOP §3.1 ③)
--------------------------------------------------------------------------------

local function applyDailyFlipIfDue(player: Player)
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return
	end
	-- Cheap read-only probe before taking the write lock every minute.
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil or data.locker.lastResetDay >= LockerCore.WindowIndex(os.time()) then
		return
	end

	local flipped = false
	dataService.Update(player, function(liveData: Types.ProfileData)
		flipped = dataService.EnsureDailyReset(liveData) == true
	end)
	if flipped then
		pushLockerState(player)
	end
end

--------------------------------------------------------------------------------
-- Friend-invite reward (SOP §3.2; contract §G FRIEND_INVITE_*)
--------------------------------------------------------------------------------

local function tryRewardInviter(invited: Player)
	local ok, joinData = pcall(function()
		return invited:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return
	end

	local referrerId = tonumber((joinData :: any).ReferredByPlayerId)
	if referrerId == nil or referrerId <= 0 or referrerId == invited.UserId then
		return -- no referral, or self-referral
	end
	local inviter = Players:GetPlayerByUserId(referrerId)
	if inviter == nil then
		return -- reward only when the inviter is online in this server (§3.2)
	end

	local dataService = getDataService()
	if dataService == nil then
		return
	end
	-- The inviter joined earlier, so their profile is almost always locked by
	-- now; tolerate a brief load race, then give up quietly.
	local deadline = os.clock() + GameConstants.INVITER_LOAD_TIMEOUT_SECONDS
	while not dataService.IsLoaded(inviter) do
		if os.clock() >= deadline or inviter.Parent == nil then
			return
		end
		task.wait(INVITER_LOAD_POLL_SECONDS)
	end

	-- Idempotent record FIRST: a crash between record and grant loses one
	-- credit at worst — never duplicates one. One reward per distinct invited
	-- friend, FRIEND_INVITE_MAX_REWARDED (5) friends per inviter, ever.
	local invitedKey = tostring(invited.UserId)
	local recorded = false
	dataService.Update(inviter, function(data: Types.ProfileData)
		local rewarded = data.social.invitesRewarded
		if rewarded[invitedKey] == true then
			return
		end
		if Util.Count(rewarded) >= GameConstants.FRIEND_INVITE_MAX_REWARDED then
			return
		end
		rewarded[invitedKey] = true
		recorded = true
	end)

	if recorded then
		LockerService.GrantExtraOpens(inviter, GameConstants.FRIEND_INVITE_REWARD_OPENS)
	end
end

--------------------------------------------------------------------------------
-- Test hooks (Stage 4 Locker.spec — contract acceptance: simulated day flip)
--------------------------------------------------------------------------------

-- Backdates (or forward-dates) locker.lastResetDay so the next EnsureDailyReset
-- treats the day as flipped and restores the free-open allowance.
function LockerService.SetLastResetDayForTest(player: Player, unixDay: number): boolean
	if type(unixDay) ~= "number" then
		return false
	end
	local dataService = getDataService()
	if dataService == nil or not dataService.IsLoaded(player) then
		return false
	end
	return dataService.Update(player, function(data: Types.ProfileData)
		data.locker.lastResetDay = unixDay
	end) == true
end

-- Forces (true/false) or clears (nil) the VIP-pass answer for one player so
-- specs can assert the 6-opens path without MarketplaceService.
function LockerService.SetVipForTest(player: Player, owns: boolean?)
	if owns == nil then
		vipOverride[player] = nil
	else
		vipOverride[player] = owns
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function LockerService:Init()
	-- Remotes already exist (init.server runs Remotes.InitServer() first).
	local ok, err = pcall(function()
		Remotes.GetFunction("GetLockerState").OnServerInvoke = function(player: Player)
			return LockerService.GetLockerState(player)
		end
	end)
	if not ok then
		warn(`[LockerService] remote bind failed: {err}`)
	end
end

function LockerService:Start()
	-- Friend-invite rewards: every join inspects its referral payload. Spawned
	-- so the brief inviter-profile wait never blocks other PlayerAdded work.
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(tryRewardInviter, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(tryRewardInviter, player) -- joins that beat service start
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		vipOverride[player] = nil
	end)

	-- Per-minute daily-flip poll for online players.
	task.spawn(function()
		while true do
			task.wait(GameConstants.LOCKER_FLIP_POLL_SECONDS)
			for _, player in Players:GetPlayers() do
				task.spawn(applyDailyFlipIfDue, player)
			end
		end
	end)
end

return LockerService
