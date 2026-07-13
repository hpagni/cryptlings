--!strict
-- CRYPTLINGS: NIGHT SHIFT — TradeService (Stage 4 "Swap-meet trading";
-- SOP §3.1 ④, §3.3, §8.1, §8.2). Scam-resistant, Robux-free duplicate trading
-- at the hub swap meet. Session FSM keyed by a tradeId GUID:
--
--   Invite (both in hub, neither in an active trade, target <=30 studs or both
--   on TradePads; rate limit 1 active trade + 5 invites/min)
--     -> Negotiating (SetOffer replaces that side's offer; ANY change resets
--        BOTH confirm stages to 0 and fires TradeEvent "Updated")
--     -> Confirm stage 1 (both) -> server stamps confirmReady; stage 2 accepted
--        only >=3s later (confirm-twice, §3.3)
--     -> both stage 2: EXECUTE atomically (see below) -> Completed
--   Leave / death / disconnect / shift-start -> auto-Cancel.
--
-- Dupe defenses (§8.2 pre-launch blocker — "no dupe-prone trade code"):
--   * Single write path: TakeOfferFromData / GrantToData are the only functions
--     that move traded items, always inside PlayerDataService.Update.
--   * Execute holds PlayerDataService.WithLock on BOTH players, acquired in
--     ascending-userId order (no deadlock), then REVALIDATES every offered item
--     inside each player's Update write lock (re-check uids + counts); any miss
--     cancels the trade with "ITEMS_CHANGED" and restores anything taken.
--   * uid-keyed case removal; duplicate uids inside one offer are rejected at
--     sanitize time (double-spend attempt).
--   * In-memory lockedItems view: TradeService.IsItemLocked(player, ref)
--     reports whether a case uid / cryptling id is in the player's live offer.
--     Nothing consults it yet — execute-time revalidation is the hard
--     guarantee; the lock is a UX courtesy for future UnboxService/ShelfService
--     wiring.
--
-- valueWarning is computed SERVER-side: each side's offered caseUids resolve to
-- tiers from the live profile, ValueIndex.OfferValue prices both sides, and
-- ValueIndex.IsLopsided(valueA, valueB) decides the verdict (module absent or
-- broken => false; never blocks trading). Every TradeState push also carries
-- the additive extensions TradeUI consumes: caseTiers {[uid]:tier} (partner
-- sealed cases render with tier colors), values {[userIdStr]:number} (meters),
-- and valueWarningFor (the userIdStr the warning is AGAINST). Completed trades
-- log valueWarning server-side for the §5.4 weekly scam review. Full both-side
-- item lists go to TradeLedger (DataStore "TradeLedger_v1") for rollback (§3.3).
--
-- Swap-meet beacon state (Lobby SOP Addendum 1, Change 5): TradeService
-- maintains liveSessionCount over non-test sessions — a session counts from
-- its Invited→Negotiating activation until Completed/Cancelled (every terminal
-- path, including disconnect via PlayerRemoving -> cancelFor -> cancelSession,
-- funnels through closeSession). On 0↔1+ transitions the boolean Attribute
-- `TradeActive` is stamped on every HubService trade pad AND the swap-meet
-- beacon head; ALL tweens run client-side off GetAttributeChangedSignal
-- (TradeBeaconController) — zero server tweens here. Writes are pcall-fenced
-- and skipped when HubService is absent; isTest fixtures never touch them.
-- WP6.4 (Security Review Scope §4): the 1 Hz sweep additionally force-closes
-- any session stuck in "Executing" past EXECUTING_STUCK_TIMEOUT_SECONDS, so
-- TradeActive/liveSessionCount and the per-player active-trade index recover
-- even from a wedged execute thread.
--
-- Remotes owned here (contract §B): Trade.Invite / Trade.SetOffer /
-- Trade.Confirm / Trade.Cancel (RemoteFunctions) and the TradeEvent RemoteEvent.
-- TradeEvent payload: {kind, tradeId, state:TradeState?} plus additive optional
-- fields reason:string? (Cancelled) and stage2At:number? (unix time stage 2
-- unlocks, sent with ConfirmStage once both sides hit stage 1).
--
-- Public API:
--   TradeService.IsItemLocked(player, ref) -> boolean  -- ref = case uid or cryptlingId
--   TradeService.GetActiveTradeId(player) -> string?
--   Pure seams for TestEZ/lune economy tests (no Roblox state; implementations
--   live in Shared.Logic.TradeFlow, which lune requires directly):
--   TradeService.SanitizeOffer(raw) -> (caseUids?, cryptlings?, err?)
--   TradeService.OfferAvailable(data, caseUids, cryptlings) -> boolean
--   TradeService.TakeOfferFromData(data, caseUids, cryptlings) -> {CaseStub}?
--     (validates EVERYTHING first; mutates data + returns the removed stubs on
--      success, returns nil with data untouched on any miss)
--   TradeService.GrantToData(data, stubs, cryptlings, record?)
--   Studio-only FSM seams (TradeService.spec; inert in production):
--   CreateSessionForTest / SetOfferForTest / ConfirmForTest / CancelForTest /
--   GetSessionStateForTest / SetClockForTest

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local TradeFlow = require(Shared:WaitForChild("Logic"):WaitForChild("TradeFlow"))
local Types = require(Shared:WaitForChild("Types"))

