--!strict
-- CRYPTLINGS: NIGHT SHIFT — remote definitions of record (CONTRACTS v1 §B).
-- This is the ONLY place remotes are defined. NEVER create ad-hoc remotes.
-- Server: Remotes.InitServer() is called exactly once by init.server.luau.
-- Client: Remotes.Get(name) yields until the instance replicates.
--
-- R2 (Lobby SOP Addendum 1, AC-9): NO remote is removed or renamed by the R2
-- change set. ShiftState and PlayerDownedState gain an additive sessionId field
-- only; Queue.SetReady and Queue.Leave keep their names and validation rules with
-- re-documented metronome semantics (Addendum 1 Change 6). Name lists below are
-- unchanged from round 1.
--
-- R3 (Lobby SOP Addendum 2): NO remote is removed or renamed (standing
-- invariant). The change set is additive only: one new RemoteFunction,
-- Bike.SetActive (R3-5 lobby bicycle), documented below.
--
-- R4 (Lobby SOP Addendum 3): NO remote is removed or renamed (standing
-- invariant). The change set is additive only: one new RemoteEvent,
-- Admin.Reply (R4-1 admin command feedback), documented below.
--
-- Payload contracts (S->C unless noted):
--   RemoteEvents:
--     ShiftState          {state:"Intermission"|"Active"|"Complete", floorSeed:number?, shiftEndsAt:number?(unix), shiftId:string?,
--                          participant:boolean (per-player: whether THIS client is mid-run),
--                          sessionId:string? (R2 additive, Addendum 1 Change 6.6: the ShiftSession
--                          GUID; participants receive their OWN session's shiftEndsAt; clients
--                          defensively drop payloads whose sessionId mismatches their session)}
--     RequeueShift  (C->S){} -- squad re-queue vote (§3.2 co-play hook)
--     CaseEvent           {kind:"PickedUp"|"Dropped"|"Banked"|"Lost", caseUid:string, tier:1|2|3|4|5|6, holderUserId:number?}
--     NoiseMeter  (owner) {noise01:number, carriedCount:number, maxCarry:number}
--     PlayerDownedState   {userId:number, downed:boolean, position:{number}?,
--                          sessionId:string? (R2 additive, Addendum 1 Change 6.6)}
--                         DELIVERY (R2): per-session-roster FireClient ONLY — never
--                         FireAllClients. Downed/bleedout state must not leak across
--                         concurrent sessions (Security Review Scope §1); clients still
--                         defensively drop mismatched sessionIds
--     ExtractionResult    {extracted:boolean, bankedCaseUids:{string}, shiftPay:number, extractionCount:number} (owner)
--     RarePullBroadcast   {playerName:string, cryptlingId:string, rarity:string}
--                         (all in server; also cross-server via MessagingService topic "RarePull", pcall-wrapped)
--     LockerChanged(owner) Types.LockerState
--     TradeEvent  (both)  {kind:"Invited"|"Updated"|"ConfirmStage"|"Completed"|"Cancelled", tradeId:string, state:TradeState?}
--     OnboardingBeat(own) {beat:"ClockIn"|"ForemanLine"|"FirstCase"|"DefectFlyby"|"FirstExtraction"|"Done",
--                          text:string? (server-side subtitle copy, every beat),
--                          position:{number}? (FirstCase = case pos — may re-fire on beacon
--                          retarget; FirstExtraction = dock pos), freeOpens:number? (Done only)}
--     ShowWelcome (owner) {} -- R7 Fix #1: first-ever lobby welcome panel. Copy is
--                          client-side (GameConstants.WELCOME). Server fires at most
--                          once per account: on profile load, if onboarding.welcomeShown
--                          == false AND stats.firstShiftDone == false, it grants the
--                          guaranteed-rare starter case FIRST (idempotent via
--                          onboarding.starterCaseGranted), sets welcomeShown = true,
--                          THEN FireClient. Empty payload for forward-compat.
--     StarterGuide(owner) {beat:string?} -- R7 Fix #4: OPTIONAL additive beat channel
--                          for the chained starter-case guide (open case -> podium ->
--                          equip -> clock-in). The client step machine can run purely
--                          on existing detection signals (LockerChanged, the unbox
--                          reveal, ShelfChanged, Pet.GetState) + GameConstants.STARTER_GUIDE
--                          subtitles; this remote is available if a lane prefers
--                          server-pushed beats. No server completion ack is required —
--                          grant-once + welcomeShown is the once-ever gate.
--     IntroBeat   (owner) {beat:string, data:{boxesNeeded:number?, boxesGot:number?}?}
--                          R9 (intro floor): S->C OWNER-ONLY step channel for the
--                          brand-new-account intro floor. The intro runner FIRES the
--                          beats ("enter"|"grabbed"|"chaseTelegraph"|"chaseStart"|
--                          "reachExit"|"done") and the intro guide UI CONSUMES them
--                          (copy is client-side, GameConstants.INTRO). data carries the
--                          box counts on "grabbed" (boxesGot/boxesNeeded). Never
--                          FireAllClients (the intro floor is per-player).
--     StarterPackOffer    {expiresAt:number} (owner)
--     ShopGrant   (owner) {sku:string, summary:string}
--     CountdownSync (all, every 30s) {toyLineEndsAt:number, nightlyRotationAt:number}
--     ShelfChanged (all)  {ownerUserId:number, slots:{[slotId:string]:string?}}
--     QueueState   (all)  {state:"Counting"|"DoorsClosing"|"Dispatch" (R2 metronome billboard
--                          states, Addendum 1 Change 6.1.7 — the pre-R2 Idle/Locked/Launching/
--                          Cooldown names retired with the QueueCore FSM at the Wave-5 cutover;
--                          "Counting" covers both IDLE-COUNTING and COUNTING-WITH-WORKERS,
--                          count distinguishes),
--                          endsAt:number (the next T=0 instant, workspace:GetServerTimeNow()
--                          based — clients tick the countdown locally, no per-second remote),
--                          count:number, capacity:number, rosterUserIds:{number}, readyUserIds:{number},
--                          afkUserIds:{number}? (R2 additive, one-shot: AFK-excluded this tick —
--                          the "Clocked out — inactive" toast),
--                          deferredUserIds:{number}? (R2 additive, one-shot: bin deferred on slot
--                          exhaustion — the "ALL FLOORS RUNNING" toast)}
--                         fired on every transition + 1 Hz while occupied (QueuePadService).
--                         SECURITY: payload carries userIds + counts ONLY — never another
--                         player's private data (Security Review Scope §1)
--     FunnelClient (C->S) {event:string, props:{[string]:any}?}
--     RespawnTimer (owner) {endsAt:number (workspace:GetServerTimeNow()-based deadline)}
--                         Fix #4 (respawn skip): fired by ShiftService when a
--                         server-owned post-death respawn timer is armed
--                         (CharacterAutoLoads is off; the server owns respawn).
--                         The client drives a countdown from
--                         endsAt - workspace:GetServerTimeNow() and shows a
--                         "RESPAWN NOW" button -> RequestRespawnNow. INVOKER-ONLY
--                         FireClient (the dead player only), never broadcast.
--                         server whitelists: client_spawn_ready, ui_open_shop, ui_open_locker, onboarding_ack
--     Admin.Reply (invoker) (text:string, isError:boolean) -- positional args, not a table
--                         R4-1 (Addendum 3): admin command feedback line. S->C,
--                         INVOKER-ONLY FireClient, fired EXCLUSIVELY by
--                         AdminCommands — never FireAllClients, and non-admins
--                         get zero feedback by design (no probing surface,
--                         R4 plan §5). This remote exists because
--                         TextChannel:DisplaySystemMessage is CLIENT-ONLY
--                         (server-side support was declined and has not shipped
--                         as of mid-2026), so the server cannot post system
--                         chat lines directly. AdminReplyUI (client) validates
--                         types (string/boolean), clamps to ~200 chars, escapes
--                         rich-text metacharacters (&<>), then renders via
--                         RBXGeneral:DisplaySystemMessage — green normal, red
--                         error. No C->S traffic on this remote ever.
--   RemoteFunctions (C->S):
--     RequestPickupCase(caseUid) -> {ok:boolean, err:string?}
--     RequestDropCase(caseUid) -> {ok}
--     RequestReviveTeammate(userId) -> {ok, err?}
--     RequestRespawnNow() -> {ok:boolean, err:string?("NO_PENDING_RESPAWN")}
--                         Fix #4 (respawn skip): skip the server-owned post-death
--                         respawn wait. Rejects NO_PENDING_RESPAWN when no timer
--                         is pending (anti-exploit: cannot be spammed to force a
--                         reload or dupe out of the downed/bleedout window).
--                         Takes no arguments. Owned by ShiftService.RespawnNow.
--     RequestOpenCase(caseUid) -> {ok, cryptlingId?, rarity?, isDuplicate?, opensRemaining?, err?("NO_OPENS"|"NOT_OWNED"|"BUSY")}
--                         opensRemaining = freeOpensRemaining + extraOpenCredits AFTER the call
--                         (LockerService total; LockerChanged remains the authoritative push)
--     GetLockerState() -> Types.LockerState
--     GetOddsTable(tier:1..6) -> {{rarity:string, pct:number}} -- EXACT values from RarityTable (§8.1)
--     Trade.Invite(targetUserId) -> {ok, tradeId?, err?}
--     Trade.SetOffer(tradeId, {caseUids:{string}, cryptlings:{[id:string]:number}}) -> {ok}
--     Trade.Confirm(tradeId, stage:1|2) -> {ok, err?} -- stage 2 valid only >=3s after BOTH stage-1
--     Trade.Cancel(tradeId) -> {ok}
--     Shelf.Place(slotId, cryptlingId) -> {ok, err?}
--     Shelf.Remove(slotId) -> {ok}
--     Shelf.GetAll() -> {{ownerUserId:number, slots:{[slotId:string]:string}}}
--                         -- one ShelfChanged-shaped snapshot per loaded owner in
--                         -- this server (late-join sync; pushes stay authoritative)
--     Queue.SetReady(ready:boolean) -> {ok:boolean} -- unanimous "start now" vote under the
--                         constant 45 s metronome (Addendum 1 Change 6.1.5): unanimous among
--                         current pad occupants (>=1 voter) + a free floor slot -> immediate
--                         EXTRA dispatch of that group; the vote NEVER moves the 45 s epoch;
--                         pending votes are cleared whenever a new player steps onto the pad.
--                         VALIDATION (fail-closed): arg must be EXACTLY a boolean — any other
--                         type/arity -> {ok=false} with zero side effects; honored only for
--                         current snapshot members; per-player rate limit <= 5 calls/10 s,
--                         enforced server-side (QueuePadService); handler never yields
--     Queue.Leave() -> {ok:boolean} -- step out of the current pad snapshot voluntarily
--                         (Addendum 1 Change 6.1.3): honored at ANY time, including the final
--                         3 s DOORS-CLOSING freeze — only late ENTRY locks at T-3; leaving
--                         NEVER moves the 45 s epoch (the metronome never pauses or resets).
--                         VALIDATION: zero-argument; extra args ignored; only snapshot members
--                         honored; same <= 5/10 s per-player rate limit
--     Shop.GetCatalog() -> {items:{Types.CatalogEntry}, randomRestricted:boolean}
--     Shop.RequestStarterPackPrompt() -> {ok}
--     Shop.PromptHousing() -> {ok:boolean, sku:string?, err:string?("AT_MAX"|"NOT_LOADED"|"NOT_WIRED")}
--                         TAKES NO ARGUMENTS BY DESIGN (SOP §5.1): the SERVER computes the next
--                         housing SKU from profile.housing.tier via HouseTransitions.NextCta and
--                         prompts only that product — no client SKU selection ever; anything the
--                         client passes is ignored/refused without side effects. Per-player
--                         prompt cooldown >= 3 s (MonetizationService); ProcessReceipt still
--                         re-validates requiresHousingTier at grant time (stale-prompt safe)
--     Consumable.Use(kind:"scentSpray"|"reviveBeacon"|"foremansKey"|"exitWarp") -> {ok, remaining:number, err?}
--     Shop.DevBuy(sku) -> {ok, err?} -- STUDIO ONLY: playtest purchase simulator (declines in production)
--     Combat.Attack(targetUserId) -> {ok, weapon:"shove"|"sword"|"paintball"|"gun"?, downed:boolean?, charges:number?, err?}
--                         fight-for-the-box: only lands when the TARGET carries a
--                         COMBAT_RARE_CASE_TIER case; weapon charges are consumables
--     Pet.Equip(cryptlingId:string) -> {ok:boolean, err:string?("BAD_ARG"|"NO_PROFILE"|"UNKNOWN_ID"|"NOT_OWNED")}
--                         "" unequips; otherwise equips an OWNED cryptling
--                         (profile.collection[id] > 0) as the follower pet
--     Pet.GetState() -> {equippedId:string ("" = none), upgradeLevel:number (0..PET_UPGRADE_MAX_LEVEL),
--                        ownedIds:{string} (cryptlingIds with collection count > 0, roster order),
--                        perk:{rarity:string, maxHealth:number, speedBonus:number, multiplier:number}?
--                        (nil while unequipped; numbers already upgrade-scaled — see
--                        Shared.Logic.PetPerks; speedBonus is advisory, §GameConstants.PET_PERKS)}
--     Bike.SetActive(active:boolean) -> {ok:boolean, active:boolean,
--                         err:string?("BAD_ARG"|"ON_SHIFT"|"OUT_OF_BOUNDS"|"DEAD"|"RATE_LIMIT")}
--                         R3-5 (Addendum 2): mount/dismount the cosmetic lobby bicycle.
--                         Owned by BikeService (server). VALIDATION (fail-closed): arg
--                         must be EXACTLY a boolean — any other type/arity -> {ok=false}
--                         with zero side effects. Server-side checks (BikeService):
--                         ShiftService.GetSessionOf(player) == nil (never on a shift),
--                         character alive, HumanoidRootPart within
--                         LobbyConfig.BIKE.LOBBY_RADIUS_STUDS of the hub spawn;
--                         per-player rate limit <= 5 calls/10 s sliding window;
--                         handler never yields.
--                         R3 WP2.3 audit notes: the DISMOUNT direction
--                         (active=false) is always honored and idempotent —
--                         never refused as ON_SHIFT/OUT_OF_BOUNDS/DEAD (mount
--                         is the only privileged direction). The rate limit
--                         applies to both directions of the REMOTE only;
--                         server-initiated ForceDismount paths (the dispatch
--                         pre-pivot hook in ShiftSession._start, the 0.5 s
--                         enforcement loop, death/seat/respawn/leave triggers)
--                         are never rate limited. Carry, queue-pad, trade-pad,
--                         and seated states are enforced by the 0.5 s loop
--                         rather than refused at grant time (grant checks stay
--                         session + alive + lobby radius, each fail-closed on
--                         a missing sibling).
--                         The "BikeActive" PLAYER ATTRIBUTE is a server-set
--                         display/speed mirror: set ONLY by BikeService and consumed by
--                         exactly the two WalkSpeed owners (CaseService.ApplyCarrySpeed
--                         and InputController.applyWalkSpeed — never a third writer,
--                         PetPerks rule). Clients cannot write server-set attributes,
--                         and NO server logic ever reads BikeActive as authorization or
--                         decision input — it is output state, not authority.
--                         R4 speed note: BIKE_SPEED_MULT is 2.2 (30.8 studs/s),
--                         deliberately ABOVE the shift validator cap of 27 — safe
--                         because the validator checks floor participants only and
--                         dispatch ForceDismounts pre-pivot; any future lobby
--                         validator must add a BikeActive allowance.
--     StarterGuide.TeleportToLot() -> {ok:boolean, err:string?}
--     StarterGuide.TeleportToClockIn() -> {ok:boolean, err:string?}
--                         R8 (Starter Guide SOP §3): the two SERVER-AUTHORITATIVE
--                         first-time-tutorial teleports. Owned by StarterGuideService
--                         (server); the CLIENT NEVER sets a CFrame — it only REQUESTS
--                         the teleport at the correct step and the server performs
--                         character:PivotTo (never TeleportService, never root.CFrame=).
--                         GATE (fail-closed, every invoke, inside PlayerDataService.WithLock):
--                         honored ONLY when onboarding.welcomeShown == true AND
--                         onboarding.starterGuideDone == false AND tutorialActive[player]
--                         AND the per-player step cursor matches (TeleportToLot only at
--                         cursor "lot"; TeleportToClockIn only at "clockIn"); else
--                         {ok=false, err="OUT_OF_STEP"} with ZERO side effects. Per-player
--                         rate limit <= 5 calls/10 s (Bike idiom) -> err="RATE", cleared on
--                         PlayerRemoving. TeleportToClockIn persists starterGuideDone = true
--                         after the successful pivot, so BOTH remotes go inert forever (no
--                         replay across rejoin/crash). MANDATORY anti-cheat hook on EACH
--                         pivot: RequestStreamAroundAsync (yields) runs BEFORE the pivot,
--                         then character:PivotTo, then SAME-THREAD with NO YIELD between
--                         them pcall(ShiftService.NoteServerTeleport, player) to re-seed the
--                         speed validator and pre-empt any future lobby validator snapback.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "Remotes"

