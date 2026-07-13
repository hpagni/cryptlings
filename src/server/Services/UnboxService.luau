--!strict
-- CRYPTLINGS: NIGHT SHIFT — UnboxService (Stage 2 "Hub + unboxing theater";
-- SOP §1.2, §3.1 ②, §8.1; contract §E). The ONLY place Cryptlings are rolled:
-- a banked CaseStub leaves locker.cases, RarityTable.RollCryptling picks the
-- pull with a server-side Random seeded once at boot, and the reply drives the
-- client's slow-peel reveal. Rare+ pulls fan out through BroadcastService.
--
-- Remotes owned here (contract §B):
--   RequestOpenCase(caseUid) -> {ok, cryptlingId?, rarity?, isDuplicate?,
--                                opensRemaining?,
--                                err?("NO_OPENS"|"NOT_OWNED"|"BUSY"|"IN_TRADE")}
--   GetOddsTable(tier)       -> RarityTable.GetOdds(tier) verbatim — the single
--                               source for the hub odds board AND every
--                               pre-purchase disclosure (§8.1: they must match).
--
-- Stage 3: the daily-cap gate at the single sanctioned "-- LOCKER_GATE" call
-- site is wired to LockerService.TryConsumeOpen (contract §I). Fail-closed: if
-- LockerService is missing/broken the gate line errors into onRequestOpenCase's
-- pcall and the open is refused (transient "BUSY") — nothing is consumed.
-- opensRemaining in the reply is the LockerService total (free opens left +
-- extra-open credits) AFTER this open was consumed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

--------------------------------------------------------------------------------
-- Server RNG — Random.new() seeded once at boot from OS entropy. ALL rolls are
-- server-side and flow through this instance (contract §E).
--------------------------------------------------------------------------------

local serverRng = Random.new()

local function rollRng(): number
	return serverRng:NextNumber()
end

-- Rare+ set: pulls that bump stats.rarePulls and trigger the broadcast (§3.1).
local RARE_PLUS: { [string]: boolean } = {
	Rare = true,
	Epic = true,
	Legendary = true,
	Godly = true,
	Mythical = true,
}

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades that feature, never the unbox itself)
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
-- Service state
--------------------------------------------------------------------------------

type OpenResult = {
	ok: boolean,
	cryptlingId: string?,
	rarity: string?,
	isDuplicate: boolean?,
	opensRemaining: number?,
	err: string?,
}

type RollOutcome = {
	cryptlingId: string,
	rarity: string,
	isDuplicate: boolean,
	firstOpen: boolean,
	rarePlus: boolean,
}

local UnboxService = {}

-- Per-player mid-open flag: one slow-peel at a time (spec: "BUSY").
local busy: { [Player]: boolean } = {}

--------------------------------------------------------------------------------
-- Open flow
--------------------------------------------------------------------------------

