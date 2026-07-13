--!strict
-- CRYPTLINGS: NIGHT SHIFT — TradeUI (Stage 4, module trade-ui).
-- Scam-resistant swap-meet trading client (SOP §3.1 ④, §3.3, §8.1):
--   * Entry: tap another player in the hub (client-local ProximityPrompt on
--     their character) or stand on the facing swap-meet TradePads (tagged
--     "TradePad" by HubService) -> "Offer Trade" -> Trade.Invite. The invitee
--     gets an accept/decline sheet with a 20s drain bar.
--   * Negotiation screen (mobile-first §3.2): two offer panes — stacked in
--     portrait, side-by-side in landscape — with rarity/tier colors and dupe
--     badges, a bottom-sheet inventory picker (SEALED CASES tab from
--     GetLockerState + CRYPTLINGS tab, counts shown, non-tradeables hidden),
--     and per-side value meters fed by Economy/ValueIndex.OfferValue with a
--     balance verdict chip.
--   * VALUE WARNING (§3.3): when TradeState.valueWarning is set against the
--     local player, a red interstitial covers the offer — "This trade is
--     heavily one-sided against you. Are you sure?" — and READY stays disabled
--     until the player explicitly taps through it. The ack re-arms whenever
--     either offer changes.
--   * Confirm-twice: stage-1 READY toggles per side (un-ready re-sends the
--     identical offer, which resets confirms server-side) with a both-ready
--     indicator; both ready -> a distinct FULL-SCREEN stage-2 summary (both
--     offers re-listed large, "TRADES ARE FINAL — no Robux, no take-backs")
--     whose round ACCEPT button is disabled for 3s behind a draining pip ring
--     (mirrors the server rule: Trade.Confirm stage 2 valid only >=3s after
--     BOTH stage-1).
--   * Any TradeEvent "Updated" that changes the PARTNER's offer while the
--     local player is readied or on the summary -> loud red "OFFER CHANGED"
--     flash and a bounce back to negotiation with confirms reset.
--   * Completed -> celebratory toast; Cancelled -> reason toast.
--
-- The server (TradeService + ValueIndex + TradeLedger) is authoritative for
-- everything: offers, confirm stages, the 3s stage-2 lock, the 20s invite
-- timeout and the value warning. This controller only renders state and
-- forwards taps; every remote call is pcall-guarded with a timeout so a
-- missing/slow server can never hang the client.
--
-- Public API (Controllers.Get("TradeUI")):
--   TradeUI.OfferTrade(targetUserId: number)  -- start an invite (hub only)
--   TradeUI.IsBusy() -> boolean               -- any trade flow on screen
--   TradeUI.Close()                           -- cancel/dismiss everything

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

-- Server-mirrored timings, read from the same GameConstants entries TradeService
-- uses (promoted at Stage 4 integration so the two can never diverge). The
-- server stays authoritative; these only drive the on-screen countdowns
-- (invite sheet drain, stage-2 accept lock).
local INVITE_TIMEOUT_SECONDS = GameConstants.TRADE_INVITE_UI_TIMEOUT_SECONDS -- 20
local STAGE2_LOCK_SECONDS = GameConstants.TRADE_CONFIRM_STAGE2_DELAY_SECONDS -- 3

local TAG_TRADE_PAD = "TradePad" -- HubService swap-meet contract
local PAD_POLL_SECONDS = 0.35
local PAD_Y_MIN, PAD_Y_MAX = -1.5, 6

local PROMPT_ACTION_TEXT = "Offer Trade"
local PROMPT_DISTANCE = 14

local SET_OFFER_DEBOUNCE_SECONDS = 0.35
local INVOKE_TIMEOUT_SECONDS = 8
local LOCKER_FETCH_TIMEOUT_SECONDS = 6

local TOAST_SECONDS = 2.6
local FLASH_SECONDS = 1.15
local BALANCED_BAND = 0.15 -- |delta| <= 15% of total value reads as balanced

-- Touch sizing: every interactive target >= the §G mobile gate.
local MIN_TOUCH_PX = GameConstants.MOBILE_MIN_TOUCH_TARGET_PX -- 44
local BUTTON_HEIGHT_PX = math.max(MIN_TOUCH_PX, 52)
local CLOSE_PX = math.max(MIN_TOUCH_PX, 48)
local TAB_HEIGHT_PX = math.max(MIN_TOUCH_PX, 46)
local CARD_WIDTH_PX = 104
local CARD_HEIGHT_PX = 64
local PICK_CARD_WIDTH_PX = 104
local PICK_CARD_HEIGHT_PX = 92
local ACCEPT_DIAMETER_PX = 96
local RING_PIPS = 16
local RING_RADIUS_PX = 64

-- Palette (matches LockerUI/RunHUD/UnboxingUI greybox chrome).
local COLOR_PANEL = Color3.fromRGB(18, 20, 24)
local COLOR_PANEL_RAISED = Color3.fromRGB(30, 33, 39)
local COLOR_TEXT = Color3.fromRGB(235, 238, 240)
local COLOR_TEXT_DIM = Color3.fromRGB(160, 166, 172)
local COLOR_ACCENT = Color3.fromRGB(80, 220, 120)
local COLOR_GOLD = Color3.fromRGB(235, 190, 52)
local COLOR_WARN = Color3.fromRGB(205, 60, 50)
local COLOR_AMBER = Color3.fromRGB(225, 160, 60)
local COLOR_SCRIM = Color3.fromRGB(8, 9, 12)
local COLOR_METER_TRACK = Color3.fromRGB(60, 64, 70)
local COLOR_FALLBACK = Color3.fromRGB(178, 178, 178)

-- DisplayOrder 18: above LockerUI (16), below the unboxing theater (20),
-- OddsUI (24) and BroadcastUI (40).
local DISPLAY_ORDER = 18

local SOUND_PING = "rbxasset://sounds/electronicpingshort.wav"
local SOUND_SNAP = "rbxasset://sounds/snap.mp3"

local FINAL_WARNING_TEXT = "TRADES ARE FINAL — no Robux, no take-backs"

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type NormalizedOffer = {
	caseUids: { string },
	caseTiers: { [string]: number }, -- only where known (own locker / server hint)
	cryptlings: { [string]: number },
	confirmStage: number,
}

type NormalizedTrade = {
	tradeId: string,
	partnerUserId: number,
	mine: NormalizedOffer,
	theirs: NormalizedOffer,
	valueWarning: boolean,
	warningAgainstMe: boolean,
	myValue: number?,
	theirValue: number?,
}

type PendingOffer = {
	caseUids: { string },
	cryptlings: { [string]: number },
}

type Phase = "Idle" | "Inviting" | "IncomingInvite" | "Negotiating" | "Summary"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local TradeUI = {}

local registryRef: any = nil -- Controllers registry (CursorUnlock lookup)

local phase: Phase = "Idle"
local shiftStateName = "Intermission"

local activeTradeId: string? = nil
local partnerUserId: number? = nil
local outgoingTargetUserId: number? = nil
local lastNormalized: NormalizedTrade? = nil
local lastRawState: any = nil

-- Local optimistic copy of MY offer (server echo overwrites on Updated).
local pendingOffer: PendingOffer = { caseUids = {}, cryptlings = {} }
local setOfferToken = 0
local readyInFlight = false

-- Warning interstitial ack: stores the offers fingerprint it was acked for, so
-- any offer change re-arms it (§3.3).
local warningAckFingerprint: string? = nil

-- Inventory caches.
local lockerCaseByUid: { [string]: Types.CaseStub } = {}
local lockerCases: { Types.CaseStub } = {}
local lockerFetchInFlight = false

local sessionToken = 0 -- invalidates per-flow loops (countdowns, ring drain)
local summaryArmed = false -- stage-2 ACCEPT past its 3s lock
local activePickerTab: "Cases" | "Cryptlings" = "Cases"

local ui: any = nil -- root gui refs (banner/toast, built in Start)
local trade: any = nil -- heavy trade frames (built lazily)

local playerPrompts: { [Player]: ProximityPrompt } = {}
local padTargetUserId: number? = nil

local valueIndexModule: any = nil
local valueIndexResolved = false

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function myKey(): string
	return tostring(LocalPlayer.UserId)
end

-- First-person cursor release (R4-2): the token is held whenever any trade
-- surface is on screen (phase ~= Idle) — invite sheet, waiting card,
-- negotiation, summary — and dropped only in the Idle funnel / Close.
-- Registry lookup, nil-guarded: a missing CursorUnlock degrades to a no-op.
local CURSOR_TOKEN = "TradeUI"

local function setCursorReleased(released: boolean)
	if registryRef == nil or type(registryRef.Get) ~= "function" then
		return
	end
	local cursorUnlock = registryRef.Get("CursorUnlock")
	if cursorUnlock == nil then
		return
	end
	if released then
		cursorUnlock.acquire(CURSOR_TOKEN)
	else
		cursorUnlock.release(CURSOR_TOKEN)
	end
end

local function rarityColor(rarity: string?): Color3
	local color = if rarity ~= nil then (RarityTable.RARITY_COLORS :: any)[rarity] else nil
	if typeof(color) == "Color3" then
		return color
	end
	return COLOR_FALLBACK
end