local REMOTE_EVENT_NAMES = table.freeze({
	"ShiftState",
	"RequeueShift",
	"CaseEvent",
	"NoiseMeter",
	"PlayerDownedState",
	"ExtractionResult",
	"RarePullBroadcast",
	"LockerChanged",
	"TradeEvent",
	"OnboardingBeat",
	"ShowWelcome",
	"StarterGuide",
	"IntroBeat",
	"StarterPackOffer",
	"ShopGrant",
	"CountdownSync",
	"ShelfChanged",
	"QueueState",
	"FunnelClient",
	"Admin.Reply",
	"RespawnTimer",
})

local REMOTE_FUNCTION_NAMES = table.freeze({
	"RequestPickupCase",
	"RequestDropCase",
	"RequestReviveTeammate",
	"RequestRespawnNow",
	"RequestOpenCase",
	"GetLockerState",
	"GetOddsTable",
	"Trade.Invite",
	"Trade.SetOffer",
	"Trade.Confirm",
	"Trade.Cancel",
	"Shelf.Place",
	"Shelf.Remove",
	"Shelf.GetAll",
	"Queue.SetReady",
	"Queue.Leave",
	"Shop.GetCatalog",
	"Shop.RequestStarterPackPrompt",
	"Shop.PromptHousing",
	"Consumable.Use",
	"Combat.Attack",
	"Pet.Equip",
	"Pet.GetState",
	"Pet.UpgradeWithPay",
	"Bike.SetActive",
	"Shop.DevBuy",
	"StarterGuide.TeleportToLot",
	"StarterGuide.TeleportToClockIn",
})