-- "First-ever open" for CoreLoop funnel step 4: the collection holds nothing
-- that came out of a case. Non-pool grants (the Starter Pack's misprint_trophy)
-- are ignored so buying the pack early can't swallow the first_unboxing step.
local function hasUnboxedBefore(collection: { [string]: number }): boolean
	for cryptlingId in collection do
		local def = RarityTable.GetCryptling(cryptlingId)
		if def == nil or def.notInPool ~= true then
			return true
		end
	end
	return false
end

-- The guarded body: caller holds busy[player]. May yield (Update lock,
-- analytics); errors are caught by the pcall in onRequestOpenCase.
local function performOpen(player: Player, dataService: any, caseUid: string): OpenResult
	-- LOCKER_GATE (Stage 3: rewired to LockerService.TryConsumeOpen — contract §I sanctioned edit #1)
	local gateOk: boolean, opensRemaining: number, openSource: string? =
		getSibling("LockerService").TryConsumeOpen(player)
	if not gateOk then
		-- locker_cap_hit is tracked by TryConsumeOpen itself (contract §I) —
		-- tracking it here too would double-count the §H return-lever metric.
		return { ok = false, err = "NO_OPENS", opensRemaining = opensRemaining }
	end

	local outcome: RollOutcome? = nil
	local updated = dataService.Update(player, function(data: Types.ProfileData)
		-- Re-find under the write lock: a parallel writer (trade, Stage 4+)
		-- could have taken this uid between validation and here.
		local index: number? = nil
		for i, stub in data.locker.cases do
			if stub.uid == caseUid then
				index = i
				break
			end
		end
		if index == nil then
			return
		end
		local stub = data.locker.cases[index]

		-- Roll BEFORE mutating so a bad stub (invalid tier asserts inside
		-- RarityTable) leaves the locker untouched. A mega crate skips the odds
		-- and GUARANTEES a Mythical (the disclosed mega-crate contract).
		local cryptlingId: string
		-- R7 (Fix #4): guaranteed-rarity starter case. Forces a uniform pick from
		-- the named rarity pool (byte-identical to the mega-Mythical guarantee
		-- below) WITHOUT the mega grab-lock. Checked BEFORE mega; normal cases
		-- never set guaranteedRarity, so TIER_WEIGHTS / disclosed odds are untouched.
		local forced = stub.guaranteedRarity
		if type(forced) == "string" and RarityTable.GetPoolByRarity(forced)[1] ~= nil then
			local pool = RarityTable.GetPoolByRarity(forced)
			local pick = math.clamp(math.floor(rollRng() * #pool) + 1, 1, #pool)
			cryptlingId = pool[pick].id
		elseif stub.mega == true then
			local pool = RarityTable.GetPoolByRarity("Mythical")
			if #pool > 0 then
				local pick = math.clamp(math.floor(rollRng() * #pool) + 1, 1, #pool)
				cryptlingId = pool[pick].id
			else
				cryptlingId = RarityTable.RollCryptling(stub.tier, rollRng)
			end
		else
			cryptlingId = RarityTable.RollCryptling(stub.tier, rollRng)
		end
		local def = RarityTable.GetCryptling(cryptlingId)
		local firstOpen = not hasUnboxedBefore(data.collection)

		table.remove(data.locker.cases, index) -- removes exactly this uid
		local count = (data.collection[cryptlingId] or 0) + 1
		data.collection[cryptlingId] = count

		local rarePlus = RARE_PLUS[def.rarity] == true
		if rarePlus then
			data.stats.rarePulls += 1
		end

		outcome = {
			cryptlingId = cryptlingId,
			rarity = def.rarity,
			isDuplicate = count > 1, -- count AFTER increment (spec)
			firstOpen = firstOpen,
			rarePlus = rarePlus,
		}
	end) == true

	if not updated or outcome == nil then
		-- Profile dropped or the uid raced away mid-flight (traded/removed after
		-- validation). Nothing was rolled, so REFUND the open the gate consumed —
		-- otherwise a race burns a (potentially Robux-bought) open credit. The
		-- refund restores the SAME pool the gate drew from: a never-expiring
		-- credit must not come back as a windowed free open.
		dataService.Update(player, function(data: Types.ProfileData)
			if openSource == "credit" then
				data.locker.extraOpenCredits += 1
			elseif data.locker.freeOpensUsed > 0 then
				data.locker.freeOpensUsed -= 1
			end
		end)
		local locker = getSibling("LockerService")
		if locker ~= nil and type(locker.NotifyLockerChanged) == "function" then
			task.spawn(function()
				pcall(locker.NotifyLockerChanged, player)
			end)
		end
		return { ok = false, err = "NOT_OWNED" }
	end
	local result = outcome :: RollOutcome

	track(player, "unbox", {
		rarity = result.rarity,
		cryptlingId = result.cryptlingId,
		duplicate = result.isDuplicate,
	})
	if result.firstOpen then
		funnelStep(player, 4, "first_unboxing") -- CoreLoop step 4 (§3.4)
	end
	if result.rarePlus then
		track(player, "rare_pull", { rarity = result.rarity })
		local broadcast = getSibling("BroadcastService")
		if broadcast ~= nil and type(broadcast.Announce) == "function" then
			pcall(broadcast.Announce, player.DisplayName, result.cryptlingId, result.rarity)
		end
	end

	return {
		ok = true,
		cryptlingId = result.cryptlingId,
		rarity = result.rarity,
		isDuplicate = result.isDuplicate,
		opensRemaining = opensRemaining,
	}
end

local function onRequestOpenCase(player: Player, caseUid: any): OpenResult
	-- Validation order per spec: profile loaded -> uid owned -> not mid-open.
	if type(caseUid) ~= "string" or caseUid == "" then
		return { ok = false, err = "NOT_OWNED" }
	end

	local dataService = getSibling("PlayerDataService")
	if
		dataService == nil
		or type(dataService.IsLoaded) ~= "function"
		or type(dataService.Get) ~= "function"
		or type(dataService.Update) ~= "function"
		or not dataService.IsLoaded(player)
	then
		return { ok = false, err = "NOT_OWNED" }
	end

	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return { ok = false, err = "NOT_OWNED" }
	end
	local owned = false
	for _, stub in data.locker.cases do
		if stub.uid == caseUid then
			owned = true
			break
		end
	end
	if not owned then
		return { ok = false, err = "NOT_OWNED" }
	end

	-- Stage 4 UX courtesy: a case sitting in the player's live trade offer is
	-- not openable (TradeService.IsItemLocked — advisory; the trade's
	-- execute-time revalidation stays the hard dupe guarantee either way).
	local tradeService = getSibling("TradeService")
	if tradeService ~= nil and type(tradeService.IsItemLocked) == "function" then
		local okLock, locked = pcall(tradeService.IsItemLocked, player, caseUid)
		if okLock and locked == true then
			return { ok = false, err = "IN_TRADE" }
		end
	end

	-- §4.1 "Never" list: no pay-to-open mid-run. The shop/locker UIs already
	-- hide during a run, but the SERVER is the gate of record — an exploit
	-- client must not be able to open banked cases (or burn purchased
	-- extra-open credits) while it is an active, un-extracted shift
	-- participant. "BUSY" keeps the OpenResult err enum stable (transient: the
	-- open is available again at clock-out; nothing was consumed).
	local shiftService = getSibling("ShiftService")
	if shiftService ~= nil and type(shiftService.IsActive) == "function" then
		local okShift, midRun = pcall(function()
			return shiftService.IsActive()
				and type(shiftService.IsParticipant) == "function"
				and shiftService.IsParticipant(player)
				and not (type(shiftService.HasExtracted) == "function" and shiftService.HasExtracted(player))
		end)
		if okShift and midRun == true then
			return { ok = false, err = "BUSY" }
		end
	end

	if busy[player] then
		return { ok = false, err = "BUSY" }
	end
	busy[player] = true
	local ok, result = pcall(performOpen, player, dataService, caseUid)
	busy[player] = nil

	if not ok then
		warn(`[UnboxService] open failed for {player.Name} ({caseUid}): {result}`)
		return { ok = false, err = "BUSY" } -- transient: nothing was consumed, retry
	end
	return result :: OpenResult
end

--------------------------------------------------------------------------------
-- Odds disclosure (§8.1)
--------------------------------------------------------------------------------

-- Returns RarityTable.GetOdds(tier) VERBATIM — the exact integer-weight-derived
-- percentages. Garbage input falls back to the disclosed baseline tier (2);
-- every real tier in RarityTable.TIER_WEIGHTS (1..6) is disclosed as itself.
local function onGetOddsTable(_player: Player, tier: any): { { rarity: string, pct: number } }
	if type(tier) ~= "number" or RarityTable.TIER_WEIGHTS[tier] == nil then
		tier = RarityTable.BASELINE_TIER
	end
	return RarityTable.GetOdds(tier)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function UnboxService:Init()
	-- Remotes already exist (init.server runs Remotes.InitServer() first).
	local ok, err = pcall(function()
		Remotes.GetFunction("RequestOpenCase").OnServerInvoke = function(player: Player, caseUid: any)
			return onRequestOpenCase(player, caseUid)
		end
		Remotes.GetFunction("GetOddsTable").OnServerInvoke = onGetOddsTable
	end)
	if not ok then
		warn(`[UnboxService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		busy[player] = nil
	end)
end

return UnboxService