-- Case tier -> greybox color, the same T1=Common / T2=Rare / T3=Godly mapping
-- the rest of the client uses (§E palette).
local TIER_COLOR_KEYS: { [number]: string } =
	{ [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Mythical" }

local function tierColor(tier: number?): Color3
	if tier == nil then
		return COLOR_FALLBACK
	end
	return rarityColor(TIER_COLOR_KEYS[tier])
end

local function makeLabel(name: string, textSize: number, bold: boolean): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = COLOR_TEXT
	return label
end

local function makeButton(name: string, text: string, bg: Color3, fg: Color3): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = bg
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextColor3 = fg
	button.Text = text
	button.AutoButtonColor = true
	return button
end

local function makeRound(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function partnerName(): string
	local userId = partnerUserId
	if userId == nil then
		return "?"
	end
	local player = Players:GetPlayerByUserId(userId)
	if player ~= nil then
		return player.DisplayName
	end
	return `Player {userId}`
end

local function isPortrait(): boolean
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return true
	end
	local size = camera.ViewportSize
	return size.Y > size.X
end

-- Guarded RemoteFunction invoke: returns the response table or nil on
-- error/timeout. Never raises, never hangs (an unbound remote just times out).
local function invoke(name: string, timeoutSeconds: number, ...: any): any
	local args = table.pack(...)
	local response: any = nil
	local done = false
	task.spawn(function()
		local ok, result = pcall(function()
			return Remotes.GetFunction(name):InvokeServer(table.unpack(args, 1, args.n))
		end)
		if ok then
			response = result
		end
		done = true
	end)
	local deadline = os.clock() + timeoutSeconds
	while not done and os.clock() < deadline do
		task.wait(0.05)
	end
	return response
end

--------------------------------------------------------------------------------
-- Toast (bottom center, above everything in this gui)
--------------------------------------------------------------------------------

local toastToken = 0

local function showToast(text: string, color: Color3)
	if ui == nil then
		return
	end
	toastToken += 1
	local token = toastToken
	local frame: Frame = ui.toastFrame
	local label: TextLabel = ui.toastLabel
	label.Text = text
	frame.BackgroundColor3 = COLOR_PANEL
	local stroke: UIStroke = ui.toastStroke
	stroke.Color = color
	label.TextColor3 = color
	frame.Visible = true
	frame.Position = UDim2.new(0.5, 0, 1, 40)
	TweenService:Create(
		frame,
		TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 1, -16) }
	):Play()
	local ping: Sound = ui.pingSound
	ping:Play()
	task.delay(TOAST_SECONDS, function()
		if token == toastToken and ui ~= nil then
			ui.toastFrame.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- ValueIndex (Stage 4 sibling, Economy/ValueIndex.luau) — defensive resolve.
-- The meters degrade to "syncing" if the module is absent or its OfferValue
-- shape differs; the warning interstitial never depends on it (the server
-- computes TradeState.valueWarning).
--------------------------------------------------------------------------------

local function resolveValueIndex(): any
	if valueIndexResolved then
		return valueIndexModule
	end
	local economy = Shared:FindFirstChild("Economy")
	local module = if economy ~= nil then economy:FindFirstChild("ValueIndex") else nil
	if module ~= nil and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			valueIndexModule = result
			valueIndexResolved = true
		end
	end
	return valueIndexModule
end

-- Best-effort client-side value of one offer. Returns nil when the offer
-- contains cases whose tier we cannot see, or when ValueIndex is unavailable.
local function computeOfferValue(offer: NormalizedOffer): number?
	local valueIndex = resolveValueIndex()
	if valueIndex == nil then
		return nil
	end
	local tiers: { number } = {}
	for _, uid in offer.caseUids do
		local tier = offer.caseTiers[uid]
		if tier == nil then
			return nil -- can't price a case of unknown tier
		end
		table.insert(tiers, tier)
	end

	-- Shape 1: OfferValue(offerTable) — superset table so several reasonable
	-- server-side signatures all read what they need. caseStubsOrTiers is the
	-- field the shipped Economy/ValueIndex.Offer type actually reads.
	if type(valueIndex.OfferValue) == "function" then
		local ok, result = pcall(valueIndex.OfferValue, {
			caseStubsOrTiers = tiers,
			caseUids = offer.caseUids,
			caseTiers = tiers,
			cases = tiers,
			cryptlings = offer.cryptlings,
		})
		if ok and type(result) == "number" then
			return result
		end
		-- Shape 2: OfferValue(caseTiers, cryptlings)
		local ok2, result2 = pcall(valueIndex.OfferValue, tiers, offer.cryptlings)
		if ok2 and type(result2) == "number" then
			return result2
		end
	end

	-- Shape 3: per-item valuation helpers.
	local caseFn = valueIndex.CaseValue
	local cryptlingFn = valueIndex.CryptlingValue
	if type(caseFn) == "function" and type(cryptlingFn) == "function" then
		local total = 0
		for _, tier in tiers do
			local ok, value = pcall(caseFn, tier)
			if not ok or type(value) ~= "number" then
				return nil
			end
			total += value
		end
		for id, count in offer.cryptlings do
			local ok, value = pcall(cryptlingFn, id)
			if not ok or type(value) ~= "number" then
				return nil
			end
			total += value * count
		end
		return total
	end
	return nil
end

--------------------------------------------------------------------------------
-- TradeState normalization (defensive over the wire shape)
--------------------------------------------------------------------------------

local function normalizeOffer(raw: any, extTiers: any): NormalizedOffer
	local offer: NormalizedOffer = { caseUids = {}, caseTiers = {}, cryptlings = {}, confirmStage = 0 }
	if type(raw) ~= "table" then
		return offer
	end
	if type(raw.confirmStage) == "number" then
		offer.confirmStage = raw.confirmStage
	end
	if type(raw.offerCaseUids) == "table" then
		for _, entry in raw.offerCaseUids :: { any } do
			if type(entry) == "string" then
				table.insert(offer.caseUids, entry)
			elseif type(entry) == "table" and type(entry.uid) == "string" then
				-- Tolerate a richer server shape ({uid, tier}) if it ever ships.
				table.insert(offer.caseUids, entry.uid)
				if type(entry.tier) == "number" then
					offer.caseTiers[entry.uid] = entry.tier
				end
			end
		end
	end
	if type(raw.offerCryptlings) == "table" then
		for id, count in raw.offerCryptlings :: { [any]: any } do
			if type(id) == "string" and type(count) == "number" and count > 0 then
				offer.cryptlings[id] = math.floor(count)
			end
		end
	end
	-- Fill tiers from a server hint map and finally from the local locker
	-- (always works for the local player's own sealed cases).
	for _, uid in offer.caseUids do
		if offer.caseTiers[uid] == nil then
			if type(extTiers) == "table" and type(extTiers[uid]) == "number" then
				offer.caseTiers[uid] = extTiers[uid]
			else
				local stub = lockerCaseByUid[uid]
				if stub ~= nil then
					offer.caseTiers[uid] = stub.tier
				end
			end
		end
	end
	return offer
end

local function normalizeTrade(raw: any): NormalizedTrade?
	if type(raw) ~= "table" or type(raw.tradeId) ~= "string" or type(raw.players) ~= "table" then
		return nil
	end
	local mineKey = myKey()
	local mineRaw: any = nil
	local theirsRaw: any = nil
	local otherKey: string? = nil
	for key, entry in raw.players :: { [any]: any } do
		if tostring(key) == mineKey then
			mineRaw = entry
		elseif otherKey == nil then
			otherKey = tostring(key)
			theirsRaw = entry
		end
	end
	if mineRaw == nil or otherKey == nil then
		return nil
	end

	local extTiers = raw.caseTiers -- optional server hint {[uid]: tier}
	local mine = normalizeOffer(mineRaw, extTiers)
	local theirs = normalizeOffer(theirsRaw, extTiers)

	-- Optional server-computed values {[userIdStr]: number} beat any client math.
	local myValue: number? = nil
	local theirValue: number? = nil
	if type(raw.values) == "table" then
		local rawMine = (raw.values :: any)[mineKey]
		local rawTheirs = (raw.values :: any)[otherKey]
		if type(rawMine) == "number" then
			myValue = rawMine
		end
		if type(rawTheirs) == "number" then
			theirValue = rawTheirs
		end
	end
	if myValue == nil then
		myValue = computeOfferValue(mine)
	end
	if theirValue == nil then
		theirValue = computeOfferValue(theirs)
	end

	local valueWarning = raw.valueWarning == true
	local warningAgainstMe = valueWarning
	if type(raw.valueWarningFor) == "string" then
		warningAgainstMe = valueWarning and raw.valueWarningFor == mineKey
	elseif valueWarning and myValue ~= nil and theirValue ~= nil then
		-- One-sided AGAINST you = you give meaningfully more than you get.
		warningAgainstMe = myValue > theirValue
	end

	return {
		tradeId = raw.tradeId,
		partnerUserId = tonumber(otherKey) or 0,
		mine = mine,
		theirs = theirs,
		valueWarning = valueWarning,
		warningAgainstMe = warningAgainstMe,
		myValue = myValue,
		theirValue = theirValue,
	}
end

local function offerFingerprint(offer: NormalizedOffer): string
	local uids = table.clone(offer.caseUids)
	table.sort(uids)
	local parts = { table.concat(uids, ",") }
	local ids: { string } = {}
	for id in offer.cryptlings do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		table.insert(parts, `{id}={offer.cryptlings[id]}`)
	end
	return table.concat(parts, "|")
end

--------------------------------------------------------------------------------
-- Inventory: sealed cases (GetLockerState) + cryptling collection
--------------------------------------------------------------------------------

local function isCaseStubShaped(stub: any): boolean
	return type(stub) == "table"
		and type(stub.uid) == "string"
		and type(stub.tier) == "number"
		and stub.tier >= 1
		and stub.tier <= 6 -- CaseStub tier domain 1..6 (6 = rainbow box); see Shared.Types.CaseStub
end

local refreshAfterLockerFetch: () -> () = function() end -- rebound after gui builders

local function fetchLockerCases()
	if lockerFetchInFlight then
		return
	end
	lockerFetchInFlight = true
	task.spawn(function()
		local state = invoke("GetLockerState", LOCKER_FETCH_TIMEOUT_SECONDS)
		lockerFetchInFlight = false
		if type(state) ~= "table" or type(state.cases) ~= "table" then
			return
		end
		table.clear(lockerCaseByUid)
		table.clear(lockerCases)
		for _, stub in state.cases :: { any } do
			if isCaseStubShaped(stub) then
				lockerCaseByUid[stub.uid] = stub
				table.insert(lockerCases, stub)
			end
		end
		table.sort(lockerCases, function(a, b)
			if a.tier ~= b.tier then
				return a.tier > b.tier
			end
			return a.uid < b.uid
		end)
		refreshAfterLockerFetch()
	end)
end

-- Cryptling collection counts {[cryptlingId]: count}. No remote in CONTRACTS
-- §B exposes the profile collection, so this resolves defensively:
--   1) LocalPlayer attribute "TradeCollection" (JSON map) — the channel the
--      Stage 4 trade server is asked to publish (see module openIssues);
--   2) an optional `collections`/`inventories` extension on the TradeState
--      payload. Returns nil when neither exists (the Cryptlings tab then shows
--      a sync notice; case trading still works end-to-end).
local function getOwnedCollection(): { [string]: number }?
	local attribute = LocalPlayer:GetAttribute("TradeCollection")
	if type(attribute) == "string" and attribute ~= "" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(attribute)
		end)
		if ok and type(decoded) == "table" then
			local counts: { [string]: number } = {}
			for id, count in decoded :: { [any]: any } do
				if type(id) == "string" and type(count) == "number" and count > 0 then
					counts[id] = math.floor(count)
				end
			end
			return counts
		end
	end
	local raw = lastRawState
	if type(raw) == "table" then
		for _, fieldName in { "collections", "inventories" } do
			local field = (raw :: any)[fieldName]
			local entry = if type(field) == "table" then field[myKey()] else nil
			if type(entry) == "table" then
				local source: any = if type(entry.cryptlings) == "table" then entry.cryptlings else entry
				local counts: { [string]: number } = {}
				local any = false
				for id, count in source :: { [any]: any } do
					if type(id) == "string" and type(count) == "number" and count > 0 then
						counts[id] = math.floor(count)
						any = true
					end
				end
				if any then
					return counts
				end
			end
		end
	end
	return nil
end

local function isTradeable(cryptlingId: string): boolean
	local def = RarityTable.GetCryptling(cryptlingId)
	if type(def) ~= "table" then
		return false
	end
	return def.tradeable ~= false
end

local function offeredCryptlingCount(id: string): number
	return pendingOffer.cryptlings[id] or 0
end

local function isCaseOffered(uid: string): boolean
	return table.find(pendingOffer.caseUids, uid) ~= nil
end

--------------------------------------------------------------------------------
-- Forward declarations (flow functions referenced before their definitions)
--------------------------------------------------------------------------------

local rebuildNegotiation: () -> ()
local openSummary: () -> ()
local closeSummary: () -> ()
local resetToIdle: () -> ()
local rebuildPicker: () -> ()
local updateEntryAffordances: () -> ()

--------------------------------------------------------------------------------
-- Offer mutations (optimistic local + debounced Trade.SetOffer)
--------------------------------------------------------------------------------

local function snapshotPendingOffer(): { caseUids: { string }, cryptlings: { [string]: number } }
	return {
		caseUids = table.clone(pendingOffer.caseUids),
		cryptlings = table.clone(pendingOffer.cryptlings),
	}
end

local function scheduleSetOffer()
	setOfferToken += 1
	local token = setOfferToken
	local tradeId = activeTradeId
	if tradeId == nil then
		return
	end
	task.delay(SET_OFFER_DEBOUNCE_SECONDS, function()
		if token ~= setOfferToken or activeTradeId ~= tradeId then
			return
		end
		local response = invoke("Trade.SetOffer", INVOKE_TIMEOUT_SECONDS, tradeId, snapshotPendingOffer())
		if type(response) ~= "table" or response.ok ~= true then
			-- Resync from the last authoritative state and tell the player.
			local normalized = lastNormalized
			if normalized ~= nil then
				pendingOffer.caseUids = table.clone(normalized.mine.caseUids)
				pendingOffer.cryptlings = table.clone(normalized.mine.cryptlings)
			end
			showToast("Couldn't update your offer — try again", COLOR_WARN)
			if phase == "Negotiating" then
				rebuildNegotiation()
				rebuildPicker()
			end
		end
	end)
end

local function addCaseToOffer(uid: string)
	if isCaseOffered(uid) then
		return
	end
	table.insert(pendingOffer.caseUids, uid)
	scheduleSetOffer()
end

local function removeCaseFromOffer(uid: string)
	local index = table.find(pendingOffer.caseUids, uid)
	if index ~= nil then
		table.remove(pendingOffer.caseUids, index)
		scheduleSetOffer()
	end
end

local function addCryptlingToOffer(id: string, ownedCount: number)
	local current = offeredCryptlingCount(id)
	if current >= ownedCount then
		return
	end
	pendingOffer.cryptlings[id] = current + 1
	scheduleSetOffer()
end

local function removeCryptlingFromOffer(id: string)
	local current = offeredCryptlingCount(id)
	if current <= 1 then
		pendingOffer.cryptlings[id] = nil
	else
		pendingOffer.cryptlings[id] = current - 1
	end
	scheduleSetOffer()
end

-- Un-ready: re-sending the IDENTICAL offer is the in-contract way to reset
-- confirm stages on both sides (any offer update resets confirms server-side).
local function requestUnready()
	local tradeId = activeTradeId
	if tradeId == nil then
		return
	end
	task.spawn(function()
		invoke("Trade.SetOffer", INVOKE_TIMEOUT_SECONDS, tradeId, snapshotPendingOffer())
	end)