local VALID_NAMES: { [string]: string } = {}
for _, name in REMOTE_EVENT_NAMES do
	VALID_NAMES[name] = "RemoteEvent"
end
for _, name in REMOTE_FUNCTION_NAMES do
	VALID_NAMES[name] = "RemoteFunction"
end
table.freeze(VALID_NAMES)

local Remotes = {}

Remotes.FOLDER_NAME = FOLDER_NAME
Remotes.EVENT_NAMES = REMOTE_EVENT_NAMES
Remotes.FUNCTION_NAMES = REMOTE_FUNCTION_NAMES
-- Cross-server rare-pull fanout topic (MessagingService, pcall-wrapped by users).
Remotes.MESSAGING_TOPIC_RARE_PULL = "RarePull"

-- Creates ReplicatedStorage.Remotes and every remote instance by exact name.
-- Idempotent; called exactly once by init.server.luau before services Init.
function Remotes.InitServer()
	assert(RunService:IsServer(), "Remotes.InitServer can only be called on the server")

	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		local newFolder = Instance.new("Folder")
		newFolder.Name = FOLDER_NAME
		newFolder.Parent = ReplicatedStorage
		folder = newFolder
	end

	for name, className in VALID_NAMES do
		if (folder :: Instance):FindFirstChild(name) == nil then
			local remote = Instance.new(className)
			remote.Name = name
			remote.Parent = folder
		end
	end