local TradeLedger = require(script.Parent:WaitForChild("TradeLedger"))

--------------------------------------------------------------------------------
-- Tuning of record: GameConstants (§G no-magic-numbers; promoted at Stage 4
-- integration so TradeUI's mirrors read the same values). Local aliases keep
-- the FSM readable.
--------------------------------------------------------------------------------

local INVITE_RANGE_STUDS = GameConstants.TRADE_INVITE_RANGE_STUDS -- 30
local INVITE_RATE_LIMIT = GameConstants.TRADE_INVITE_RATE_LIMIT -- 5/min
local INVITE_RATE_WINDOW_SECONDS = GameConstants.TRADE_INVITE_RATE_WINDOW_SECONDS -- 60
local INVITE_EXPIRY_SECONDS = GameConstants.TRADE_INVITE_EXPIRY_SECONDS -- 30
local SESSION_IDLE_TIMEOUT_SECONDS = GameConstants.TRADE_SESSION_IDLE_TIMEOUT_SECONDS -- 300
local POLL_INTERVAL_SECONDS = 1
-- WP6.4 (Security Review Scope §4: "TradeActive cannot wedge true"): a healthy
-- execute completes in well under a second (in-memory locks + one pcall'd
-- ledger append); a session still "Executing" this long after its last
-- activity stamp is wedged (errored/hung thread) and is force-closed by the
-- sweep so liveSessionCount/TradeActive and both players' activeByUser slots
-- always recover.
local EXECUTING_STUCK_TIMEOUT_SECONDS = 60
local PAD_Y_TOLERANCE = 6 -- studs above a TradePad that still count as "on" it
local PAD_XZ_SLACK = 0.5

--------------------------------------------------------------------------------
-- Lazy sibling/shared resolution (house pattern: a missing parallel-stage
-- module degrades a check, never takes trading down with it)
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

--------------------------------------------------------------------------------
-- Session state
--------------------------------------------------------------------------------

type OfferState = TradeFlow.OfferState

type Session = {
	tradeId: string,
	phase: string, -- "Invited" | "Negotiating" | "Executing" | "Closed"
	inviterId: number,
	targetId: number,
	userIds: { number }, -- {inviterId, targetId}
	offers: { [number]: OfferState }, -- keyed by userId
	confirmReadyClock: number?, -- now() when BOTH hit stage 1
	stage2AtUnix: number?, -- unix time stage 2 unlocks (sent to clients)
	createdAt: number, -- now()
	lastActivityAt: number, -- now()
	valueWarning: boolean,
	-- ValueIndex-derived extensions pushed in every TradeState (TradeUI meters):
	caseTiers: { [string]: number }, -- {[offered caseUid]: tier}, both sides
	sideValues: { [number]: number }?, -- userId -> offer value (nil if ValueIndex absent)
	valueWarningFor: number?, -- userId the warning is AGAINST (gives more value)
	isTest: boolean?, -- CreateSessionForTest sessions skip the hub/presence sweep
	tradeActiveCounted: boolean?, -- in liveSessionCount (Change 5 beacon state)
}

type SwapOutcome = TradeFlow.SwapOutcome

type Reply = { ok: boolean, tradeId: string?, err: string? }

local TradeService = {}

local sessions: { [string]: Session } = {}
local activeByUser: { [number]: string } = {} -- userId -> tradeId (1 active trade each)
local inviteTimes: { [number]: { number } } = {} -- userId -> now() stamps (rate limit)
local characterConns: { [Player]: RBXScriptConnection } = {}
local tradeEvent: RemoteEvent? = nil

-- Monotonic clock for all session timing. SetClockForTest swaps it so the
-- TradeService.spec FSM tests can drive the 3s stage-2 window deterministically.
local clockFn: () -> number = os.clock

local function now(): number
	return clockFn()
end

-- Player-like fixtures registered by CreateSessionForTest ({UserId, Name, ...}
-- tables with PlayerDataService mock profiles). getPlayer falls back to them so
-- the whole FSM — including atomic execute — runs headless in TestEZ.
local testPlayers: { [number]: any } = {}

--------------------------------------------------------------------------------
-- Pure offer logic (the §8.2 single write path; also the TestEZ/lune seams —
-- no Roblox state, operate on plain profile-data tables). The implementations
-- live in Shared.Logic.TradeFlow (pure, lune-testable); these aliases keep the
-- documented TradeService seams stable for TradeService.spec and callers.
--------------------------------------------------------------------------------

TradeService.SanitizeOffer = TradeFlow.SanitizeOffer
TradeService.OfferAvailable = TradeFlow.OfferAvailable
TradeService.TakeOfferFromData = TradeFlow.TakeOfferFromData
TradeService.GrantToData = TradeFlow.GrantToData

--------------------------------------------------------------------------------
-- Session helpers
--------------------------------------------------------------------------------

local function getPlayer(userId: number): Player?
	local player = Players:GetPlayerByUserId(userId)
	if player ~= nil then
		return player
	end
	return testPlayers[userId] :: Player?
end

local function getRoot(player: Player?): BasePart?
	if player == nil then
		return nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

--------------------------------------------------------------------------------
-- Swap-meet beacon state (Addendum 1 Change 5 / AC-5). Server publishes state
-- only — the TradeActive boolean Attribute on the trade pads and beacon head;
-- TradeBeaconController owns every tween client-side. No Light instances, no
-- runtime create/destroy, zero remote changes.
--------------------------------------------------------------------------------

local liveSessionCount = 0 -- non-test sessions in Negotiating/Executing

-- Stamps TradeActive on every HubService.GetTradePads() pad and on the
-- HubService.GetSwapMeetBeacon() head part. GetSwapMeetBeacon is feature-
-- detected (lands with PlazaBuilder's beacon in the same wave); a missing or
-- failing HubService degrades to a no-op — never takes trading down.
local function applyTradeActiveAttribute(active: boolean)
	local hub = getSibling("HubService")
	if hub == nil then
		return
	end
	if type(hub.GetTradePads) == "function" then
		local ok, pads = pcall(hub.GetTradePads)
		if ok and type(pads) == "table" then
			for _, pad in pads :: { BasePart } do
				if typeof(pad) == "Instance" then
					pad:SetAttribute("TradeActive", active)
				end
			end
		end
	end
	if type(hub.GetSwapMeetBeacon) == "function" then
		local ok, head = pcall(hub.GetSwapMeetBeacon)
		if ok and typeof(head) == "Instance" then
			head:SetAttribute("TradeActive", active)
		end
	end
end

-- A live (non-test) session went active (Invited -> Negotiating). isTest
-- fixtures never count and never touch attributes (TradeService.spec stays
-- attribute-silent).
local function noteSessionActive(session: Session)
	if session.isTest == true or session.tradeActiveCounted == true then
		return
	end
	session.tradeActiveCounted = true
	liveSessionCount += 1
	if liveSessionCount == 1 then
		pcall(applyTradeActiveAttribute, true)
	end
end

-- Counted session reached a terminal state. Every Completed/Cancelled path —
-- executeTrade, explicit cancel, invite expiry/timeout sweeps, death, and the
-- disconnect path (PlayerRemoving -> cancelFor -> cancelSession) — funnels
-- through closeSession, so TradeActive can never wedge true.
local function noteSessionClosed(session: Session)
	if session.tradeActiveCounted ~= true then
		return
	end
	session.tradeActiveCounted = nil
	liveSessionCount = math.max(0, liveSessionCount - 1)
	if liveSessionCount == 0 then
		pcall(applyTradeActiveAttribute, false)
	end
end

-- TradeState snapshot per contract §C (players keyed by tostring(userId)) plus
-- the additive Stage-4 extensions TradeUI consumes: caseTiers (partner sealed
-- cases render with tier colors), values (per-side meters), valueWarningFor
-- (which side the §3.3 warning is against).
local function buildState(session: Session): Types.TradeState
	local players: { [string]: Types.TradeOffer } = {}
	for _, userId in session.userIds do
		local offer = session.offers[userId]
		players[tostring(userId)] = {
			offerCaseUids = table.clone(offer.caseUids),
			offerCryptlings = table.clone(offer.cryptlings),
			confirmStage = offer.confirmStage,
		}
	end
	local values: { [string]: number }? = nil
	local sideValues = session.sideValues
	if sideValues ~= nil then
		local byKey: { [string]: number } = {}
		for userId, value in sideValues do
			byKey[tostring(userId)] = value
		end
		values = byKey
	end
	return {
		tradeId = session.tradeId,
		players = players,
		valueWarning = session.valueWarning,
		caseTiers = table.clone(session.caseTiers),
		values = values,
		valueWarningFor = if session.valueWarningFor ~= nil then tostring(session.valueWarningFor) else nil,
	}
end

-- TradeEvent to both parties. reason (Cancelled) and stage2At (ConfirmStage)
-- are additive optional payload fields on top of the contract-B shape.
local function fireTradeEvent(session: Session, kind: string, reason: string?, stage2At: number?)
	local event = tradeEvent
	if event == nil then
		return
	end
	local payload = {
		kind = kind,
		tradeId = session.tradeId,
		state = buildState(session),
		reason = reason,
		stage2At = stage2At,
	}
	for _, userId in session.userIds do
		local player = getPlayer(userId)
		-- typeof guard: ForTest player-likes are plain tables with no client.
		if player ~= nil and typeof(player) == "Instance" then
			event:FireClient(player, payload)
		end
	end
end

local function closeSession(session: Session)
	session.phase = "Closed"
	noteSessionClosed(session)
	sessions[session.tradeId] = nil
	for _, userId in session.userIds do
		if activeByUser[userId] == session.tradeId then
			activeByUser[userId] = nil
		end
		if session.isTest == true then
			testPlayers[userId] = nil
		end
	end
end

local function cancelSession(session: Session, reason: string)
	if session.phase == "Closed" then
		return
	end
	closeSession(session)
	fireTradeEvent(session, "Cancelled", reason)
	for _, userId in session.userIds do
		local player = getPlayer(userId)
		if player ~= nil then
			track(player, "trade_cancelled", { reason = reason })
		end
	end
end

-- Auto-cancel hook (leave / death / disconnect; shift-start goes through the
-- poll loop). Executing sessions are left alone — the execute path's per-player
-- revalidation and Update failures handle a mid-execute departure safely.
local function cancelFor(player: Player, reason: string)
	local tradeId = activeByUser[player.UserId]
	if tradeId == nil then
		return
	end
	local session = sessions[tradeId]
	if session ~= nil and (session.phase == "Invited" or session.phase == "Negotiating") then
		cancelSession(session, reason)
	end
end

-- ANY action from the target while still "Invited" is the acceptance signal.
local function markActivity(session: Session, player: Player)
	session.lastActivityAt = now()
	if session.phase == "Invited" and player.UserId == session.targetId then
		session.phase = "Negotiating"
		noteSessionActive(session)
	end
end

local function resolveSession(player: Player, tradeId: any): (Session?, string?)
	if type(tradeId) ~= "string" or tradeId == "" then
		return nil, "NO_TRADE"
	end
	local session = sessions[tradeId]
	if session == nil or session.phase == "Closed" then
		return nil, "NO_TRADE"
	end
	if session.offers[player.UserId] == nil then
		return nil, "NOT_IN_TRADE"
	end
	if session.phase == "Executing" then
		return nil, "EXECUTING"
	end
	return session, nil
end

-- Single constructor for live (onInvite) and ForTest sessions.
local function newSession(inviterId: number, targetId: number, phase: string, isTest: boolean): Session
	local clock = now()
	local tradeId = HttpService:GenerateGUID(false)
	local session: Session = {
		tradeId = tradeId,
		phase = phase,
		inviterId = inviterId,
		targetId = targetId,
		userIds = { inviterId, targetId },
		offers = TradeFlow.NewOffers(inviterId, targetId),
		confirmReadyClock = nil,
		stage2AtUnix = nil,
		createdAt = clock,
		lastActivityAt = clock,
		valueWarning = false,
		caseTiers = {},
		sideValues = nil,
		valueWarningFor = nil,
		isTest = if isTest then true else nil,
	}
	sessions[tradeId] = session
	activeByUser[inviterId] = tradeId
	activeByUser[targetId] = tradeId
	return session
end

--------------------------------------------------------------------------------
-- Value warning (server-computed, §3.3 / §5.4)
--------------------------------------------------------------------------------

-- Resolves one side's offered caseUids to tiers from the live profile (ValueIndex
-- is pure and cannot look up uids) and records each uid's tier into outTiers —
-- the TradeState.caseTiers extension TradeUI renders partner cases from.
local function buildValueSide(
	userId: number,
	offer: OfferState,
	outTiers: { [string]: number }
): { tiers: { number }, cryptlings: { [string]: number } }
	local tiers: { number } = {}
	local tierByUid: { [string]: number } = {}
	local dataService = getSibling("PlayerDataService")
	local player = getPlayer(userId)
	if player ~= nil and dataService ~= nil and type(dataService.Get) == "function" then
		local data = dataService.Get(player) :: Types.ProfileData?
		if data ~= nil then
			for _, stub in data.locker.cases do
				tierByUid[stub.uid] = stub.tier
			end
		end
	end
	for _, uid in offer.caseUids do
		local tier = tierByUid[uid] or 1
		table.insert(tiers, tier)
		outTiers[uid] = tier
	end
	return { tiers = tiers, cryptlings = table.clone(offer.cryptlings) }
end

-- Recomputes everything ValueIndex-derived on the session: per-side values,
-- the §3.3 valueWarning verdict, which side it is against, and the uid->tier
-- map. TradeFlow.ComputeValueVerdict degrades to "no warning, no meters" on
-- any valuation failure and never blocks trading.
local function refreshValueState(session: Session)
	local caseTiers: { [string]: number } = {}
	local sideA = buildValueSide(session.userIds[1], session.offers[session.userIds[1]], caseTiers)
	local sideB = buildValueSide(session.userIds[2], session.offers[session.userIds[2]], caseTiers)
	session.caseTiers = caseTiers
	session.sideValues = nil
	session.valueWarning = false
	session.valueWarningFor = nil

	local values, warning, againstIndex = TradeFlow.ComputeValueVerdict(sideA, sideB)
	if values == nil then
		return
	end
	session.sideValues = {
		[session.userIds[1]] = values[1],
		[session.userIds[2]] = values[2],
	}
	session.valueWarning = warning
	if againstIndex ~= nil then
		-- The warning is AGAINST the side giving more value away.
		session.valueWarningFor = session.userIds[againstIndex]
	end
end

--------------------------------------------------------------------------------
-- Invite preconditions
--------------------------------------------------------------------------------

-- "In hub" = has a live character and is not a participant of the running
-- shift. ShiftService missing/broken degrades to "in hub" (house rule:
-- optional siblings never take the feature down).
local function isInHub(player: Player): boolean
	if getRoot(player) == nil then
		return false
	end
	local shift = getSibling("ShiftService")
	if shift ~= nil and type(shift.IsParticipant) == "function" then
		local ok, participating = pcall(shift.IsParticipant, player)
		if ok and participating == true then
			return false
		end
	end
	return true
end

local function isOnTradePad(root: BasePart): boolean
	local hub = getSibling("HubService")
	if hub == nil or type(hub.GetTradePads) ~= "function" then
		return false
	end
	local ok, pads = pcall(hub.GetTradePads)
	if not ok or type(pads) ~= "table" then
		return false
	end
	for _, pad in pads :: { BasePart } do
		local offset = root.Position - pad.Position
		if
			math.abs(offset.X) <= pad.Size.X / 2 + PAD_XZ_SLACK
			and math.abs(offset.Z) <= pad.Size.Z / 2 + PAD_XZ_SLACK
			and offset.Y >= -2
			and offset.Y <= PAD_Y_TOLERANCE
		then
			return true
		end
	end
	return false
end

local function withinInviteRange(inviter: Player, target: Player): boolean
	local rootA = getRoot(inviter)
	local rootB = getRoot(target)
	if rootA == nil or rootB == nil then
		return false
	end
	if (rootA.Position - rootB.Position).Magnitude <= INVITE_RANGE_STUDS then
		return true
	end
	return isOnTradePad(rootA) and isOnTradePad(rootB)
end

-- Sliding-window invite rate limit: 5 invites per 60s per player.
local function consumeInviteToken(player: Player): boolean
	local clock = now()
	local times = inviteTimes[player.UserId]
	if times == nil then
		times = {}
		inviteTimes[player.UserId] = times
	end
	for index = #times, 1, -1 do
		if clock - times[index] > INVITE_RATE_WINDOW_SECONDS then
			table.remove(times, index)
		end
	end
	if #times >= INVITE_RATE_LIMIT then
		return false
	end
	table.insert(times, clock)
	return true
end

--------------------------------------------------------------------------------
-- Atomic execute (§8.2 — the economy-critical path)
--------------------------------------------------------------------------------

-- Full ledger record: complete CaseStub lists for both sides (§3.3 "full trade
-- logging for rollback" — profile.tradeHistory only keeps uid summaries).
local function buildLedgerRecord(
	session: Session,
	playerA: Player,
	playerB: Player,
	offerA: OfferState,
	offerB: OfferState,
	outcome: SwapOutcome
): TradeLedger.LedgerRecord
	local sides: { [string]: TradeLedger.LedgerSide } = {}
	sides[tostring(playerA.UserId)] = {
		userId = playerA.UserId,
		playerName = playerA.Name,
		gaveCases = (outcome.takenA :: { Types.CaseStub }) :: { any },
		gaveCryptlings = table.clone(offerA.cryptlings),
	}
	sides[tostring(playerB.UserId)] = {
		userId = playerB.UserId,
		playerName = playerB.Name,
		gaveCases = (outcome.takenB :: { Types.CaseStub }) :: { any },
		gaveCryptlings = table.clone(offerB.cryptlings),
	}
	return {
		tradeId = session.tradeId,
		ts = os.time(),
		jobId = game.JobId,
		sides = sides,
		valueWarning = session.valueWarning,
	}
end

local function executeTrade(session: Session)
	session.phase = "Executing"

	local dataService = getSibling("PlayerDataService")
	-- Ascending-userId lock order: every multi-player lock in the game acquires
	-- the same way, so two concurrent executes can never deadlock (§8.2).
	local idA = math.min(session.userIds[1], session.userIds[2])
	local idB = math.max(session.userIds[1], session.userIds[2])
	local playerA = getPlayer(idA)
	local playerB = getPlayer(idB)
	if
		dataService == nil
		or playerA == nil
		or playerB == nil
		or not dataService.IsLoaded(playerA)
		or not dataService.IsLoaded(playerB)
	then
		cancelSession(session, "PLAYER_LEFT")
		return
	end
	local offerA = session.offers[idA]
	local offerB = session.offers[idB]

	local outcome: SwapOutcome? = nil
	local okOuter = dataService.WithLock(playerA, function()
		local okInner = dataService.WithLock(playerB, function()
			-- TradeFlow.DoSwap: take-take-grant-grant with per-player revalidation
			-- and restore-on-half-failure (§8.2), under both players' locks.
			outcome = TradeFlow.DoSwap(dataService, session.tradeId, playerA, playerB, offerA, offerB)
			return nil
		end)
		if not okInner then
			outcome = nil
		end
		return nil
	end)
	if not okOuter then
		outcome = nil
	end

	local result = outcome
	if result == nil then
		cancelSession(session, "EXECUTE_FAILED")
		return
	end
	if not result.ok then
		cancelSession(session, result.err or "ITEMS_CHANGED")
		return
	end

	-- Pet equip healing: a side that traded away the last copy of its equipped
	-- pet must lose the follower + perk now (PetService mirrors ShelfService's
	-- reconcile pattern). Non-yielding; same getSibling contract as GrantUpgrade.
	-- WP6.4 hardening (Security Review Scope §4): pcall-fenced — this was the
	-- only unfenced sibling call between phase="Executing" and closeSession; a
	-- throw here (swallowed by the guarded() handler wrapper) would strand the
	-- session in "Executing" and wedge TradeActive true for the server lifetime.
	local pets = getSibling("PetService")
	if pets ~= nil and type(pets.RevalidateEquip) == "function" then
		pcall(pets.RevalidateEquip, playerA)
		pcall(pets.RevalidateEquip, playerB)
	end

	-- Ledger AFTER the locks release (Append yields on SetAsync; pcall + retry
	-- lives inside TradeLedger). A ledger failure never reverses the swap.
	local record = buildLedgerRecord(session, playerA, playerB, offerA, offerB, result)
	local okAppend, appended = pcall(TradeLedger.Append, record)
	if not okAppend or appended ~= true then
		warn(`[TradeService] trade {session.tradeId}: ledger append did not complete durably`)
	end

	fireTradeEvent(session, "Completed")
	closeSession(session)

	-- §5.4 scam-review server log + §H analytics (valueWarning carried on both).
	print(`[TradeService] trade_completed {session.tradeId} valueWarning={session.valueWarning}`)
	track(playerA, "trade_completed", { valueWarning = session.valueWarning })
	track(playerB, "trade_completed", { valueWarning = session.valueWarning })
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

local function onInvite(player: Player, targetUserId: any): Reply
	if
		type(targetUserId) ~= "number"
		or targetUserId ~= targetUserId
		or targetUserId % 1 ~= 0
		or targetUserId <= 0
		or targetUserId == player.UserId
	then
		return { ok = false, err = "BAD_TARGET" }
	end

	local dataService = getSibling("PlayerDataService")
	if dataService == nil or not dataService.IsLoaded(player) then
		return { ok = false, err = "NOT_LOADED" }
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if target == nil then
		return { ok = false, err = "TARGET_NOT_FOUND" }
	end
	if not dataService.IsLoaded(target) then
		return { ok = false, err = "TARGET_NOT_LOADED" }
	end
	if activeByUser[player.UserId] ~= nil then
		return { ok = false, err = "ALREADY_TRADING" }
	end
	if activeByUser[target.UserId] ~= nil then
		return { ok = false, err = "TARGET_BUSY" }
	end
	if not isInHub(player) or not isInHub(target) then
		return { ok = false, err = "NOT_IN_HUB" }
	end
	if not withinInviteRange(player, target) then
		return { ok = false, err = "TOO_FAR" }
	end
	if not consumeInviteToken(player) then
		return { ok = false, err = "RATE_LIMITED" }
	end

	local session = newSession(player.UserId, target.UserId, "Invited", false)

	track(player, "trade_invited")
	fireTradeEvent(session, "Invited")
	return { ok = true, tradeId = session.tradeId }
end

local function onSetOffer(player: Player, tradeId: any, rawOffer: any): Reply
	local session, err = resolveSession(player, tradeId)
	if session == nil then
		return { ok = false, err = err }
	end

	local caseUids, cryptlings, offerErr = TradeService.SanitizeOffer(rawOffer)
	if caseUids == nil or cryptlings == nil then
		return { ok = false, err = offerErr or "BAD_OFFER" }
	end

	local dataService = getSibling("PlayerDataService")
	local data = if dataService ~= nil and type(dataService.Get) == "function"
		then dataService.Get(player) :: Types.ProfileData?
		else nil
	if data == nil then
		return { ok = false, err = "NOT_LOADED" }
	end
	if not TradeService.OfferAvailable(data, caseUids, cryptlings) then
		return { ok = false, err = "NOT_OWNED" }
	end

	-- ANY offer change resets BOTH confirm stages to 0 (§3.3 confirm-twice).
	TradeFlow.ApplySetOffer(session, player.UserId, caseUids, cryptlings)

	markActivity(session, player)
	refreshValueState(session)
	fireTradeEvent(session, "Updated")
	return { ok = true }
end

local function onConfirm(player: Player, tradeId: any, stage: any): Reply
	if stage ~= 1 and stage ~= 2 then
		return { ok = false, err = "BAD_STAGE" }
	end
	local session, err = resolveSession(player, tradeId)
	if session == nil then
		return { ok = false, err = err }
	end

	-- The confirm-twice FSM (§3.3) is pure: stage 1 both sides, server-stamped
	-- confirm-ready clock, stage 2 only >=3s later (server-timed, never client),
	-- idempotent re-presses, EMPTY_TRADE guard.
	local otherId = if player.UserId == session.inviterId then session.targetId else session.inviterId
	local result = TradeFlow.ApplyConfirm(session, player.UserId, otherId, stage :: number, now(), os.time())
	if not result.ok then
		return { ok = false, err = result.err }
	end
	if result.changed then
		markActivity(session, player)
		fireTradeEvent(session, "ConfirmStage", nil, session.stage2AtUnix)
	end
	if result.executeNow then
		executeTrade(session) -- yields; Completed/Cancelled fires from inside
	end
	return { ok = true }
end

local function onCancel(player: Player, tradeId: any): Reply
	local session, err = resolveSession(player, tradeId)
	if session == nil then
		return { ok = false, err = err }
	end
	cancelSession(session, "CANCELLED")
	return { ok = true }
end

-- Top-level handler guard: a bug must reply {ok=false}, never error a client.
local function guarded(name: string, handler: (Player, any, any) -> Reply): (Player, any, any) -> Reply
	return function(player: Player, a: any, b: any): Reply
		local ok, result = pcall(handler, player, a, b)
		if ok and type(result) == "table" then
			return result :: Reply
		end
		warn(`[TradeService] {name} handler failed for {player.Name}: {result}`)
		return { ok = false, err = "INTERNAL" }
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- True when `ref` (a case uid or a cryptlingId with offered count > 0) is part
-- of this player's live trade offer. In-memory lockedItems view (§8.2):
-- consulted nowhere else yet — execute-time revalidation is the hard guarantee.
function TradeService.IsItemLocked(player: Player, ref: string): boolean
	if type(ref) ~= "string" or ref == "" then
		return false
	end
	local tradeId = activeByUser[player.UserId]
	if tradeId == nil then
		return false
	end
	local session = sessions[tradeId]
	if session == nil or session.phase == "Closed" then
		return false
	end
	local offer = session.offers[player.UserId]
	if offer == nil then
		return false
	end
	if (offer.cryptlings[ref] or 0) > 0 then
		return true
	end
	for _, uid in offer.caseUids do
		if uid == ref then
			return true
		end
	end
	return false
end

function TradeService.GetActiveTradeId(player: Player): string?
	return activeByUser[player.UserId]
end

--------------------------------------------------------------------------------
-- ForTest seams (Studio-only) — TradeService.spec drives the session FSM
-- headless through these: player-like tables ({UserId, Name, ...}) carrying
-- PlayerDataService mock profiles (LoadMockProfileForTest) flow through the
-- REAL handlers, including the atomic execute path. Outside Studio every seam
-- is inert.
--------------------------------------------------------------------------------

local function isTestSeamAllowed(): boolean
	return RunService:IsStudio()
end

-- Creates a live "Negotiating" session between two player-likes (skips the
-- invite preconditions — hub/range/rate-limit are covered by live play, the
-- spec covers the economy FSM). Returns the tradeId, or nil outside Studio.
function TradeService.CreateSessionForTest(playerLikeA: any, playerLikeB: any): string?
	if not isTestSeamAllowed() then
		return nil
	end
	if type(playerLikeA) ~= "table" and typeof(playerLikeA) ~= "Instance" then
		return nil
	end
	local idA = tonumber(playerLikeA.UserId)
	local idB = tonumber(playerLikeB.UserId)
	if idA == nil or idB == nil or idA == idB then
		return nil
	end
	if activeByUser[idA] ~= nil or activeByUser[idB] ~= nil then
		return nil -- 1 active trade per player holds for fixtures too
	end
	if typeof(playerLikeA) ~= "Instance" then
		testPlayers[idA] = playerLikeA
	end
	if typeof(playerLikeB) ~= "Instance" then
		testPlayers[idB] = playerLikeB
	end
	local session = newSession(idA, idB, "Negotiating", true)
	return session.tradeId
end

-- Module-level entry points into the real remote handlers.
function TradeService.SetOfferForTest(playerLike: any, tradeId: any, rawOffer: any): Reply
	if not isTestSeamAllowed() then
		return { ok = false, err = "NOT_STUDIO" }
	end
	return onSetOffer(playerLike :: Player, tradeId, rawOffer)
end

function TradeService.ConfirmForTest(playerLike: any, tradeId: any, stage: any): Reply
	if not isTestSeamAllowed() then
		return { ok = false, err = "NOT_STUDIO" }
	end
	return onConfirm(playerLike :: Player, tradeId, stage)
end

function TradeService.CancelForTest(playerLike: any, tradeId: any): Reply
	if not isTestSeamAllowed() then
		return { ok = false, err = "NOT_STUDIO" }
	end
	return onCancel(playerLike :: Player, tradeId)
end

-- Read-only TradeState snapshot (what fireTradeEvent would push) so the spec
-- can assert confirm-stage resets and the valueWarning verdict.
function TradeService.GetSessionStateForTest(tradeId: any): Types.TradeState?
	if not isTestSeamAllowed() then
		return nil
	end
	if type(tradeId) ~= "string" then
		return nil
	end
	local session = sessions[tradeId]
	if session == nil then
		return nil
	end
	return buildState(session)
end

-- Swap the monotonic session clock (nil restores os.clock) — lets the spec
-- cross the 3s stage-2 window without sleeping.
function TradeService.SetClockForTest(fn: (() -> number)?)
	if not isTestSeamAllowed() then
		return
	end
	clockFn = fn or os.clock
end

--------------------------------------------------------------------------------
-- Auto-cancel watchers (leave / death / disconnect / shift-start)
--------------------------------------------------------------------------------

local function watchCharacter(player: Player, character: Model)
	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid ~= nil and humanoid:IsA("Humanoid") then
			humanoid.Died:Once(function()
				cancelFor(player, "DIED")
			end)
		end
	end)
end

local function onPlayerAdded(player: Player)
	if characterConns[player] ~= nil then
		return
	end
	characterConns[player] = player.CharacterAdded:Connect(function(character)
		watchCharacter(player, character)
	end)
	local character = player.Character
	if character ~= nil then
		watchCharacter(player, character)
	end
end

local function onPlayerRemoving(player: Player)
	local conn = characterConns[player]
	if conn ~= nil then
		conn:Disconnect()
	end
	characterConns[player] = nil
	inviteTimes[player.UserId] = nil
	cancelFor(player, "PLAYER_LEFT")
end

-- 1 Hz sweep: shift-start auto-cancel, pending-invite expiry, zombie sessions,
-- belt-and-braces departed-player cleanup.
local function pollSessions()
	local clock = now()
	for _, session in table.clone(sessions) do
		-- WP6.4 stuck-Executing sweeper (Security Review Scope §4): the trade
		-- data is safe either way — the swap is atomic inside both players'
		-- Update locks and closeSession only clears bookkeeping — and
		-- cancelSession is idempotent (phase == "Closed" check) should the
		-- stuck thread ever finish later. This guarantees TradeActive and the
		-- 1-active-trade-per-player index always recover.
		if session.phase == "Executing" then
			if clock - session.lastActivityAt > EXECUTING_STUCK_TIMEOUT_SECONDS then
				warn(`[TradeService] trade {session.tradeId} stuck in Executing — force-closed by the WP6.4 sweeper`)
				cancelSession(session, "EXECUTE_FAILED")
			end
			continue
		end
		if session.phase ~= "Invited" and session.phase ~= "Negotiating" then
			continue
		end
		if session.phase == "Invited" and clock - session.createdAt > INVITE_EXPIRY_SECONDS then
			cancelSession(session, "INVITE_EXPIRED")
			continue
		end
		if clock - session.lastActivityAt > SESSION_IDLE_TIMEOUT_SECONDS then
			cancelSession(session, "TIMED_OUT")
			continue
		end
		if session.isTest == true then
			continue -- ForTest player-likes have no character/hub presence
		end
		for _, userId in session.userIds do
			local player = getPlayer(userId)
			if player == nil then
				cancelSession(session, "PLAYER_LEFT")
				break
			end
			if not isInHub(player) then
				cancelSession(session, "SHIFT_STARTED")
				break
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function TradeService:Init()
	-- Remotes already exist (init.server runs Remotes.InitServer() first).
	local ok, err = pcall(function()
		tradeEvent = Remotes.GetEvent("TradeEvent")
		Remotes.GetFunction("Trade.Invite").OnServerInvoke = guarded("Trade.Invite", function(player, targetUserId)
			return onInvite(player, targetUserId)
		end)
		Remotes.GetFunction("Trade.SetOffer").OnServerInvoke = guarded("Trade.SetOffer", onSetOffer)
		Remotes.GetFunction("Trade.Confirm").OnServerInvoke = guarded("Trade.Confirm", onConfirm)
		Remotes.GetFunction("Trade.Cancel").OnServerInvoke = guarded("Trade.Cancel", function(player, tradeId)
			return onCancel(player, tradeId)
		end)
	end)
	if not ok then
		warn(`[TradeService] remote bind failed: {err}`)
	end
end

function TradeService:Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	task.spawn(function()
		while true do
			task.wait(POLL_INTERVAL_SECONDS)
			local ok, err = pcall(pollSessions)
			if not ok then
				warn(`[TradeService] session sweep failed: {err}`)
			end
		end
	end)
end

return TradeService