end

--------------------------------------------------------------------------------
-- Root gui (banner + toast + sounds) — built once in Start
--------------------------------------------------------------------------------

local function buildRootGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TradeUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	gui.DisplayOrder = DISPLAY_ORDER

	-- Swap-meet pad banner: appears when the local player and a partner stand
	-- on facing TradePads. Bottom-center, one-thumb.
	local banner = makeButton("PadBanner", "OFFER TRADE", COLOR_ACCENT, COLOR_PANEL)
	banner.AnchorPoint = Vector2.new(0.5, 1)
	banner.Position = UDim2.new(0.5, 0, 1, -84)
	banner.Size = UDim2.fromOffset(300, BUTTON_HEIGHT_PX)
	banner.TextSize = 16
	banner.Visible = false
	banner.ZIndex = 2
	banner.Parent = gui
	makeRound(banner, 14)

	-- Toast.
	local toastFrame = Instance.new("Frame")
	toastFrame.Name = "Toast"
	toastFrame.AnchorPoint = Vector2.new(0.5, 1)
	toastFrame.Position = UDim2.new(0.5, 0, 1, -16)
	toastFrame.Size = UDim2.fromOffset(320, 52)
	toastFrame.BackgroundColor3 = COLOR_PANEL
	toastFrame.BackgroundTransparency = 0.06
	toastFrame.BorderSizePixel = 0
	toastFrame.Visible = false
	toastFrame.ZIndex = 60
	toastFrame.Parent = gui
	makeRound(toastFrame, 12)
	local toastStroke = Instance.new("UIStroke")
	toastStroke.Color = COLOR_ACCENT
	toastStroke.Thickness = 1.5
	toastStroke.Transparency = 0.25
	toastStroke.Parent = toastFrame

	local toastLabel = makeLabel("Text", 14, true)
	toastLabel.Size = UDim2.new(1, -20, 1, 0)
	toastLabel.Position = UDim2.fromOffset(10, 0)
	toastLabel.TextWrapped = true
	toastLabel.ZIndex = 61
	toastLabel.Parent = toastFrame

	local ping = Instance.new("Sound")
	ping.Name = "Ping"
	ping.SoundId = SOUND_PING
	ping.Volume = 0.25
	ping.Parent = gui

	local snap = Instance.new("Sound")
	snap.Name = "Snap"
	snap.SoundId = SOUND_SNAP
	snap.Volume = 0.5
	snap.Parent = gui

	ui = {
		gui = gui,
		banner = banner,
		toastFrame = toastFrame,
		toastLabel = toastLabel,
		toastStroke = toastStroke,
		pingSound = ping,
		snapSound = snap,
	}
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	banner.Activated:Connect(function()
		local target = padTargetUserId
		if target ~= nil then
			TradeUI.OfferTrade(target)
		end
	end)
end

--------------------------------------------------------------------------------
-- Item cards (offer grids + summary rows)
--------------------------------------------------------------------------------

type CardSpec = {
	name: string,
	title: string,
	subtitle: string?,
	color: Color3,
	count: number?,
	dupe: boolean,
	order: number,
	onTap: (() -> ())?,
}

local function buildItemCard(parent: Instance, spec: CardSpec): TextButton
	local card = makeButton(spec.name, "", COLOR_PANEL_RAISED, COLOR_TEXT)
	card.AutoButtonColor = spec.onTap ~= nil
	card.LayoutOrder = spec.order
	card.ZIndex = 4
	makeRound(card, 10)

	local stroke = Instance.new("UIStroke")
	stroke.Color = spec.color
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = card

	local title = makeLabel("Title", 13, true)
	title.Position = UDim2.fromOffset(6, 6)
	title.Size = UDim2.new(1, -12, 0, 16)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.TextColor3 = spec.color
	title.Text = spec.title
	title.ZIndex = 5
	title.Parent = card

	if spec.subtitle ~= nil then
		local subtitle = makeLabel("Subtitle", 11, false)
		subtitle.Position = UDim2.fromOffset(6, 24)
		subtitle.Size = UDim2.new(1, -12, 0, 14)
		subtitle.TextXAlignment = Enum.TextXAlignment.Left
		subtitle.TextColor3 = COLOR_TEXT_DIM
		subtitle.Text = spec.subtitle
		subtitle.ZIndex = 5
		subtitle.Parent = card
	end

	if spec.count ~= nil and spec.count > 1 then
		local count = makeLabel("Count", 13, true)
		count.AnchorPoint = Vector2.new(1, 1)
		count.Position = UDim2.new(1, -6, 1, -4)
		count.Size = UDim2.fromOffset(40, 16)
		count.TextXAlignment = Enum.TextXAlignment.Right
		count.Text = `x{spec.count}`
		count.ZIndex = 5
		count.Parent = card
	end

	if spec.dupe then
		local badge = makeLabel("Dupe", 10, true)
		badge.BackgroundTransparency = 0
		badge.BackgroundColor3 = COLOR_GOLD
		badge.TextColor3 = COLOR_PANEL
		badge.AnchorPoint = Vector2.new(0, 1)
		badge.Position = UDim2.new(0, 6, 1, -4)
		badge.Size = UDim2.fromOffset(38, 14)
		badge.Text = "DUPE"
		badge.ZIndex = 5
		badge.Parent = card
		makeRound(badge, 7)
	end

	local onTap = spec.onTap
	if onTap ~= nil then
		card.Activated:Connect(onTap)
	end
	card.Parent = parent
	return card
end

--------------------------------------------------------------------------------
-- Offer pane (used twice: YOUR OFFER / THEIR OFFER)
--------------------------------------------------------------------------------

local function buildOfferPane(parent: Instance, paneName: string): any
	local root = Instance.new("Frame")
	root.Name = paneName
	root.BackgroundColor3 = COLOR_PANEL_RAISED
	root.BackgroundTransparency = 0.35
	root.BorderSizePixel = 0
	root.ZIndex = 3
	root.Parent = parent
	makeRound(root, 12)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = root

	local title = makeLabel("Title", 14, true)
	title.Position = UDim2.fromOffset(2, 2)
	title.Size = UDim2.new(1, -96, 0, 18)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.ZIndex = 4
	title.Parent = root

	local ready = makeLabel("Ready", 12, true)
	ready.AnchorPoint = Vector2.new(1, 0)
	ready.Position = UDim2.new(1, -2, 0, 2)
	ready.Size = UDim2.fromOffset(90, 18)
	ready.TextXAlignment = Enum.TextXAlignment.Right
	ready.TextColor3 = COLOR_TEXT_DIM
	ready.Text = "NOT READY"
	ready.ZIndex = 4
	ready.Parent = root

	local meterTrack = Instance.new("Frame")
	meterTrack.Name = "MeterTrack"
	meterTrack.Position = UDim2.fromOffset(2, 24)
	meterTrack.Size = UDim2.new(1, -76, 0, 8)
	meterTrack.BackgroundColor3 = COLOR_METER_TRACK
	meterTrack.BorderSizePixel = 0
	meterTrack.ZIndex = 4
	meterTrack.Parent = root
	makeRound(meterTrack, 4)

	local meterFill = Instance.new("Frame")
	meterFill.Name = "Fill"
	meterFill.Size = UDim2.fromScale(0, 1)
	meterFill.BackgroundColor3 = COLOR_ACCENT
	meterFill.BorderSizePixel = 0
	meterFill.ZIndex = 5
	meterFill.Parent = meterTrack
	makeRound(meterFill, 4)

	local meterValue = makeLabel("MeterValue", 12, true)
	meterValue.AnchorPoint = Vector2.new(1, 0)
	meterValue.Position = UDim2.new(1, -2, 0, 20)
	meterValue.Size = UDim2.fromOffset(68, 16)
	meterValue.TextXAlignment = Enum.TextXAlignment.Right
	meterValue.TextColor3 = COLOR_TEXT_DIM
	meterValue.Text = "—"
	meterValue.ZIndex = 4
	meterValue.Parent = root

	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.Position = UDim2.fromOffset(0, 38)
	grid.Size = UDim2.new(1, 0, 1, -38)
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.ScrollBarThickness = 4
	grid.ScrollBarImageColor3 = COLOR_METER_TRACK
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.ZIndex = 4
	grid.Parent = root
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(CARD_WIDTH_PX, CARD_HEIGHT_PX)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	local empty = makeLabel("Empty", 13, false)
	empty.AnchorPoint = Vector2.new(0.5, 0)
	empty.Position = UDim2.new(0.5, 0, 0, 14)
	empty.Size = UDim2.new(1, -16, 0, 36)
	empty.TextColor3 = COLOR_TEXT_DIM
	empty.TextWrapped = true
	empty.Visible = false
	empty.ZIndex = 4
	empty.Parent = grid

	return {
		root = root,
		title = title,
		ready = ready,
		meterFill = meterFill,
		meterValue = meterValue,
		grid = grid,
		empty = empty,
	}
end

local function clearGrid(grid: ScrollingFrame)
	for _, child in grid:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

--------------------------------------------------------------------------------
-- Heavy trade gui (invite sheets, negotiation, picker, summary, flash) — lazy
--------------------------------------------------------------------------------