end

local CLIENT_WAIT_TIMEOUT_SECONDS = 10

-- Returns the remote instance with this exact name. Yields on the client until
-- it replicates (warns after 10s, then keeps waiting); errors on unknown names
-- (catches typos at the call site).
function Remotes.Get(name: string): Instance
	assert(
		VALID_NAMES[name] ~= nil,
		`Remotes.Get: unknown remote "{name}" — remotes are defined only in Remotes.luau`
	)

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		assert(folder ~= nil, "Remotes.Get called on the server before Remotes.InitServer()")
		local remote = folder:FindFirstChild(name)
		assert(remote ~= nil, `Remotes.Get: remote "{name}" missing — was Remotes.InitServer() called?`)
		return remote
	end

	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME, CLIENT_WAIT_TIMEOUT_SECONDS)
	if folder == nil then
		warn(
			`Remotes.Get: "{FOLDER_NAME}" folder not replicated after {CLIENT_WAIT_TIMEOUT_SECONDS}s — still waiting`
		)
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	end

	local remote = (folder :: Instance):WaitForChild(name, CLIENT_WAIT_TIMEOUT_SECONDS)
	if remote == nil then
		warn(`Remotes.Get: remote "{name}" not replicated after {CLIENT_WAIT_TIMEOUT_SECONDS}s — still waiting`)
		remote = (folder :: Instance):WaitForChild(name)
	end
	return remote
end

-- Typed conveniences over Get.
function Remotes.GetEvent(name: string): RemoteEvent
	local remote = Remotes.Get(name)
	assert(remote:IsA("RemoteEvent"), `Remotes.GetEvent: "{name}" is a {remote.ClassName}, not a RemoteEvent`)
	return remote
end

function Remotes.GetFunction(name: string): RemoteFunction
	local remote = Remotes.Get(name)
	assert(remote:IsA("RemoteFunction"), `Remotes.GetFunction: "{name}" is a {remote.ClassName}, not a RemoteFunction`)
	return remote
end

return table.freeze(Remotes)