local function buildCenterCard(parent: Instance, name: string, height: number): Frame
	local card = Instance.new("Frame")
	card.Name = name
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(320, height)
	card.BackgroundColor3 = COLOR_PANEL
	card.BorderSizePixel = 0
	card.ZIndex = 31
	card.Parent = parent
	makeRound(card, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Color = COLOR_ACCENT
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = card
	return card
end

local function buildDrainBar(parent: Instance, y: number): Frame
	local track = Instance.new("Frame")
	track.Name = "DrainTrack"
	track.Position = UDim2.fromOffset(16, y)
	track.Size = UDim2.new(1, -32, 0, 6)
	track.BackgroundColor3 = COLOR_METER_TRACK
	track.BorderSizePixel = 0
	track.ZIndex = 32
	track.Parent = parent
	makeRound(track, 3)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = COLOR_GOLD
	fill.BorderSizePixel = 0
	fill.ZIndex = 33
	fill.Parent = track
	makeRound(fill, 3)
	return fill
end

local function buildTradeGui()
	if trade ~= nil or ui == nil then
		return
	end
	local gui: ScreenGui = ui.gui

	----------------------------------------------------------------------------
	-- Modal scrim shared by the invite/waiting cards
	----------------------------------------------------------------------------
	local modalScrim = Instance.new("Frame")
	modalScrim.Name = "ModalScrim"
	modalScrim.Size = UDim2.fromScale(1, 1)
	modalScrim.BackgroundColor3 = COLOR_SCRIM
	modalScrim.BackgroundTransparency = 0.45
	modalScrim.BorderSizePixel = 0
	modalScrim.Visible = false
	modalScrim.ZIndex = 30
	modalScrim.Parent = gui

	----------------------------------------------------------------------------
	-- Incoming invite sheet (accept/decline, 20s drain)
	----------------------------------------------------------------------------
	local inviteCard = buildCenterCard(gui, "InviteCard", 224)
	inviteCard.Visible = false

	local inviteTitle = makeLabel("Title", 18, true)
	inviteTitle.Position = UDim2.fromOffset(16, 16)
	inviteTitle.Size = UDim2.new(1, -32, 0, 44)
	inviteTitle.TextWrapped = true
	inviteTitle.Text = "Trade offer"
	inviteTitle.ZIndex = 32
	inviteTitle.Parent = inviteCard

	local inviteBody = makeLabel("Body", 13, false)
	inviteBody.Position = UDim2.fromOffset(16, 62)
	inviteBody.Size = UDim2.new(1, -32, 0, 30)
	inviteBody.TextWrapped = true
	inviteBody.TextColor3 = COLOR_TEXT_DIM
	inviteBody.Text = "wants to trade with you at the swap meet."
	inviteBody.ZIndex = 32
	inviteBody.Parent = inviteCard

	local inviteDrain = buildDrainBar(inviteCard, 100)

	local inviteAccept = makeButton("Accept", "ACCEPT", COLOR_ACCENT, COLOR_PANEL)
	inviteAccept.Position = UDim2.new(0, 16, 1, -(BUTTON_HEIGHT_PX * 2 + 24))
	inviteAccept.Size = UDim2.new(1, -32, 0, BUTTON_HEIGHT_PX)
	inviteAccept.ZIndex = 32
	inviteAccept.Parent = inviteCard
	makeRound(inviteAccept, 12)

	local inviteDecline = makeButton("Decline", "DECLINE", COLOR_PANEL_RAISED, COLOR_TEXT)
	inviteDecline.Position = UDim2.new(0, 16, 1, -(BUTTON_HEIGHT_PX + 14))
	inviteDecline.Size = UDim2.new(1, -32, 0, BUTTON_HEIGHT_PX)
	inviteDecline.ZIndex = 32
	inviteDecline.Parent = inviteCard
	makeRound(inviteDecline, 12)

	----------------------------------------------------------------------------
	-- Outgoing invite (waiting) card
	----------------------------------------------------------------------------
	local waitingCard = buildCenterCard(gui, "WaitingCard", 178)
	waitingCard.Visible = false

	local waitingTitle = makeLabel("Title", 16, true)
	waitingTitle.Position = UDim2.fromOffset(16, 16)
	waitingTitle.Size = UDim2.new(1, -32, 0, 44)
	waitingTitle.TextWrapped = true
	waitingTitle.Text = "Invite sent"
	waitingTitle.ZIndex = 32
	waitingTitle.Parent = waitingCard

	local waitingDrain = buildDrainBar(waitingCard, 72)

	local waitingCancel = makeButton("Cancel", "CANCEL INVITE", COLOR_PANEL_RAISED, COLOR_TEXT)
	waitingCancel.Position = UDim2.new(0, 16, 1, -(BUTTON_HEIGHT_PX + 14))
	waitingCancel.Size = UDim2.new(1, -32, 0, BUTTON_HEIGHT_PX)
	waitingCancel.ZIndex = 32
	waitingCancel.Parent = waitingCard
	makeRound(waitingCancel, 12)

	----------------------------------------------------------------------------
	-- Negotiation screen (full screen)
	----------------------------------------------------------------------------
	local nego = Instance.new("Frame")
	nego.Name = "Negotiation"
	nego.Size = UDim2.fromScale(1, 1)
	nego.BackgroundColor3 = COLOR_PANEL
	nego.BackgroundTransparency = 0.04
	nego.BorderSizePixel = 0
	nego.Visible = false
	nego.ZIndex = 2
	nego.Parent = gui

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 56)
	header.BackgroundTransparency = 1
	header.ZIndex = 3
	header.Parent = nego

	local negoTitle = makeLabel("Title", 18, true)
	negoTitle.Position = UDim2.fromOffset(14, 8)
	negoTitle.Size = UDim2.new(1, -80, 0, 22)
	negoTitle.TextXAlignment = Enum.TextXAlignment.Left
	negoTitle.TextTruncate = Enum.TextTruncate.AtEnd
	negoTitle.Text = "SWAP MEET"
	negoTitle.ZIndex = 4
	negoTitle.Parent = header

	local negoSub = makeLabel("Sub", 12, false)
	negoSub.Position = UDim2.fromOffset(14, 32)
	negoSub.Size = UDim2.new(1, -80, 0, 16)
	negoSub.TextXAlignment = Enum.TextXAlignment.Left
	negoSub.TextColor3 = COLOR_TEXT_DIM
	negoSub.Text = FINAL_WARNING_TEXT
	negoSub.ZIndex = 4
	negoSub.Parent = header

	local negoClose = makeButton("Close", "X", COLOR_PANEL_RAISED, COLOR_TEXT_DIM)
	negoClose.AnchorPoint = Vector2.new(1, 0)
	negoClose.Position = UDim2.new(1, -10, 0, 6)
	negoClose.Size = UDim2.fromOffset(CLOSE_PX, CLOSE_PX)
	negoClose.TextSize = 18
	negoClose.ZIndex = 4
	negoClose.Parent = header
	makeRound(negoClose, 12)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(10, 56)
	content.Size = UDim2.new(1, -20, 1, -(56 + BUTTON_HEIGHT_PX + 26))
	content.BackgroundTransparency = 1
	content.ZIndex = 3
	content.Parent = nego

	local paneTheirs = buildOfferPane(content, "PaneTheirs")
	local paneMine = buildOfferPane(content, "PaneMine")
	paneMine.title.Text = "YOUR OFFER"

	-- Balance verdict chip between the panes.
	local balance = makeLabel("Balance", 13, true)
	balance.BackgroundTransparency = 0
	balance.BackgroundColor3 = COLOR_PANEL_RAISED
	balance.AnchorPoint = Vector2.new(0.5, 0.5)
	balance.Size = UDim2.fromOffset(210, 28)
	balance.TextColor3 = COLOR_TEXT_DIM
	balance.Text = "ADD ITEMS TO COMPARE"
	balance.ZIndex = 6
	balance.Parent = content
	makeRound(balance, 14)

	-- §3.3 value-warning interstitial: covers the offers until explicitly
	-- acknowledged; READY stays disabled while it is armed.
	local warning = Instance.new("Frame")
	warning.Name = "ValueWarning"
	warning.Size = UDim2.fromScale(1, 1)
	warning.BackgroundColor3 = COLOR_SCRIM
	warning.BackgroundTransparency = 0.25
	warning.BorderSizePixel = 0
	warning.Visible = false
	warning.ZIndex = 8
	warning.Parent = content

	local warningCard = Instance.new("Frame")
	warningCard.Name = "Card"
	warningCard.AnchorPoint = Vector2.new(0.5, 0.5)
	warningCard.Position = UDim2.fromScale(0.5, 0.5)
	warningCard.Size = UDim2.fromOffset(312, 196)
	warningCard.BackgroundColor3 = COLOR_PANEL
	warningCard.BorderSizePixel = 0
	warningCard.ZIndex = 9
	warningCard.Parent = warning
	makeRound(warningCard, 16)
	local warningStroke = Instance.new("UIStroke")
	warningStroke.Color = COLOR_WARN
	warningStroke.Thickness = 2.5
	warningStroke.Transparency = 0.1
	warningStroke.Parent = warningCard

	local warningTitle = makeLabel("Title", 18, true)
	warningTitle.Position = UDim2.fromOffset(16, 14)
	warningTitle.Size = UDim2.new(1, -32, 0, 24)
	warningTitle.TextColor3 = COLOR_WARN
	warningTitle.Text = "! ONE-SIDED TRADE !"
	warningTitle.ZIndex = 10
	warningTitle.Parent = warningCard

	local warningBody = makeLabel("Body", 15, true)
	warningBody.Position = UDim2.fromOffset(16, 46)
	warningBody.Size = UDim2.new(1, -32, 0, 64)
	warningBody.TextWrapped = true
	warningBody.Text = "This trade is heavily one-sided against you. Are you sure?"
	warningBody.ZIndex = 10
	warningBody.Parent = warningCard

	local warningAck = makeButton("Ack", "I UNDERSTAND — CONTINUE ANYWAY", COLOR_WARN, COLOR_TEXT)
	warningAck.Position = UDim2.new(0, 16, 1, -(BUTTON_HEIGHT_PX + 14))
	warningAck.Size = UDim2.new(1, -32, 0, BUTTON_HEIGHT_PX)
	warningAck.TextSize = 14
	warningAck.ZIndex = 10
	warningAck.Parent = warningCard
	makeRound(warningAck, 12)

	-- Persistent reminder strip once acked (the warning never fully disappears).
	local warningStrip = makeLabel("WarningStrip", 12, true)
	warningStrip.BackgroundTransparency = 0
	warningStrip.BackgroundColor3 = COLOR_WARN
	warningStrip.AnchorPoint = Vector2.new(0.5, 1)
	warningStrip.Position = UDim2.new(0.5, 0, 1, -2)
	warningStrip.Size = UDim2.new(1, -8, 0, 22)
	warningStrip.Text = "! one-sided against you"
	warningStrip.Visible = false
	warningStrip.ZIndex = 7
	warningStrip.Parent = content
	makeRound(warningStrip, 11)

	-- Bottom action bar: CANCEL / ADD ITEMS / READY (one-thumb).
	local bottomBar = Instance.new("Frame")
	bottomBar.Name = "BottomBar"
	bottomBar.AnchorPoint = Vector2.new(0, 1)
	bottomBar.Position = UDim2.new(0, 10, 1, -10)
	bottomBar.Size = UDim2.new(1, -20, 0, BUTTON_HEIGHT_PX)
	bottomBar.BackgroundTransparency = 1
	bottomBar.ZIndex = 3
	bottomBar.Parent = nego

	local cancelButton = makeButton("Cancel", "CANCEL", COLOR_PANEL_RAISED, COLOR_TEXT_DIM)
	cancelButton.Size = UDim2.new(0.24, -4, 1, 0)
	cancelButton.TextSize = 14
	cancelButton.ZIndex = 4
	cancelButton.Parent = bottomBar
	makeRound(cancelButton, 12)

	local addButton = makeButton("AddItems", "+ ADD ITEMS", COLOR_PANEL_RAISED, COLOR_TEXT)
	addButton.Position = UDim2.new(0.24, 4, 0, 0)
	addButton.Size = UDim2.new(0.33, -8, 1, 0)
	addButton.TextSize = 14
	addButton.ZIndex = 4
	addButton.Parent = bottomBar
	makeRound(addButton, 12)

	local readyButton = makeButton("Ready", "READY", COLOR_ACCENT, COLOR_PANEL)
	readyButton.Position = UDim2.new(0.57, 4, 0, 0)
	readyButton.Size = UDim2.new(0.43, -4, 1, 0)
	readyButton.ZIndex = 4
	readyButton.Parent = bottomBar
	makeRound(readyButton, 12)

	----------------------------------------------------------------------------
	-- Inventory picker bottom sheet (over the negotiation screen)
	----------------------------------------------------------------------------
	local pickerScrim = makeButton("PickerScrim", "", COLOR_SCRIM, COLOR_TEXT)
	pickerScrim.AutoButtonColor = false
	pickerScrim.Size = UDim2.fromScale(1, 1)
	pickerScrim.BackgroundTransparency = 0.45
	pickerScrim.Visible = false
	pickerScrim.ZIndex = 14
	pickerScrim.Parent = gui

	local pickerSheet = Instance.new("Frame")
	pickerSheet.Name = "PickerSheet"
	pickerSheet.AnchorPoint = Vector2.new(0.5, 1)
	pickerSheet.Position = UDim2.fromScale(0.5, 1)
	pickerSheet.Size = UDim2.fromScale(1, 0.62)
	pickerSheet.BackgroundColor3 = COLOR_PANEL
	pickerSheet.BorderSizePixel = 0
	pickerSheet.Visible = false
	pickerSheet.ZIndex = 15
	pickerSheet.Parent = gui
	makeRound(pickerSheet, 18)
	local pickerCap = Instance.new("UISizeConstraint")
	pickerCap.MaxSize = Vector2.new(720, math.huge)
	pickerCap.Parent = pickerSheet
	local pickerPadding = Instance.new("UIPadding")
	pickerPadding.PaddingLeft = UDim.new(0, 12)
	pickerPadding.PaddingRight = UDim.new(0, 12)
	pickerPadding.PaddingTop = UDim.new(0, 10)
	pickerPadding.PaddingBottom = UDim.new(0, 10)
	pickerPadding.Parent = pickerSheet

	local pickerTitle = makeLabel("Title", 16, true)
	pickerTitle.Position = UDim2.fromOffset(2, 2)
	pickerTitle.Size = UDim2.new(1, -64, 0, 20)
	pickerTitle.TextXAlignment = Enum.TextXAlignment.Left
	pickerTitle.Text = "ADD TO YOUR OFFER"
	pickerTitle.ZIndex = 16
	pickerTitle.Parent = pickerSheet

	local pickerDone = makeButton("Done", "DONE", COLOR_ACCENT, COLOR_PANEL)
	pickerDone.AnchorPoint = Vector2.new(1, 0)
	pickerDone.Position = UDim2.fromScale(1, 0)
	pickerDone.Size = UDim2.fromOffset(76, MIN_TOUCH_PX)
	pickerDone.TextSize = 14
	pickerDone.ZIndex = 16
	pickerDone.Parent = pickerSheet
	makeRound(pickerDone, 12)

	local pickerTabRow = Instance.new("Frame")
	pickerTabRow.Name = "TabRow"
	pickerTabRow.Position = UDim2.fromOffset(0, 30 + 8)
	pickerTabRow.Size = UDim2.new(1, 0, 0, TAB_HEIGHT_PX)
	pickerTabRow.BackgroundTransparency = 1
	pickerTabRow.ZIndex = 16
	pickerTabRow.Parent = pickerSheet
	local pickerTabLayout = Instance.new("UIListLayout")
	pickerTabLayout.FillDirection = Enum.FillDirection.Horizontal
	pickerTabLayout.Padding = UDim.new(0, 8)
	pickerTabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pickerTabLayout.Parent = pickerTabRow

	local function buildPickerTab(text: string, order: number): TextButton
		local tab = makeButton(`Tab{order}`, text, COLOR_PANEL_RAISED, COLOR_TEXT_DIM)
		tab.Size = UDim2.fromOffset(140, TAB_HEIGHT_PX)
		tab.TextSize = 14
		tab.LayoutOrder = order
		tab.ZIndex = 17
		tab.Parent = pickerTabRow
		makeRound(tab, 10)
		return tab
	end
	local tabCases = buildPickerTab("SEALED CASES", 1)
	local tabCryptlings = buildPickerTab("PETS", 2)

	local pickerGrid = Instance.new("ScrollingFrame")
	pickerGrid.Name = "Grid"
	pickerGrid.Position = UDim2.fromOffset(0, 38 + TAB_HEIGHT_PX + 16)
	pickerGrid.Size = UDim2.new(1, 0, 1, -(38 + TAB_HEIGHT_PX + 16))
	pickerGrid.BackgroundTransparency = 1
	pickerGrid.BorderSizePixel = 0
	pickerGrid.ScrollBarThickness = 6
	pickerGrid.ScrollBarImageColor3 = COLOR_METER_TRACK
	pickerGrid.ScrollingDirection = Enum.ScrollingDirection.Y
	pickerGrid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	pickerGrid.CanvasSize = UDim2.new()
	pickerGrid.ZIndex = 16
	pickerGrid.Parent = pickerSheet
	local pickerLayout = Instance.new("UIGridLayout")
	pickerLayout.CellSize = UDim2.fromOffset(PICK_CARD_WIDTH_PX, PICK_CARD_HEIGHT_PX)
	pickerLayout.CellPadding = UDim2.fromOffset(8, 8)
	pickerLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pickerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	pickerLayout.Parent = pickerGrid

	local pickerEmpty = makeLabel("Empty", 14, false)
	pickerEmpty.AnchorPoint = Vector2.new(0.5, 0)
	pickerEmpty.Position = UDim2.new(0.5, 0, 0, 28)
	pickerEmpty.Size = UDim2.new(1, -40, 0, 64)
	pickerEmpty.TextColor3 = COLOR_TEXT_DIM
	pickerEmpty.TextWrapped = true
	pickerEmpty.Visible = false
	pickerEmpty.ZIndex = 16
	pickerEmpty.Parent = pickerGrid

	----------------------------------------------------------------------------
	-- Stage-2 full-screen summary (distinct look: darker, gold-framed)
	----------------------------------------------------------------------------
	local summary = Instance.new("Frame")
	summary.Name = "Summary"
	summary.Size = UDim2.fromScale(1, 1)
	summary.BackgroundColor3 = COLOR_SCRIM
	summary.BorderSizePixel = 0
	summary.Visible = false
	summary.ZIndex = 20
	summary.Parent = gui

	local summaryTitle = makeLabel("Title", 22, true)
	summaryTitle.Position = UDim2.fromOffset(0, 14)
	summaryTitle.Size = UDim2.new(1, 0, 0, 26)
	summaryTitle.TextColor3 = COLOR_GOLD
	summaryTitle.Text = "FINAL CONFIRMATION"
	summaryTitle.ZIndex = 21
	summaryTitle.Parent = summary

	local summaryBanner = makeLabel("Banner", 15, true)
	summaryBanner.BackgroundTransparency = 0
	summaryBanner.BackgroundColor3 = COLOR_WARN
	summaryBanner.Position = UDim2.fromOffset(16, 46)
	summaryBanner.Size = UDim2.new(1, -32, 0, 34)
	summaryBanner.TextWrapped = true
	summaryBanner.Text = FINAL_WARNING_TEXT
	summaryBanner.ZIndex = 21
	summaryBanner.Parent = summary
	makeRound(summaryBanner, 10)

	local summaryContent = Instance.new("Frame")
	summaryContent.Name = "Content"
	summaryContent.Position = UDim2.fromOffset(12, 88)
	summaryContent.Size = UDim2.new(1, -24, 1, -(88 + RING_RADIUS_PX * 2 + 16 + BUTTON_HEIGHT_PX + 56))
	summaryContent.BackgroundTransparency = 1
	summaryContent.ZIndex = 21
	summaryContent.Parent = summary

	local function buildSummaryList(name: string, accent: Color3): any
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.BackgroundColor3 = COLOR_PANEL
		frame.BorderSizePixel = 0
		frame.ZIndex = 21
		frame.Parent = summaryContent
		makeRound(frame, 12)
		local stroke = Instance.new("UIStroke")
		stroke.Color = accent
		stroke.Thickness = 1.5
		stroke.Transparency = 0.4
		stroke.Parent = frame

		local title = makeLabel("Title", 15, true)
		title.Position = UDim2.fromOffset(10, 8)
		title.Size = UDim2.new(1, -20, 0, 20)
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = accent
		title.ZIndex = 22
		title.Parent = frame

		local list = Instance.new("ScrollingFrame")
		list.Name = "List"
		list.Position = UDim2.fromOffset(8, 32)
		list.Size = UDim2.new(1, -16, 1, -40)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.ScrollBarImageColor3 = COLOR_METER_TRACK
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.CanvasSize = UDim2.new()
		list.ZIndex = 22
		list.Parent = frame
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, 4)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = list

		return { root = frame, title = title, list = list }
	end

	local summaryGive = buildSummaryList("YouGive", COLOR_WARN)
	local summaryGet = buildSummaryList("YouGet", COLOR_ACCENT)

	-- Round ACCEPT button with a draining pip ring (3s lock).
	local acceptHolder = Instance.new("Frame")
	acceptHolder.Name = "AcceptHolder"
	acceptHolder.AnchorPoint = Vector2.new(0.5, 1)
	acceptHolder.Position = UDim2.new(0.5, 0, 1, -(BUTTON_HEIGHT_PX + 28))
	acceptHolder.Size = UDim2.fromOffset(RING_RADIUS_PX * 2 + 16, RING_RADIUS_PX * 2 + 16)
	acceptHolder.BackgroundTransparency = 1
	acceptHolder.ZIndex = 21
	acceptHolder.Parent = summary

	local acceptButton = makeButton("Accept", "ACCEPT", COLOR_PANEL_RAISED, COLOR_TEXT_DIM)
	acceptButton.AnchorPoint = Vector2.new(0.5, 0.5)
	acceptButton.Position = UDim2.fromScale(0.5, 0.5)
	acceptButton.Size = UDim2.fromOffset(ACCEPT_DIAMETER_PX, ACCEPT_DIAMETER_PX)
	acceptButton.TextSize = 15
	acceptButton.TextWrapped = true
	acceptButton.ZIndex = 23
	acceptButton.Parent = acceptHolder
	local acceptCorner = Instance.new("UICorner")
	acceptCorner.CornerRadius = UDim.new(1, 0)
	acceptCorner.Parent = acceptButton

	local ringPips: { Frame } = {}
	local holderCenter = RING_RADIUS_PX + 8
	for index = 1, RING_PIPS do
		local angle = (index - 1) / RING_PIPS * math.pi * 2 - math.pi / 2
		local pip = Instance.new("Frame")
		pip.Name = `RingPip{index}`
		pip.AnchorPoint = Vector2.new(0.5, 0.5)
		pip.Position = UDim2.fromOffset(
			holderCenter + math.floor(math.cos(angle) * RING_RADIUS_PX + 0.5),
			holderCenter + math.floor(math.sin(angle) * RING_RADIUS_PX + 0.5)
		)
		pip.Size = UDim2.fromOffset(8, 8)
		pip.BackgroundColor3 = COLOR_GOLD
		pip.BorderSizePixel = 0
		pip.ZIndex = 22
		pip.Parent = acceptHolder
		local pipCorner = Instance.new("UICorner")
		pipCorner.CornerRadius = UDim.new(1, 0)
		pipCorner.Parent = pip
		table.insert(ringPips, pip)
	end

	local backButton = makeButton("Back", "GO BACK", COLOR_PANEL_RAISED, COLOR_TEXT)
	backButton.AnchorPoint = Vector2.new(0.5, 1)
	backButton.Position = UDim2.new(0.5, 0, 1, -12)
	backButton.Size = UDim2.fromOffset(260, BUTTON_HEIGHT_PX)
	backButton.ZIndex = 21
	backButton.Parent = summary
	makeRound(backButton, 12)

	----------------------------------------------------------------------------
	-- OFFER CHANGED flash overlay (above everything but the toast)
	----------------------------------------------------------------------------
	local flash = Instance.new("Frame")
	flash.Name = "OfferChangedFlash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = COLOR_WARN
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Visible = false
	flash.ZIndex = 40
	flash.Parent = gui

	local flashLabel = makeLabel("Text", 34, true)
	flashLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	flashLabel.Position = UDim2.fromScale(0.5, 0.5)
	flashLabel.Size = UDim2.new(1, -40, 0, 60)
	flashLabel.Text = "OFFER CHANGED"
	flashLabel.ZIndex = 41
	flashLabel.Parent = flash

	local flashScale = Instance.new("UIScale")
	flashScale.Scale = 1
	flashScale.Parent = flashLabel

	trade = {
		modalScrim = modalScrim,
		inviteCard = inviteCard,
		inviteTitle = inviteTitle,
		inviteBody = inviteBody,
		inviteDrain = inviteDrain,
		inviteAccept = inviteAccept,
		inviteDecline = inviteDecline,
		waitingCard = waitingCard,
		waitingTitle = waitingTitle,
		waitingDrain = waitingDrain,
		waitingCancel = waitingCancel,
		nego = nego,
		negoTitle = negoTitle,
		negoClose = negoClose,
		content = content,
		paneMine = paneMine,
		paneTheirs = paneTheirs,
		balance = balance,
		warning = warning,
		warningAck = warningAck,
		warningStrip = warningStrip,
		cancelButton = cancelButton,
		addButton = addButton,
		readyButton = readyButton,
		pickerScrim = pickerScrim,
		pickerSheet = pickerSheet,
		tabCases = tabCases,
		tabCryptlings = tabCryptlings,
		pickerGrid = pickerGrid,
		pickerEmpty = pickerEmpty,
		pickerDone = pickerDone,
		summary = summary,
		summaryGive = summaryGive,
		summaryGet = summaryGet,
		acceptButton = acceptButton,
		ringPips = ringPips,
		backButton = backButton,
		flash = flash,
		flashScale = flashScale,
	}
end

--------------------------------------------------------------------------------
-- Orientation layout: stacked panes portrait, side-by-side landscape (§3.2)
--------------------------------------------------------------------------------

local function applyOrientation()
	if trade == nil then
		return
	end
	local portrait = isPortrait()
	local theirsPane: Frame = trade.paneTheirs.root
	local minePane: Frame = trade.paneMine.root
	local balance: TextLabel = trade.balance
	if portrait then
		theirsPane.Position = UDim2.new(0, 0, 0, 0)
		theirsPane.Size = UDim2.new(1, 0, 0.5, -20)
		minePane.Position = UDim2.new(0, 0, 0.5, 20)
		minePane.Size = UDim2.new(1, 0, 0.5, -20)
		balance.Position = UDim2.fromScale(0.5, 0.5)
	else
		minePane.Position = UDim2.new(0, 0, 0, 0)
		minePane.Size = UDim2.new(0.5, -6, 1, 0)
		theirsPane.Position = UDim2.new(0.5, 6, 0, 0)
		theirsPane.Size = UDim2.new(0.5, -6, 1, 0)
		balance.Position = UDim2.fromScale(0.5, 0.06)
	end

	-- Summary lists follow the same orientation.
	local give: Frame = trade.summaryGive.root
	local get: Frame = trade.summaryGet.root
	if portrait then
		give.Position = UDim2.new(0, 0, 0, 0)
		give.Size = UDim2.new(1, 0, 0.5, -4)
		get.Position = UDim2.new(0, 0, 0.5, 4)
		get.Size = UDim2.new(1, 0, 0.5, -4)
	else
		give.Position = UDim2.new(0, 0, 0, 0)
		give.Size = UDim2.new(0.5, -6, 1, 0)
		get.Position = UDim2.new(0.5, 6, 0, 0)
		get.Size = UDim2.new(0.5, -6, 1, 0)
	end
end

--------------------------------------------------------------------------------
-- Negotiation rendering
--------------------------------------------------------------------------------

local function caseCardSpec(uid: string, tier: number?, order: number, onTap: (() -> ())?): CardSpec
	return {
		name = `Case_{uid}`,
		title = if tier ~= nil then `TIER {tier} CASE` else "SEALED CASE",
		subtitle = "sealed",
		color = tierColor(tier),
		count = nil,
		dupe = false,
		order = order,
		onTap = onTap,
	}
end

local function cryptlingCardSpec(id: string, count: number, dupe: boolean, order: number, onTap: (() -> ())?): CardSpec
	local def = RarityTable.GetCryptling(id)
	local displayName = if type(def) == "table" then def.name else id
	local rarity = if type(def) == "table" then def.rarity else nil
	return {
		name = `Cryptling_{id}`,
		title = displayName,
		subtitle = rarity,
		color = rarityColor(rarity),
		count = count,
		dupe = dupe,
		order = order,
		onTap = onTap,
	}
end

-- Sort cryptling ids rarest-first for stable, readable grids.
local RARITY_RANK: { [string]: number } = {}
for index, rarity in RarityTable.RARITY_ORDER :: { string } do
	RARITY_RANK[rarity] = index
end

local function sortedCryptlingIds(map: { [string]: number }): { string }
	local ids: { string } = {}
	for id in map do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local defA = RarityTable.GetCryptling(a)
		local defB = RarityTable.GetCryptling(b)
		local rankA = if type(defA) == "table" then RARITY_RANK[defA.rarity] or 0 else 0
		local rankB = if type(defB) == "table" then RARITY_RANK[defB.rarity] or 0 else 0
		if rankA ~= rankB then
			return rankA > rankB
		end
		return a < b
	end)
	return ids
end

local function renderOfferGrid(pane: any, offer: NormalizedOffer, ownedCounts: { [string]: number }?, mineSide: boolean)
	clearGrid(pane.grid)
	local order = 0

	for _, uid in offer.caseUids do
		order += 1
		local tier = offer.caseTiers[uid]
		local onTap: (() -> ())? = nil
		if mineSide then
			onTap = function()
				removeCaseFromOffer(uid)
				rebuildNegotiation()
				rebuildPicker()
			end
		end
		buildItemCard(pane.grid, caseCardSpec(uid, tier, order, onTap))
	end

	for _, id in sortedCryptlingIds(offer.cryptlings) do
		order += 1
		local count = offer.cryptlings[id]
		local dupe: boolean
		if mineSide then
			local owned = if ownedCounts ~= nil then ownedCounts[id] or 0 else 0
			dupe = owned >= 2
		else
			dupe = count >= 2
		end
		local onTap: (() -> ())? = nil
		if mineSide then
			onTap = function()
				removeCryptlingFromOffer(id)
				rebuildNegotiation()
				rebuildPicker()
			end
		end
		buildItemCard(pane.grid, cryptlingCardSpec(id, count, dupe, order, onTap))
	end

	if order == 0 then
		pane.empty.Text = if mineSide
			then "Nothing offered — tap ADD ITEMS below."
			else "They haven't offered anything yet."
		pane.empty.Visible = true
	else
		pane.empty.Visible = false
	end
end

local function pendingAsOffer(): NormalizedOffer
	local offer: NormalizedOffer = {
		caseUids = table.clone(pendingOffer.caseUids),
		caseTiers = {},
		cryptlings = table.clone(pendingOffer.cryptlings),
		confirmStage = if lastNormalized ~= nil then lastNormalized.mine.confirmStage else 0,
	}
	for _, uid in offer.caseUids do
		local stub = lockerCaseByUid[uid]
		if stub ~= nil then
			offer.caseTiers[uid] = stub.tier
		end
	end
	return offer
end

-- Fingerprint of the CURRENT trade for the warning ack (local pending + their
-- authoritative side, so any change on either side re-arms the interstitial).
local function currentWarningFingerprint(): string
	local theirs = if lastNormalized ~= nil then offerFingerprint(lastNormalized.theirs) else ""
	return `{offerFingerprint(pendingAsOffer())}::{theirs}`
end

local function warningArmed(): boolean
	local normalized = lastNormalized
	if normalized == nil or not (normalized.valueWarning and normalized.warningAgainstMe) then
		return false
	end
	return warningAckFingerprint ~= currentWarningFingerprint()
end

rebuildNegotiation = function()
	if trade == nil then
		return
	end
	local normalized = lastNormalized
	local mineOffer = pendingAsOffer()
	local theirsOffer: NormalizedOffer = if normalized ~= nil
		then normalized.theirs
		else { caseUids = {}, caseTiers = {}, cryptlings = {}, confirmStage = 0 }

	trade.negoTitle.Text = `SWAP MEET — trading with {partnerName()}`
	trade.paneTheirs.title.Text = `THEIR OFFER — {partnerName()}`

	local ownedCounts = getOwnedCollection()
	renderOfferGrid(trade.paneMine, mineOffer, ownedCounts, true)
	renderOfferGrid(trade.paneTheirs, theirsOffer, nil, false)

	-- Value meters + balance verdict.
	local myValue = computeOfferValue(mineOffer)
	local theirValue: number? = nil
	if normalized ~= nil then
		theirValue = if normalized.theirValue ~= nil then normalized.theirValue else computeOfferValue(theirsOffer)
		if myValue == nil then
			myValue = normalized.myValue
		end
	end
	local maxValue = math.max(myValue or 0, theirValue or 0, 1)
	trade.paneMine.meterFill.Size = UDim2.fromScale(math.clamp((myValue or 0) / maxValue, 0, 1), 1)
	trade.paneTheirs.meterFill.Size = UDim2.fromScale(math.clamp((theirValue or 0) / maxValue, 0, 1), 1)
	trade.paneMine.meterValue.Text = if myValue ~= nil then `= {math.floor(myValue + 0.5)}` else "—"
	trade.paneTheirs.meterValue.Text = if theirValue ~= nil then `= {math.floor(theirValue + 0.5)}` else "—"

	local balance: TextLabel = trade.balance
	if myValue ~= nil and theirValue ~= nil then
		local total = myValue + theirValue
		local delta = theirValue - myValue
		if total <= 0 then
			balance.Text = "ADD ITEMS TO COMPARE"
			balance.TextColor3 = COLOR_TEXT_DIM
		elseif math.abs(delta) <= total * BALANCED_BAND then
			balance.Text = "BALANCED"
			balance.TextColor3 = COLOR_ACCENT
		elseif delta > 0 then
			balance.Text = "IN YOUR FAVOR ^"
			balance.TextColor3 = COLOR_ACCENT
		else
			balance.Text = "v AGAINST YOU"
			balance.TextColor3 = COLOR_WARN
		end
	else
		balance.Text = "VALUE METER SYNCING..."
		balance.TextColor3 = COLOR_TEXT_DIM
	end

	-- Ready chips.
	local myStage = if normalized ~= nil then normalized.mine.confirmStage else 0
	local theirStage = theirsOffer.confirmStage
	local mineReady: TextLabel = trade.paneMine.ready
	local theirsReady: TextLabel = trade.paneTheirs.ready
	mineReady.Text = if myStage >= 1 then "READY +" else "NOT READY"
	mineReady.TextColor3 = if myStage >= 1 then COLOR_ACCENT else COLOR_TEXT_DIM
	theirsReady.Text = if theirStage >= 1 then "READY +" else "NOT READY"
	theirsReady.TextColor3 = if theirStage >= 1 then COLOR_ACCENT else COLOR_TEXT_DIM

	-- §3.3 warning interstitial + persistent strip.
	local armed = warningArmed()
	trade.warning.Visible = armed
	local warningActive = normalized ~= nil and normalized.valueWarning and normalized.warningAgainstMe
	trade.warningStrip.Visible = warningActive and not armed

	-- READY button state machine.
	local readyButton: TextButton = trade.readyButton
	if armed then
		readyButton.Text = "REVIEW WARNING FIRST"
		readyButton.BackgroundColor3 = COLOR_PANEL_RAISED
		readyButton.TextColor3 = COLOR_TEXT_DIM
		readyButton.TextSize = 13
	elseif myStage >= 1 then
		readyButton.Text = if theirStage >= 1 then "BOTH READY" else "WAITING... TAP TO UNREADY"
		readyButton.BackgroundColor3 = COLOR_AMBER
		readyButton.TextColor3 = COLOR_PANEL
		readyButton.TextSize = 13
	else
		readyButton.Text = "READY"
		readyButton.BackgroundColor3 = COLOR_ACCENT
		readyButton.TextColor3 = COLOR_PANEL
		readyButton.TextSize = 16
	end
end

--------------------------------------------------------------------------------
-- Inventory picker rendering
--------------------------------------------------------------------------------

local function restylePickerTabs()
	if trade == nil then
		return
	end
	local function style(tab: TextButton, selected: boolean)
		tab.BackgroundColor3 = if selected then COLOR_ACCENT else COLOR_PANEL_RAISED
		tab.TextColor3 = if selected then COLOR_PANEL else COLOR_TEXT_DIM
	end
	style(trade.tabCases, activePickerTab == "Cases")
	style(trade.tabCryptlings, activePickerTab == "Cryptlings")
end

rebuildPicker = function()
	if trade == nil or not trade.pickerSheet.Visible then
		return
	end
	restylePickerTabs()
	local grid: ScrollingFrame = trade.pickerGrid
	clearGrid(grid)
	local empty: TextLabel = trade.pickerEmpty
	local order = 0

	if activePickerTab == "Cases" then
		for _, stub in lockerCases do
			if not isCaseOffered(stub.uid) then
				order += 1
				local uid = stub.uid
				buildItemCard(grid, {
					name = `Pick_{uid}`,
					title = `TIER {stub.tier} CASE`,
					subtitle = "tap to add",
					color = tierColor(stub.tier),
					count = nil,
					dupe = false,
					order = order,
					onTap = function()
						addCaseToOffer(uid)
						rebuildNegotiation()
						rebuildPicker()
					end,
				})
			end
		end
		if order == 0 then
			empty.Text = if #lockerCases == 0
				then "No sealed cases in your locker."
				else "All your sealed cases are already in the offer."
			empty.Visible = true
		else
			empty.Visible = false
		end
	else
		local ownedCounts = getOwnedCollection()
		if ownedCounts == nil then
			empty.Text = "Collection sync unavailable right now — you can still trade sealed cases."
			empty.Visible = true
			return
		end
		-- Roster order (rarity-grouped in RarityTable); non-tradeables hidden.
		for _, def in RarityTable.CRYPTLINGS :: { any } do
			local id = def.id
			if type(id) == "string" and isTradeable(id) then
				local owned = ownedCounts[id] or 0
				local available = owned - offeredCryptlingCount(id)
				if available > 0 then
					order += 1
					buildItemCard(grid, {
						name = `Pick_{id}`,
						title = def.name,
						subtitle = def.rarity,
						color = rarityColor(def.rarity),
						count = available,
						dupe = owned >= 2,
						order = order,
						onTap = function()
							addCryptlingToOffer(id, owned)
							rebuildNegotiation()
							rebuildPicker()
						end,
					})
				end
			end
		end
		if order == 0 then
			empty.Text = "No tradeable Pets left to add."
			empty.Visible = true
		else
			empty.Visible = false
		end
	end
end

local function openPicker()
	if trade == nil then
		return
	end
	fetchLockerCases()
	trade.pickerScrim.Visible = true
	trade.pickerSheet.Visible = true
	trade.pickerSheet.Position = UDim2.fromScale(0.5, 1.2)
	TweenService:Create(
		trade.pickerSheet,
		TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.fromScale(0.5, 1) }
	):Play()
	rebuildPicker()
end

local function closePicker()
	if trade ~= nil then
		trade.pickerScrim.Visible = false
		trade.pickerSheet.Visible = false
	end
end

--------------------------------------------------------------------------------
-- Stage-2 summary
--------------------------------------------------------------------------------

local function renderSummaryList(listRefs: any, offer: NormalizedOffer, titleText: string)
	listRefs.title.Text = titleText
	local list: ScrollingFrame = listRefs.list
	for _, child in list:GetChildren() do
		if child:IsA("Frame") and child.Name == "Row" then
			child:Destroy()
		end
	end

	local order = 0
	local function addRow(text: string, color: Color3, badge: string?)
		order += 1
		local row = Instance.new("Frame")
		row.Name = "Row"
		row.Size = UDim2.new(1, 0, 0, 40)
		row.BackgroundColor3 = COLOR_PANEL_RAISED
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.ZIndex = 22
		row.Parent = list
		makeRound(row, 8)

		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.Position = UDim2.fromOffset(8, 8)
		swatch.Size = UDim2.fromOffset(8, 24)
		swatch.BackgroundColor3 = color
		swatch.BorderSizePixel = 0
		swatch.ZIndex = 23
		swatch.Parent = row
		makeRound(swatch, 4)

		local label = makeLabel("Text", 16, true)
		label.Position = UDim2.fromOffset(24, 0)
		label.Size = UDim2.new(1, -90, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextTruncate = Enum.TextTruncate.AtEnd
		label.Text = text
		label.ZIndex = 23
		label.Parent = row

		if badge ~= nil then
			local badgeLabel = makeLabel("Badge", 11, true)
			badgeLabel.BackgroundTransparency = 0
			badgeLabel.BackgroundColor3 = COLOR_GOLD
			badgeLabel.TextColor3 = COLOR_PANEL
			badgeLabel.AnchorPoint = Vector2.new(1, 0.5)
			badgeLabel.Position = UDim2.new(1, -8, 0.5, 0)
			badgeLabel.Size = UDim2.fromOffset(48, 18)
			badgeLabel.Text = badge
			badgeLabel.ZIndex = 23
			badgeLabel.Parent = row
			makeRound(badgeLabel, 9)
		end
	end

	for _, uid in offer.caseUids do
		local tier = offer.caseTiers[uid]
		addRow(if tier ~= nil then `Tier {tier} sealed case` else "Sealed case", tierColor(tier), nil)
	end
	for _, id in sortedCryptlingIds(offer.cryptlings) do
		local count = offer.cryptlings[id]
		local def = RarityTable.GetCryptling(id)
		local displayName = if type(def) == "table" then def.name else id
		local rarity: string? = if type(def) == "table" then def.rarity else nil
		local text = if count > 1 then `{displayName}  x{count}` else displayName
		addRow(text, rarityColor(rarity), if count >= 2 then "DUPE" else nil)
	end
	if order == 0 then
		addRow("nothing", COLOR_TEXT_DIM, nil)
	end
end

local function startAcceptLock(token: number)
	if trade == nil then
		return
	end
	summaryArmed = false
	local acceptButton: TextButton = trade.acceptButton
	acceptButton.Active = false
	acceptButton.AutoButtonColor = false
	acceptButton.BackgroundColor3 = COLOR_PANEL_RAISED
	acceptButton.TextColor3 = COLOR_TEXT_DIM

	task.spawn(function()
		local startedAt = os.clock()
		while true do
			if trade == nil or token ~= sessionToken or not trade.summary.Visible then
				return
			end
			local elapsed = os.clock() - startedAt
			local remaining = STAGE2_LOCK_SECONDS - elapsed
			local fraction = math.clamp(remaining / STAGE2_LOCK_SECONDS, 0, 1)
			local lit = math.ceil(fraction * RING_PIPS)
			for index, pip in trade.ringPips :: { Frame } do
				pip.BackgroundColor3 = if index <= lit then COLOR_GOLD else COLOR_METER_TRACK
			end
			acceptButton.Text = `ACCEPT\n({math.ceil(math.max(remaining, 0))})`
			if remaining <= 0 then
				break
			end
			task.wait(0.05)
		end
		-- Armed.
		summaryArmed = true
		for _, pip in trade.ringPips :: { Frame } do
			pip.BackgroundColor3 = COLOR_ACCENT
		end
		acceptButton.Active = true
		acceptButton.AutoButtonColor = true
		acceptButton.BackgroundColor3 = COLOR_ACCENT
		acceptButton.TextColor3 = COLOR_PANEL
		acceptButton.Text = "ACCEPT\nTRADE"
	end)
end

openSummary = function()
	if trade == nil or phase ~= "Negotiating" then
		return
	end
	local normalized = lastNormalized
	if normalized == nil then
		return
	end
	phase = "Summary"
	setCursorReleased(true)
	sessionToken += 1
	closePicker()
	applyOrientation()
	renderSummaryList(trade.summaryGive, normalized.mine, `YOU GIVE -> {partnerName()}`)
	renderSummaryList(trade.summaryGet, normalized.theirs, `YOU GET <- {partnerName()}`)
	trade.summary.Visible = true
	startAcceptLock(sessionToken)
end

closeSummary = function()
	if trade ~= nil then
		trade.summary.Visible = false
	end
	summaryArmed = false
	if phase == "Summary" then
		phase = "Negotiating"
	end
end

--------------------------------------------------------------------------------
-- OFFER CHANGED flash (loud: red wash + bouncing text + snap)
--------------------------------------------------------------------------------

local function playOfferChangedFlash()
	if trade == nil then
		return
	end
	local flash: Frame = trade.flash
	local scale: UIScale = trade.flashScale
	flash.Visible = true
	flash.BackgroundTransparency = 0.25
	scale.Scale = 0.4
	local snap: Sound = ui.snapSound
	snap:Play()
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Scale = 1.1 })
		:Play()
	TweenService:Create(
		flash,
		TweenInfo.new(FLASH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ BackgroundTransparency = 1 }
	):Play()
	task.delay(FLASH_SECONDS, function()
		if trade ~= nil then
			trade.flash.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------
-- Flow control
--------------------------------------------------------------------------------

local function hideModals()
	-- Only called from the resetToIdle funnel, so the trade flow is over and
	-- the cursor token must drop with the last trade surface (R4-2).
	setCursorReleased(false)
	if trade ~= nil then
		trade.modalScrim.Visible = false
		trade.inviteCard.Visible = false
		trade.waitingCard.Visible = false
		trade.nego.Visible = false
		trade.summary.Visible = false
		trade.warning.Visible = false
	end
	closePicker()
end

resetToIdle = function()
	sessionToken += 1
	setOfferToken += 1
	phase = "Idle"
	activeTradeId = nil
	partnerUserId = nil
	outgoingTargetUserId = nil
	lastNormalized = nil
	lastRawState = nil
	warningAckFingerprint = nil
	summaryArmed = false
	readyInFlight = false
	pendingOffer = { caseUids = {}, cryptlings = {} }
	hideModals()
	updateEntryAffordances()
end

local function openNegotiation()
	if trade == nil then
		return
	end
	phase = "Negotiating"
	setCursorReleased(true)
	trade.modalScrim.Visible = false
	trade.inviteCard.Visible = false
	trade.waitingCard.Visible = false
	trade.summary.Visible = false
	trade.nego.Visible = true
	applyOrientation()
	fetchLockerCases()
	rebuildNegotiation()
	updateEntryAffordances()
end

local function cancelActiveTrade(reasonToast: string?)
	local tradeId = activeTradeId
	if tradeId ~= nil then
		task.spawn(function()
			invoke("Trade.Cancel", INVOKE_TIMEOUT_SECONDS, tradeId)
		end)
	end
	if reasonToast ~= nil then
		showToast(reasonToast, COLOR_TEXT_DIM)
	end
	resetToIdle()
end

-- Invitee accept: opening the negotiation plus an explicit empty SetOffer —
-- the in-contract signal that the invite was taken (any SetOffer from the
-- invitee tells TradeService the trade is live).
local function acceptIncomingInvite()
	local tradeId = activeTradeId
	if tradeId == nil then
		resetToIdle()
		return
	end
	openNegotiation()
	task.spawn(function()
		invoke("Trade.SetOffer", INVOKE_TIMEOUT_SECONDS, tradeId, snapshotPendingOffer())
	end)
end

local function showIncomingInvite(inviterName: string)
	if trade == nil then
		return
	end
	phase = "IncomingInvite"
	setCursorReleased(true)
	sessionToken += 1
	local token = sessionToken
	trade.modalScrim.Visible = true
	trade.inviteCard.Visible = true
	trade.inviteTitle.Text = `{inviterName} wants to trade`
	trade.inviteBody.Text = "Swap-meet trade offer. Sealed cases and duplicate Pets only — trades are final."
	updateEntryAffordances()

	task.spawn(function()
		local startedAt = os.clock()
		while phase == "IncomingInvite" and token == sessionToken do
			local fraction = 1 - math.clamp((os.clock() - startedAt) / INVITE_TIMEOUT_SECONDS, 0, 1)
			trade.inviteDrain.Size = UDim2.fromScale(fraction, 1)
			if fraction <= 0 then
				-- Server timeout is authoritative; just dismiss the sheet.
				if phase == "IncomingInvite" and token == sessionToken then
					showToast("Trade offer expired", COLOR_TEXT_DIM)
					resetToIdle()
				end
				return
			end
			task.wait(0.1)
		end
	end)
end

local function showWaitingCard(targetName: string)
	if trade == nil then
		return
	end
	phase = "Inviting"
	setCursorReleased(true)
	sessionToken += 1
	local token = sessionToken
	trade.modalScrim.Visible = true
	trade.waitingCard.Visible = true
	trade.waitingTitle.Text = `Trade offer sent to {targetName} — waiting...`
	updateEntryAffordances()

	task.spawn(function()
		local startedAt = os.clock()
		while phase == "Inviting" and token == sessionToken do
			local fraction = 1 - math.clamp((os.clock() - startedAt) / INVITE_TIMEOUT_SECONDS, 0, 1)
			trade.waitingDrain.Size = UDim2.fromScale(fraction, 1)
			if fraction <= 0 then
				if phase == "Inviting" and token == sessionToken then
					showToast("No answer — invite expired", COLOR_TEXT_DIM)
					cancelActiveTrade(nil)
				end
				return
			end
			task.wait(0.1)
		end
	end)
end

--------------------------------------------------------------------------------
-- Ready / accept taps
--------------------------------------------------------------------------------

local function onReadyTapped()
	local normalized = lastNormalized
	local tradeId = activeTradeId
	if tradeId == nil or readyInFlight then
		return
	end
	if warningArmed() then
		-- The interstitial is the only way through (§3.3).
		if trade ~= nil then
			trade.warning.Visible = true
		end
		return
	end
	local myStage = if normalized ~= nil then normalized.mine.confirmStage else 0
	readyInFlight = true
	task.spawn(function()
		if myStage >= 1 then
			requestUnready()
		else
			local response = invoke("Trade.Confirm", INVOKE_TIMEOUT_SECONDS, tradeId, 1)
			if type(response) ~= "table" or response.ok ~= true then
				local err = if type(response) == "table" and type(response.err) == "string"
					then response.err
					else "try again"
				showToast(`Couldn't ready up — {err}`, COLOR_WARN)
			end
		end
		readyInFlight = false
	end)
end

local function onAcceptTapped()
	local tradeId = activeTradeId
	if tradeId == nil or not summaryArmed or readyInFlight then
		return
	end
	readyInFlight = true
	task.spawn(function()
		local response = invoke("Trade.Confirm", INVOKE_TIMEOUT_SECONDS, tradeId, 2)
		readyInFlight = false
		if type(response) ~= "table" or response.ok ~= true then
			local err = if type(response) == "table" and type(response.err) == "string"
				then response.err
				else "try again"
			showToast(`Couldn't accept — {err}`, COLOR_WARN)
		end
		-- Completed event drives the celebration; nothing optimistic here.
	end)
end

--------------------------------------------------------------------------------
-- TradeEvent handling
--------------------------------------------------------------------------------

local function applyNormalized(normalized: NormalizedTrade)
	lastNormalized = normalized
	partnerUserId = normalized.partnerUserId
	-- Server echo is authoritative for my own offer.
	pendingOffer.caseUids = table.clone(normalized.mine.caseUids)
	pendingOffer.cryptlings = table.clone(normalized.mine.cryptlings)
end

local function handleInvited(payload: any)
	buildTradeGui()
	local tradeId = payload.tradeId
	if type(tradeId) ~= "string" then
		return
	end

	if outgoingTargetUserId ~= nil and (phase == "Inviting" or phase == "Idle") then
		-- Initiator side: bind the tradeId, keep waiting for the accept.
		activeTradeId = tradeId
		local normalized = normalizeTrade(payload.state)
		if normalized ~= nil then
			lastRawState = payload.state
			applyNormalized(normalized)
		end
		return
	end

	if phase ~= "Idle" then
		return -- already busy; the server times this invite out
	end

	activeTradeId = tradeId
	lastRawState = payload.state
	local normalized = normalizeTrade(payload.state)
	local inviterName = "Someone"
	if normalized ~= nil then
		applyNormalized(normalized)
		inviterName = partnerName()
	end
	showIncomingInvite(inviterName)
end

local function handleUpdated(payload: any)
	local previous = lastNormalized
	local normalized = normalizeTrade(payload.state)
	if normalized == nil then
		return
	end
	lastRawState = payload.state

	local wasReadied = previous ~= nil and previous.mine.confirmStage >= 1
	local wasSummary = phase == "Summary"
	local theirsChanged = previous ~= nil and offerFingerprint(previous.theirs) ~= offerFingerprint(normalized.theirs)

	applyNormalized(normalized)

	if phase == "Inviting" then
		-- First Updated = the invitee accepted; negotiation begins.
		openNegotiation()
		showToast(`{partnerName()} accepted — build your offer`, COLOR_ACCENT)
		return
	end

	if phase == "IncomingInvite" then
		-- State moved while the sheet was up (e.g. inviter pre-loaded an offer);
		-- keep the sheet, just remember the state.
		return
	end

	if phase ~= "Negotiating" and phase ~= "Summary" then
		return
	end

	-- Mid-flow partner change: loud flash + bounce back with confirms reset.
	if theirsChanged and (wasReadied or wasSummary) then
		closeSummary()
		phase = "Negotiating"
		playOfferChangedFlash()
		showToast("Offer changed — confirms reset", COLOR_WARN)
	elseif wasSummary then
		-- My own un-ready echo while on the summary: quiet return.
		closeSummary()
	end

	rebuildNegotiation()
	rebuildPicker()
end

local function handleConfirmStage(payload: any)
	local normalized = normalizeTrade(payload.state)
	if normalized == nil then
		return
	end
	lastRawState = payload.state
	applyNormalized(normalized)

	if phase == "Inviting" then
		openNegotiation()
		return
	end
	if phase ~= "Negotiating" and phase ~= "Summary" then
		return
	end

	local bothReady = normalized.mine.confirmStage >= 1 and normalized.theirs.confirmStage >= 1
	if bothReady and phase == "Negotiating" then
		openSummary()
	elseif not bothReady and phase == "Summary" then
		closeSummary()
		showToast("Confirms reset", COLOR_TEXT_DIM)
	end
	rebuildNegotiation()
end

local function handleCompleted()
	showToast(`TRADE COMPLETE! Enjoy your haul, {LocalPlayer.DisplayName}!`, COLOR_ACCENT)
	if trade ~= nil then
		-- Celebratory green wash (reuses the flash overlay, friendlier color).
		local flash: Frame = trade.flash
		local label: TextLabel = trade.flash:FindFirstChild("Text") :: TextLabel
		label.Text = "TRADE COMPLETE!"
		flash.BackgroundColor3 = COLOR_ACCENT
		playOfferChangedFlash()
		task.delay(FLASH_SECONDS, function()
			if trade ~= nil then
				label.Text = "OFFER CHANGED"
				flash.BackgroundColor3 = COLOR_WARN
			end
		end)
	end
	resetToIdle()
	fetchLockerCases() -- cases moved hands; refresh the cache for the next trade
end

local function handleCancelled(payload: any)
	local reason = if type(payload.reason) == "string" then payload.reason else "Trade cancelled"
	showToast(reason, COLOR_TEXT_DIM)
	resetToIdle()
end

local function onTradeEvent(payload: any)
	if type(payload) ~= "table" or type(payload.kind) ~= "string" then
		return
	end
	local kind = payload.kind

	if kind == "Invited" then
		handleInvited(payload)
		return
	end

	-- Everything else only matters for the trade we are in.
	if activeTradeId == nil or payload.tradeId ~= activeTradeId then
		return
	end
	buildTradeGui()

	if kind == "Updated" then
		handleUpdated(payload)
	elseif kind == "ConfirmStage" then
		handleConfirmStage(payload)
	elseif kind == "Completed" then
		handleCompleted()
	elseif kind == "Cancelled" then
		handleCancelled(payload)
	end
end

--------------------------------------------------------------------------------
-- Entry point 1: client-local "Offer Trade" prompt on other players (hub only)
--------------------------------------------------------------------------------

updateEntryAffordances = function()
	local available = phase == "Idle" and shiftStateName ~= "Active"
	for _, prompt in playerPrompts do
		prompt.Enabled = available
	end
	if ui ~= nil and not available then
		ui.banner.Visible = false
	end
end

local function attachPrompt(player: Player, root: BasePart)
	local old = playerPrompts[player]
	if old ~= nil then
		old:Destroy()
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OfferTradePrompt"
	prompt.ActionText = PROMPT_ACTION_TEXT
	prompt.ObjectText = player.DisplayName
	prompt.HoldDuration = 0 -- single tap on touch
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Enabled = phase == "Idle" and shiftStateName ~= "Active"
	prompt.Parent = root
	prompt.Triggered:Connect(function()
		TradeUI.OfferTrade(player.UserId)
	end)
	playerPrompts[player] = prompt
end

local function watchPlayer(player: Player)
	if player == LocalPlayer then
		return
	end
	local function onCharacter(character: Model)
		task.spawn(function()
			local root = character:WaitForChild("HumanoidRootPart", 10)
			if root ~= nil and root:IsA("BasePart") then
				attachPrompt(player, root)
			end
		end)
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character ~= nil then
		onCharacter(player.Character)
	end
end

--------------------------------------------------------------------------------
-- Entry point 2: facing TradePads at the swap meet
--------------------------------------------------------------------------------

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function isOnPad(root: BasePart, pad: BasePart): boolean
	local offset = root.Position - pad.Position
	return math.abs(offset.X) <= pad.Size.X / 2 + 1
		and math.abs(offset.Z) <= pad.Size.Z / 2 + 1
		and offset.Y >= PAD_Y_MIN
		and offset.Y <= PAD_Y_MAX
end

local function pollTradePads()
	padTargetUserId = nil
	if ui == nil then
		return
	end
	if phase ~= "Idle" or shiftStateName == "Active" then
		ui.banner.Visible = false
		return
	end
	local myRoot = rootOf(LocalPlayer)
	if myRoot == nil then
		ui.banner.Visible = false
		return
	end

	local pads = CollectionService:GetTagged(TAG_TRADE_PAD)
	local myPad: BasePart? = nil
	for _, instance in pads do
		if instance:IsA("BasePart") and isOnPad(myRoot, instance) then
			myPad = instance
			break
		end
	end
	if myPad == nil then
		ui.banner.Visible = false
		return
	end

	-- Someone standing on any OTHER pad is the facing partner.
	for _, player in Players:GetPlayers() do
		if player ~= LocalPlayer then
			local otherRoot = rootOf(player)
			if otherRoot ~= nil then
				for _, instance in pads do
					if instance:IsA("BasePart") and instance ~= myPad and isOnPad(otherRoot, instance) then
						padTargetUserId = player.UserId
						ui.banner.Text = `OFFER TRADE — {player.DisplayName}`
						ui.banner.Visible = true
						return
					end
				end
			end
		end
	end
	ui.banner.Visible = false
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function TradeUI.IsBusy(): boolean
	return phase ~= "Idle"
end

function TradeUI.Close()
	-- Belt-and-braces: cancelActiveTrade -> resetToIdle -> hideModals also
	-- releases; release is idempotent (token set, not a counter).
	setCursorReleased(false)
	if phase == "Idle" then
		return
	end
	cancelActiveTrade(nil)
end

function TradeUI.OfferTrade(targetUserId: number)
	if phase ~= "Idle" or shiftStateName == "Active" then
		return
	end
	if type(targetUserId) ~= "number" or targetUserId == LocalPlayer.UserId then
		return
	end
	buildTradeGui()
	outgoingTargetUserId = targetUserId
	local target = Players:GetPlayerByUserId(targetUserId)
	showWaitingCard(if target ~= nil then target.DisplayName else "player")
	fetchLockerCases()

	task.spawn(function()
		local response = invoke("Trade.Invite", INVOKE_TIMEOUT_SECONDS, targetUserId)
		if phase ~= "Inviting" then
			return -- declined/cancelled/expired while in flight
		end
		if type(response) == "table" and response.ok == true then
			if type(response.tradeId) == "string" then
				activeTradeId = response.tradeId
			end
			-- Stay on the waiting card until the first Updated (= accepted) or
			-- a Cancelled event / the 20s drain.
		else
			local err = if type(response) == "table" and type(response.err) == "string"
				then response.err
				else "couldn't reach them"
			showToast(`Trade invite failed — {err}`, COLOR_WARN)
			resetToIdle()
		end
	end)
end

--------------------------------------------------------------------------------
-- Server event handlers
--------------------------------------------------------------------------------

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	shiftStateName = payload.state
	if shiftStateName == "Active" and phase ~= "Idle" then
		-- No trading mid-run; the server cancels its side too.
		cancelActiveTrade("Shift started — trade cancelled")
	end
	updateEntryAffordances()
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function TradeUI:Init(registry: any)
	-- Connections only — no yields in Init (loader contract).
	registryRef = registry
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		local prompt = playerPrompts[player]
		if prompt ~= nil then
			prompt:Destroy()
			playerPrompts[player] = nil
		end
		-- Partner left mid-trade: the server cancels; drop the UI immediately.
		if partnerUserId ~= nil and player.UserId == partnerUserId and phase ~= "Idle" then
			showToast(`{player.DisplayName} left — trade cancelled`, COLOR_TEXT_DIM)
			resetToIdle()
		end
	end)
end

function TradeUI:Start()
	buildRootGui()
	refreshAfterLockerFetch = function()
		if phase == "Negotiating" or phase == "Summary" then
			rebuildNegotiation()
			rebuildPicker()
		end
	end

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Remotes.GetEvent("TradeEvent").OnClientEvent:Connect(onTradeEvent)
	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)

	-- Lazy gui wiring once built: connect on first build via polling Start-time
	-- construction instead — build now if a trade is somehow already pending is
	-- unnecessary; wire handlers right after the first buildTradeGui call.
	-- (buildTradeGui is idempotent; handlers attach below on demand.)
	local wired = false
	local function wireTradeHandlers()
		if wired or trade == nil then
			return
		end
		wired = true
		trade.inviteAccept.Activated:Connect(acceptIncomingInvite)
		trade.inviteDecline.Activated:Connect(function()
			cancelActiveTrade("Trade declined")
		end)
		trade.waitingCancel.Activated:Connect(function()
			cancelActiveTrade("Invite cancelled")
		end)
		trade.negoClose.Activated:Connect(function()
			cancelActiveTrade("Trade cancelled")
		end)
		trade.cancelButton.Activated:Connect(function()
			cancelActiveTrade("Trade cancelled")
		end)
		trade.addButton.Activated:Connect(openPicker)
		trade.readyButton.Activated:Connect(onReadyTapped)
		trade.warningAck.Activated:Connect(function()
			warningAckFingerprint = currentWarningFingerprint()
			rebuildNegotiation()
		end)
		trade.pickerScrim.Activated:Connect(closePicker)
		trade.pickerDone.Activated:Connect(closePicker)
		trade.tabCases.Activated:Connect(function()
			activePickerTab = "Cases"
			rebuildPicker()
		end)
		trade.tabCryptlings.Activated:Connect(function()
			activePickerTab = "Cryptlings"
			rebuildPicker()
		end)
		trade.acceptButton.Activated:Connect(onAcceptTapped)
		trade.backButton.Activated:Connect(function()
			-- Back = un-ready (identical re-SetOffer resets confirms server-side).
			closeSummary()
			requestUnready()
			rebuildNegotiation()
		end)
	end

	-- Wrap buildTradeGui so every code path that lazily builds also wires.
	local rawBuild = buildTradeGui
	buildTradeGui = function()
		rawBuild()
		wireTradeHandlers()
	end

	-- Orientation: re-layout on viewport changes (portrait <-> landscape).
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyOrientation)
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCamera = Workspace.CurrentCamera
		if newCamera ~= nil then
			newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyOrientation)
		end
	end)

	-- Swap-meet pad watcher.
	task.spawn(function()
		while true do
			local ok, err = pcall(pollTradePads)
			if not ok then
				warn(`[TradeUI] pad poll failed: {err}`)
			end
			task.wait(PAD_POLL_SECONDS)
		end
	end)
end

return TradeUI
