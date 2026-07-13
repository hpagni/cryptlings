--!strict
-- CRYPTLINGS: NIGHT SHIFT — QueuePadService (R2 WP5.1; Lobby SOP Addendum 1
-- Change 6.1). The thin Roblox adapter around the pure DispatchCore metronome:
-- zone sensing, the 45 s master clock, snapshot/freeze/dispatch staging,
-- attribute/billboard mirrors, the QueueState remote, ring tinting, and
-- placeholder SFX. Every dispatch rule (perpetual epoch, T-3 freeze, FIFO
-- party-aware bins of <= 4, no hold-back, slot-exhaustion deferral, unanimous
-- Start-now vote) lives in Shared.Logic.DispatchCore and is pinned by
-- tests/suites/dispatch_core.luau — this file never re-implements one.
--
-- Master clock (Change 6.1.1): `shiftEpoch = workspace:GetServerTimeNow()` is
-- set ONCE at Start and mirrored to the pad/zone/model as the `ShiftEpoch`
-- attribute. It NEVER pauses and NEVER resets — an empty pad at T=0 is a
-- silent rollover (whistle + ring flash client-side, no state stall, no
-- "Waiting for players"). Clients render the countdown locally from the
-- epoch; there is no per-second remote.
--
-- Pad set (Change 6.1.3/6.1.6): membership is a ZONE VOLUME, never Touched —
-- a 5 Hz Workspace:GetPartBoundsInBox poll over the invisible ClockInZone,
-- plus an immediate re-check on CharacterAdded. A body is in the snapshot iff
-- alive, not already in a shift (ShiftService.GetSessionOf == nil), not
-- AFK-excluded (root drift >= DISPATCH.AFK_EXCLUDE_SECONDS with a
-- Player.Idled cross-check -> 6-stud nudge off-pad + one-shot afkUserIds in
-- the QueueState payload — the client's "Clocked out — inactive" toast), and
-- not pad-cooldown-listed (DISPATCH.INSHIFT_STRIKES in-shift AFK strikes,
-- reported by ShiftService via ReportAfkStrike, earn a
-- DISPATCH.PAD_COOLDOWN_SECONDS cooldown). At T-3 the snapshot freezes
-- ("DOORS CLOSING", DoorsClosing attribute): late ENTRY defers to the next
-- cycle; stepping OFF still removes at any time.
--
-- Dispatch (Change 6.1.4, Wave-5 cross-WP contract): at every T=0 the
-- snapshot partitions into party-aware FIFO bins (co-present Roblox friends
-- group as one unit via a matrix cached asynchronously on PlayerAdded —
-- IsFriendsWith is NEVER called inside the step/snapshot path) and the launch
-- bins are STAGED for the ShiftService dispatcher; bins beyond the free slot
-- count defer with "ALL FLOORS RUNNING" and roll into the next snapshot. An
-- unconsumed plan is replaced wholesale at the next T=0 — the metronome never
-- wedges on a dead consumer, so there is no launch watchdog.
--
-- Mirrors (display only — truth is the pad set + epoch):
--   (a) attributes QueueState / QueueCount / CountdownEndsAt / RingState
--       (names preserved — liveness contract for ShiftService's
--       getActiveQueuePad) plus additive ShiftEpoch / ActiveFloors /
--       DoorsClosing, on the pad part, the zone part, and the QueuePad model;
--   (b) QueueState RemoteEvent on every transition + 1 Hz while occupied
--       (payload: userIds + counts ONLY — Security Review Scope §1; additive
--       one-shot afkUserIds / deferredUserIds arrays for the WP5.3 toasts);
--   (c) billboard: line 2 "NEXT SHIFT 0:NN" / "DOORS CLOSING", line 3
--       "CLOCKED IN: n", line 4 "SHIFT STARTED — N FLOORS RUNNING" flash then
--       the persistent "N FLOORS RUNNING" line ("ALL FLOORS RUNNING" while a
--       deferral notice is live);
--   (d) ring color (idle cyan / occupied amber / final white) — the client
--       tweens pulse/strobe off the RingState attribute. The queue beacon's
--       shift-dimming is retired: the metronome pad never sleeps.
--
-- Remote validation (Remotes.luau contract; Security Review Scope §2):
--   Queue.SetReady — arg must be EXACTLY a boolean, else {ok=false} with zero
--   side effects; the unanimous vote dispatches an EXTRA bin (free slot
--   required server-side) and never moves the epoch; any new pad entrant
--   clears all pending votes. Queue.Leave — zero-arg, extras ignored; honored
--   at ANY time including the final 3 s. Both: <= 5 calls / 10 s sliding
--   window per player, only current snapshot members honored, handlers never
--   yield.
--
-- Public API (HubService.IsInClockInZone + ShiftService WP5.2 dispatcher):
--   QueuePadService.IsOnPad(player) -> boolean
--   QueuePadService.GetPendingDispatch() -> { {Player} }?  -- non-nil exactly while a staged plan awaits
--   QueuePadService.ConsumeDispatch() -> { {Player} }?     -- acknowledge; one ShiftSession per bin
--   QueuePadService.AddRequeueVote(player)                 -- next-snapshot membership (freeze-gated)
--   QueuePadService.ReportAfkStrike(player)                -- WP5.2 in-shift AFK watchdog reports

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local DispatchCore = require(Shared:WaitForChild("Logic"):WaitForChild("DispatchCore"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local DISPATCH = LobbyConfig.DISPATCH -- metronome numbers of record (WP1.2)

local POLL_SECONDS = 1 / LobbyConfig.QUEUE_MEMBERSHIP_HZ -- 5 Hz zone poll (§6.3)
local BROADCAST_SECONDS = 1 -- QueueState refresh cadence while occupied

local RATE_LIMIT_CALLS = 5 -- per-player Queue.* budget (Security Scope §2)
local RATE_LIMIT_WINDOW_SECONDS = 10

local AFK_MOVE_EPSILON_STUDS = 0.5 -- root drift below this = "unchanged"
local AFK_NUDGE_STUDS = 6 -- Change 6.1.6: "nudge 6 studs off-pad"
-- Player.Idled re-fires roughly every 30 s while the client stays inactive;
-- a fire inside this window means the engine still considers them idle.
local IDLED_RECENT_SECONDS = 35

local DISPATCH_FLASH_SECONDS = 4 -- "SHIFT STARTED — N FLOORS RUNNING" hold
local DEFER_FLASH_SECONDS = 4 -- "ALL FLOORS RUNNING" hold on a deferral

-- Ring state palette (SOP §6.1 idiom under the metronome: idle cyan, occupied
-- amber, DOORS-CLOSING white — the cyan matches QueuePadBuilder's idle ring).
local COLOR_RING_IDLE = Color3.fromRGB(90, 220, 255)
local COLOR_RING_QUEUED = Color3.fromRGB(255, 176, 60)
local COLOR_RING_FINAL = Color3.fromRGB(255, 255, 255)

-- Placeholder greybox SFX (art/audio pass replaces these — same ids the
-- client controllers use).
local SOUND_TICK_ID = "rbxasset://sounds/electronicpingshort.wav" -- final-3 s tick
local SOUND_KACHUNK_ID = "rbxasset://sounds/snap.mp3" -- punch-clock join
local SOUND_WHISTLE_ID = "rbxasset://sounds/victory.wav" -- T=0 steam whistle

-- DispatchCore config of record: every number sourced from LobbyConfig.DISPATCH
-- (CYCLE_SECONDS re-exports GameConstants.INTERMISSION_SECONDS — never a
-- literal 45 here).
local dispatchConfig: DispatchCore.Config = DispatchCore.config({
	cycleSeconds = DISPATCH.CYCLE_SECONDS,
	binSize = DISPATCH.BIN_SIZE,
	freezeSeconds = DISPATCH.FREEZE_SECONDS,
	maxBins = DISPATCH.SLOT_COUNT,
})

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local QueuePadService = {}

local active = false

-- The master clock anchor (set once at Start; no event may ever mutate it).
local shiftEpoch: number? = nil
local lastCycleIndex = 0

-- Pad fixtures (every one optional — a missing fixture degrades its mirror,
-- never the queue mechanics).
local zonePart: BasePart? = nil
local padPart: BasePart? = nil
local ringParts: { BasePart } = {}
local countdownLabel: TextLabel? = nil
local workersLabel: TextLabel? = nil
local floorsLabel: TextLabel? = nil

-- Pad set: padRoster insertion order IS pad-arrival order (entries are
-- blocked during the freeze window, so the roster at T=0 IS the snapshot).
local padRoster: { Player } = {}
local padArrival: { [Player]: number } = {}

-- The ONLY userId -> Player resolution (maintained on enter, cleared on
-- PlayerRemoving — liveness is always player.Parent == Players).
local playerByUserId: { [number]: Player } = {}

local inZone: { [Player]: boolean } = {} -- latest zone poll result
local optedOut: { [Player]: boolean } = {} -- Leave/AFK while still inside the zone
local requeueVoters: { [Player]: boolean } = {} -- ShiftService squad re-queue (§3.2 co-play)
local votes: { [DispatchCore.Key]: boolean } = {} -- Start-now votes by userId

local afkTrack: { [number]: { position: Vector3, since: number } } = {}
local lastIdledAt: { [Player]: number } = {} -- Player.Idled cross-check stamps

-- Server-session persistent BY DESIGN (keyed by userId, never cleared on
-- leave): rejoining the server does not launder strikes or a pad cooldown.
local afkStrikes: { [number]: number } = {}
local padCooldownUntil: { [number]: number } = {}

-- Pairwise friendship matrix (v1 party proxy), cached asynchronously on
-- PlayerAdded. The snapshot path only ever READS this table.
local friendPairs: { [number]: { [number]: boolean } } = {}

-- The staged dispatch plan awaiting the ShiftService dispatcher.
local pendingBins: { { Player } }? = nil

local characterConns: { [Player]: RBXScriptConnection } = {}
local idledConns: { [Player]: RBXScriptConnection } = {}

local callStamps: { [Player]: { [string]: { number } } } = {} -- sliding-window rate limit

local overlapParams = OverlapParams.new()
overlapParams.RespectCanCollide = false

-- Mirror bookkeeping.
local lastSignature = ""
local lastBroadcastAt = 0
local lastTickSecond = -1
local dispatchFlashUntil = 0
local dispatchFlashFloors = 0
local deferFlashUntil = 0
local afkNoticeIds: { number } = {} -- one-shot payload arrays, cleared on send
local deferredNoticeIds: { number } = {}

local soundTick: Sound? = nil
local soundKaChunk: Sound? = nil
local soundWhistle: Sound? = nil

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing module degrades a
-- feature, never boot)
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
-- Small helpers
--------------------------------------------------------------------------------

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function aliveRoot(player: Player): BasePart?
	if player.Parent ~= Players then
		return nil
	end
	local character = player.Character
	if character == nil then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Sliding-window per-player rate limit (TradeService invite-token pattern).
local function consumeRateToken(player: Player, key: string): boolean
	local clock = os.clock()
	local byKey = callStamps[player]
	if byKey == nil then
		byKey = {}
		callStamps[player] = byKey
	end
	local stamps = byKey[key]
	if stamps == nil then
		stamps = {}
		byKey[key] = stamps
	end
	for index = #stamps, 1, -1 do
		if clock - stamps[index] > RATE_LIMIT_WINDOW_SECONDS then
			table.remove(stamps, index)
		end
	end
	if #stamps >= RATE_LIMIT_CALLS then
		return false
	end
	table.insert(stamps, clock)
	return true
end

local function makeSound(name: string, soundId: string, volume: number): Sound?
	local host: Instance? = padPart or zonePart
	if host == nil then
		return nil
	end
	local ok, sound = pcall(function(): Sound
		local instance = Instance.new("Sound")
		instance.Name = name
		instance.SoundId = soundId
		instance.Volume = volume
		instance.RollOffMaxDistance = 150
		instance.Parent = host
		return instance
	end)
	if ok then
		return sound
	end
	return nil
end

local function playSound(sound: Sound?)
	if sound ~= nil then
		pcall(function()
			sound:Play()
		end)
	end
end

local function formatCountdown(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

--------------------------------------------------------------------------------
-- ShiftService bridge (pcall feature-detection; absent facade degrades to a
-- display-only pad — the legacy no-pad fallback in ShiftService takes over)
--------------------------------------------------------------------------------

local function isInShift(player: Player): boolean
	local shift = getSibling("ShiftService")
	if shift ~= nil and type(shift.GetSessionOf) == "function" then
		local ok, session = pcall(shift.GetSessionOf, player)
		if ok and session ~= nil then
			return true
		end
	end
	return false
end

-- Nil when the facade (or its slot pool) is absent: the pad then stages zero
-- launch bins (everything defers) instead of guessing at capacity.
local function freeSlotCount(): number?
	local shift = getSibling("ShiftService")
	if shift ~= nil and type(shift.GetFreeSlotCount) == "function" then
		local ok, count = pcall(shift.GetFreeSlotCount)
		if ok and type(count) == "number" then
			return math.max(math.floor(count), 0)
		end
	end
	return nil
end

local function activeFloorCount(): number
	local free = freeSlotCount()
	if free == nil then
		return 0
	end
	return math.clamp(DISPATCH.SLOT_COUNT - free, 0, DISPATCH.SLOT_COUNT)
end

--------------------------------------------------------------------------------
-- Clock (pure reads over the immutable epoch)
--------------------------------------------------------------------------------

local function cycleIndexAt(epoch: number, clock: number): number
	return math.floor((clock - epoch) / dispatchConfig.cycleSeconds)
end

-- The next T=0 instant: constant within a cycle, jumps by exactly one cycle
-- at each dispatch (CountdownEndsAt + payload endsAt are both this value).
local function nextDispatchAt(epoch: number, clock: number): number
	return epoch + (cycleIndexAt(epoch, clock) + 1) * dispatchConfig.cycleSeconds
end

--------------------------------------------------------------------------------
-- Pad membership
--------------------------------------------------------------------------------

local function isMember(player: Player): boolean
	return padArrival[player] ~= nil
end

local function removeMember(player: Player)
	if padArrival[player] == nil then
		return
	end
	padArrival[player] = nil
	local index = table.find(padRoster, player)
	if index ~= nil then
		table.remove(padRoster, index)
	end
	votes[player.UserId] = nil
	afkTrack[player.UserId] = nil
	requeueVoters[player] = nil
end

local function addMember(player: Player, clock: number)
	if padArrival[player] ~= nil then
		return
	end
	padArrival[player] = clock
	table.insert(padRoster, player)
	playerByUserId[player.UserId] = player
	afkTrack[player.UserId] = nil
	lastIdledAt[player] = nil
	-- A new key entering the pad clears EVERY pending Start-now vote
	-- (DispatchCore.voteReady contract: stale unanimity must never fire).
	table.clear(votes)
	if inZone[player] == true then
		playSound(soundKaChunk) -- punch-clock "ka-chunk" (§6.4)
	end
end

--------------------------------------------------------------------------------
-- Friendship cache (party proxy). IsFriendsWith yields, so rows are built in
-- a spawned thread on PlayerAdded ONLY — the T=0 snapshot path is cache-read.
--------------------------------------------------------------------------------

local function areFriends(a: Player, b: Player): boolean
	local row = friendPairs[a.UserId]
	return row ~= nil and row[b.UserId] == true
end

local function cacheFriendships(player: Player)
	if friendPairs[player.UserId] == nil then
		friendPairs[player.UserId] = {}
	end
	task.spawn(function()
		for _, other in Players:GetPlayers() do
			if other == player or other.Parent ~= Players then
				continue
			end
			local ok, isFriend = pcall(player.IsFriendsWith, player, other.UserId)
			if ok and isFriend == true and player.Parent == Players then
				-- Symmetric write, guarded so a row cleared by PlayerRemoving
				-- mid-yield is never resurrected.
				local mine = friendPairs[player.UserId]
				local theirs = friendPairs[other.UserId]
				if mine ~= nil then
					mine[other.UserId] = true
				end
				if theirs ~= nil then
					theirs[player.UserId] = true
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Snapshot -> staged dispatch
--------------------------------------------------------------------------------

-- Live snapshot occupants in FIFO entry order (entries were blocked during
-- the freeze window, so the roster at T=0 IS the frozen snapshot; leavers and
-- AFK exclusions were already dropped by the step passes).
local function snapshotOccupants(): { Player }
	local occupants: { Player } = {}
	for _, player in padRoster do
		if aliveRoot(player) ~= nil and not isInShift(player) then
			table.insert(occupants, player)
		end
	end
	return occupants
end

-- Party-aware units: co-present Roblox friends (cached matrix) merge into one
-- unit (transitively — a friendship component), everyone else is a singleton.
-- A unit is stamped with its EARLIEST member's pad arrival, so DispatchCore's
-- FIFO sort never reorders a party behind latecomers.
local function buildUnits(occupants: { Player }): ({ DispatchCore.Unit }, { [number]: Player })
	local byKey: { [number]: Player } = {}
	local claimed: { [Player]: boolean } = {}
	local units: { DispatchCore.Unit } = {}
	for _, seedPlayer in occupants do
		if claimed[seedPlayer] then
			continue
		end
		claimed[seedPlayer] = true
		local component: { [Player]: boolean } = { [seedPlayer] = true }
		local frontier: { Player } = { seedPlayer }
		while #frontier > 0 do
			local current = table.remove(frontier) :: Player
			for _, other in occupants do
				if claimed[other] ~= true and areFriends(current, other) then
					claimed[other] = true
					component[other] = true
					table.insert(frontier, other)
				end
			end
		end
		local keys: { DispatchCore.Key } = {}
		local arrivedAt = math.huge
		for _, member in occupants do -- occupant order keeps keys FIFO inside the unit
			if component[member] == true then
				table.insert(keys, member.UserId)
				byKey[member.UserId] = member
				local arrival = padArrival[member]
				if arrival ~= nil and arrival < arrivedAt then
					arrivedAt = arrival
				end
			end
		end
		table.insert(units, { keys = keys, arrivedAt = arrivedAt })
	end
	return units, byKey
end

-- Compute a dispatch plan over `occupants` and stage the launch bins for the
-- ShiftService dispatcher. An unconsumed previous plan is REPLACED wholesale:
-- never-consumed occupants are still standing on the pad and simply land in
-- the replacement plan (no watchdog, no wedge). Returns the staged bin count.
local function stageDispatch(clock: number, occupants: { Player }): number
	table.clear(deferredNoticeIds)
	if #occupants == 0 then
		pendingBins = nil
		return 0
	end

	local units, byKey = buildUnits(occupants)
	local plan = DispatchCore.planDispatch(units, freeSlotCount() or 0, dispatchConfig)

	local bins: { { Player } } = {}
	for _, bin in plan.bins do
		local players: { Player } = {}
		for _, key in bin do
			local player = byKey[key :: number]
			if player ~= nil then
				table.insert(players, player)
			end
		end
		if #players > 0 then
			table.insert(bins, players)
		end
	end
	pendingBins = if #bins > 0 then bins else nil

	-- Bins beyond the free slots defer (Change 6.2.3): those occupants stay
	-- in the pad set for the next cycle and read "ALL FLOORS RUNNING".
	for _, bin in plan.deferredBins do
		for _, key in bin do
			table.insert(deferredNoticeIds, key :: number)
		end
	end
	if #deferredNoticeIds > 0 then
		deferFlashUntil = clock + DEFER_FLASH_SECONDS
	end
	return #bins
end

-- The T=0 crossing: snapshot -> staged bins. Runs on EVERY crossing — an
-- empty pad is the silent rollover (same epoch, whistle, next cycle).
local function runCycleDispatch(clock: number)
	local staged = stageDispatch(clock, snapshotOccupants())
	table.clear(votes) -- the snapshot consumed every pending Start-now vote
	playSound(soundWhistle) -- T=0 whistle: dispatch AND silent rollover (§6.1.2)
	if staged > 0 then
		dispatchFlashUntil = clock + DISPATCH_FLASH_SECONDS
		dispatchFlashFloors = math.clamp(activeFloorCount() + staged, 1, DISPATCH.SLOT_COUNT)
	end
end

-- Start-now vote (Change 6.1.5): unanimous over the CURRENT occupants plus a
-- free slot -> immediate EXTRA dispatch; the master epoch is never touched.
-- Re-checked every step (a slot freeing later can complete an armed vote);
-- votes clear on dispatch, so a passing vote fires exactly once.
local function tryStartNowVote(clock: number)
	if #padRoster == 0 then
		return
	end
	local occupantKeys: { DispatchCore.Key } = {}
	for _, player in padRoster do
		table.insert(occupantKeys, player.UserId)
	end
	if not DispatchCore.voteReady(votes, occupantKeys) then
		return
	end
	local free = freeSlotCount()
	if free == nil or free < 1 then
		return -- no slot: the vote stays armed until one frees or the set changes
	end
	local staged = stageDispatch(clock, snapshotOccupants())
	table.clear(votes)
	if staged > 0 then
		playSound(soundWhistle)
		dispatchFlashUntil = clock + DISPATCH_FLASH_SECONDS
		dispatchFlashFloors = math.clamp(activeFloorCount() + staged, 1, DISPATCH.SLOT_COUNT)
	end
end

--------------------------------------------------------------------------------
-- Mirrors (display only; synchronous and yield-free — called from the poll
-- loop and from every remote/API mutation so transitions are never a poll
-- tick stale)
--------------------------------------------------------------------------------

local function ringColorFor(ringState: string): Color3
	if ringState == "Final" then
		return COLOR_RING_FINAL
	elseif ringState == "Queued" then
		return COLOR_RING_QUEUED
	end
	return COLOR_RING_IDLE
end

-- Attribute mirror targets: pad part + zone part + the QueuePad model (the
-- QueuePadUI ring tween and any tag-bound client read the same values; the
-- zone's QueueState attribute is ShiftService's pad-liveness probe).
local function attributeTargets(): { Instance }
	local targets: { Instance } = {}
	if padPart ~= nil then
		table.insert(targets, padPart)
		local model = padPart.Parent
		if model ~= nil and model:IsA("Model") then
			table.insert(targets, model)
		end
	end
	if zonePart ~= nil then
		table.insert(targets, zonePart)
	end
	return targets
end

local function publish(clock: number)
	local epoch = shiftEpoch
	if epoch == nil then
		return
	end

	local count = #padRoster
	local freeze = DispatchCore.inFreeze(epoch, clock, dispatchConfig)
	local endsAt = nextDispatchAt(epoch, clock)
	local activeFloors = activeFloorCount()

	-- Billboard/attribute states (Change 6.1.7): Counting covers both
	-- IDLE-COUNTING and COUNTING-WITH-WORKERS (QueueCount distinguishes).
	local stateName = if clock < dispatchFlashUntil then "Dispatch" elseif freeze then "DoorsClosing" else "Counting"
	local ringState = if freeze then "Final" elseif count > 0 then "Queued" else "Idle"

	-- (a) Attributes (GetServerTimeNow-based, so clients tick locally).
	for _, target in attributeTargets() do
		target:SetAttribute("QueueState", stateName)
		target:SetAttribute("QueueCount", count)
		target:SetAttribute("CountdownEndsAt", endsAt)
		target:SetAttribute("RingState", ringState)
		target:SetAttribute("ActiveFloors", activeFloors)
		target:SetAttribute("DoorsClosing", freeze)
	end

	-- (d) Ring base color; QueuePadUI tweens pulse/strobe transparency.
	local ringColor = ringColorFor(ringState)
	for _, ring in ringParts do
		ring.Color = ringColor
	end

	-- (c) Billboard lines (text writes guarded — no no-op replication churn).
	if countdownLabel ~= nil then
		local text = if freeze then "DOORS CLOSING" else `NEXT SHIFT {formatCountdown(endsAt - clock)}`
		if countdownLabel.Text ~= text then
			countdownLabel.Text = text
		end
	end
	if workersLabel ~= nil then
		local text = `CLOCKED IN: {count}`
		if workersLabel.Text ~= text then
			workersLabel.Text = text
		end
	end
	if floorsLabel ~= nil then
		local text = ""
		if clock < deferFlashUntil then
			text = "ALL FLOORS RUNNING"
		elseif clock < dispatchFlashUntil then
			local noun = if dispatchFlashFloors == 1 then "FLOOR" else "FLOORS"
			text = `SHIFT STARTED — {dispatchFlashFloors} {noun} RUNNING`
		elseif activeFloors > 0 then
			local noun = if activeFloors == 1 then "FLOOR" else "FLOORS"
			text = `{activeFloors} {noun} RUNNING`
		end
		if floorsLabel.Text ~= text then
			floorsLabel.Text = text
		end
	end

	-- Roster/ready id lists (userIds + counts ONLY — Security Scope §1).
	local rosterUserIds: { number } = {}
	for _, player in padRoster do
		table.insert(rosterUserIds, player.UserId)
	end
	local readyUserIds: { number } = {}
	for userId, voted in votes do
		if voted then
			table.insert(readyUserIds, userId :: number)
		end
	end
	table.sort(readyUserIds)

	-- (b) QueueState remote: every transition + 1 Hz while occupied, plus an
	-- unconditional send while a one-shot AFK/deferral notice is queued
	-- (additive afkUserIds/deferredUserIds arrays — WP5.3's "Clocked out —
	-- inactive" and "ALL FLOORS RUNNING" toasts; schema otherwise unchanged).
	local hasNotices = #afkNoticeIds > 0 or #deferredNoticeIds > 0
	local rosterSignature = table.concat(rosterUserIds, ",")
	local signature =
		`{stateName}|{rosterSignature}|{table.concat(readyUserIds, ",")}|{activeFloors}|{math.floor(endsAt * 10)}`
	local dueRefresh = count > 0 and clock - lastBroadcastAt >= BROADCAST_SECONDS
	if signature ~= lastSignature or dueRefresh or hasNotices then
		lastSignature = signature
		lastBroadcastAt = clock
		local payload: { [string]: any } = {
			state = stateName,
			endsAt = endsAt,
			count = count,
			capacity = dispatchConfig.binSize,
			rosterUserIds = rosterUserIds,
			readyUserIds = readyUserIds,
		}
		if #afkNoticeIds > 0 then
			payload.afkUserIds = table.clone(afkNoticeIds)
		end
		if #deferredNoticeIds > 0 then
			payload.deferredUserIds = table.clone(deferredNoticeIds)
		end
		Remotes.GetEvent("QueueState"):FireAllClients(payload)
		table.clear(afkNoticeIds)
		table.clear(deferredNoticeIds)
	end
end

--------------------------------------------------------------------------------
-- Zone membership + the 5 Hz step
--------------------------------------------------------------------------------

-- Who is physically inside the clock-in volume right now (zone, never
-- Touched — SOP §6.3). Alive characters only.
local function scanZone(): { [Player]: boolean }
	local zone = zonePart
	local result: { [Player]: boolean } = {}
	if zone == nil then
		return result
	end
	local parts = Workspace:GetPartBoundsInBox(zone.CFrame, zone.Size, overlapParams)
	for _, part in parts do
		local character = part:FindFirstAncestorOfClass("Model")
		local player = if character ~= nil then Players:GetPlayerFromCharacter(character) else nil
		if player ~= nil and result[player] ~= true and aliveRoot(player) ~= nil then
			result[player] = true
		end
	end
	return result
end

-- AFK nudge: pivot the body AFK_NUDGE_STUDS past the zone's street-side edge,
-- keeping their facing (Change 6.1.6 "nudge 6 studs off-pad"). Only ever
-- applied to a player's OWN stillness — never aimable at someone else.
local function nudgeOffPad(player: Player)
	local zone = zonePart
	local root = aliveRoot(player)
	local character = player.Character
	if zone == nil or root == nil or character == nil then
		return
	end
	local exitX = zone.Position.X - (zone.Size.X / 2 + AFK_NUDGE_STUDS)
	local pivot = character:GetPivot()
	local rotation = pivot - pivot.Position
	character:PivotTo(CFrame.new(Vector3.new(exitX, pivot.Position.Y, pivot.Position.Z)) * rotation)
end

local function step()
	if not active then
		return
	end
	local epoch = shiftEpoch
	if epoch == nil then
		return
	end
	local clock = now()

	-- 1) Membership scan.
	inZone = scanZone()

	-- Opt-outs clear once the body actually steps off; requeue votes dissolve
	-- into ordinary physical membership the moment the voter walks on.
	for player in optedOut do
		if inZone[player] ~= true then
			optedOut[player] = nil
		end
	end
	for player in requeueVoters do
		if inZone[player] == true then
			requeueVoters[player] = nil
		end
	end

	-- 2) Removals — honored at ANY time, including the final 3 s (only late
	-- ENTRY locks): gone bodies, step-offs (non-voters), and players a
	-- dispatcher already bound into a live session.
	for index = #padRoster, 1, -1 do
		local player = padRoster[index]
		local gone = player.Parent ~= Players
		local offPad = inZone[player] ~= true and requeueVoters[player] ~= true
		if gone or offPad or isInShift(player) then
			removeMember(player)
		end
	end

	-- 3) AFK exclusion (Change 6.1.6): root unchanged for AFK_EXCLUDE_SECONDS
	-- (Player.Idled cross-checked) -> drop from the pad set, 6-stud nudge off,
	-- one-shot afkUserIds notice. Never disturbs the epoch.
	for index = #padRoster, 1, -1 do
		local player = padRoster[index]
		local root = aliveRoot(player)
		if root == nil then
			continue
		end
		local userId = player.UserId
		local track = afkTrack[userId]
		if track == nil or (root.Position - track.position).Magnitude > AFK_MOVE_EPSILON_STUDS then
			afkTrack[userId] = { position = root.Position, since = clock }
			lastIdledAt[player] = nil -- physical movement clears the engine-idle flag
		else
			local idleStamp = lastIdledAt[player]
			local engineIdle = idleStamp ~= nil and clock - (idleStamp :: number) <= IDLED_RECENT_SECONDS
			if clock - track.since >= DISPATCH.AFK_EXCLUDE_SECONDS or engineIdle then
				removeMember(player)
				table.insert(afkNoticeIds, userId)
				if inZone[player] == true then
					optedOut[player] = true -- no instant re-enter while still inside the zone
					nudgeOffPad(player)
				end
			end
		end
	end

	-- 4) T=0 crossing: snapshot -> party-aware FIFO bins -> staged dispatch.
	-- The SAME epoch keeps running (silent rollover when nobody is aboard).
	local cycle = cycleIndexAt(epoch, clock)
	if cycle > lastCycleIndex then
		lastCycleIndex = cycle
		runCycleDispatch(clock)
	end

	-- 5) Entries — blocked inside the T-3 freeze window (late ENTRY defers to
	-- the next cycle; right after a crossing the fresh cycle is never frozen).
	-- Candidates: bodies in the zone + off-pad requeue voters, under the same
	-- gates (cooldown list, not-in-shift, alive).
	if not DispatchCore.inFreeze(epoch, clock, dispatchConfig) then
		local candidates: { Player } = {}
		for player in inZone do
			table.insert(candidates, player)
		end
		for player in requeueVoters do
			if inZone[player] ~= true then
				table.insert(candidates, player)
			end
		end
		for _, player in candidates do
			if
				not isMember(player)
				and optedOut[player] ~= true
				and clock >= (padCooldownUntil[player.UserId] or 0)
				and aliveRoot(player) ~= nil
				and not isInShift(player)
			then
				addMember(player, clock)
			end
		end
	end

	-- 6) Start-now vote: unanimous + free slot -> immediate extra dispatch.
	tryStartNowVote(clock)

	-- 7) DOORS-CLOSING tick SFX, once per countdown second (§6.4).
	local remaining = DispatchCore.remaining(epoch, clock, dispatchConfig)
	if remaining <= dispatchConfig.freezeSeconds then
		local second = math.ceil(remaining)
		if second ~= lastTickSecond then
			lastTickSecond = second
			playSound(soundTick)
		end
	end

	-- 8) Mirror + broadcast.
	publish(clock)
end

--------------------------------------------------------------------------------
-- Fixture discovery — pcall HubService; every fixture optional (the queue
-- runs headless over just the zone part if the greybox pad is absent)
--------------------------------------------------------------------------------

local function adoptBuild(build: { [string]: any })
	if typeof(build.zonePart) == "Instance" and build.zonePart:IsA("BasePart") then
		zonePart = build.zonePart
	end
	if typeof(build.pad) == "Instance" and build.pad:IsA("BasePart") then
		padPart = build.pad
	end
	if type(build.ringParts) == "table" then
		for _, ring in build.ringParts :: { any } do
			if typeof(ring) == "Instance" and ring:IsA("BasePart") then
				table.insert(ringParts, ring)
			end
		end
	end
	if typeof(build.countdownLabel) == "Instance" and build.countdownLabel:IsA("TextLabel") then
		countdownLabel = build.countdownLabel
	end
	if typeof(build.workersLabel) == "Instance" and build.workersLabel:IsA("TextLabel") then
		workersLabel = build.workersLabel
	end
	if typeof(build.floorsLabel) == "Instance" and build.floorsLabel:IsA("TextLabel") then
		floorsLabel = build.floorsLabel
	end
end

-- Name-based fallback over the QueuePadBuilder model (zone.Parent) for a
-- HubService that exposes only the preserved GetClockInZone contract.
local function discoverFromModel(model: Instance)
	if padPart == nil then
		local pad = model:FindFirstChild("QueuePad")
		if pad ~= nil and pad:IsA("BasePart") then
			padPart = pad
		end
	end
	if #ringParts == 0 then
		for _, child in model:GetChildren() do
			if child.Name == "QueueRing" and child:IsA("BasePart") then
				table.insert(ringParts, child)
			end
		end
	end
	if countdownLabel == nil or workersLabel == nil or floorsLabel == nil then
		local anchor = model:FindFirstChild("ClockInBillboardAnchor")
		local billboard = if anchor ~= nil then anchor:FindFirstChild("ClockInBillboard") else nil
		if billboard ~= nil then
			local line2 = billboard:FindFirstChild("Line2")
			local line3 = billboard:FindFirstChild("Line3")
			local line4 = billboard:FindFirstChild("Line4")
			if countdownLabel == nil and line2 ~= nil and line2:IsA("TextLabel") then
				countdownLabel = line2
			end
			if workersLabel == nil and line3 ~= nil and line3:IsA("TextLabel") then
				workersLabel = line3
			end
			if floorsLabel == nil and line4 ~= nil and line4:IsA("TextLabel") then
				floorsLabel = line4
			end
		end
	end
end

local function discoverFixtures(): boolean
	local hub = getSibling("HubService")
	if hub == nil then
		return false
	end

	-- Preferred: the full QueuePadBuilder return table, when HubService
	-- exposes it (WP2.3 forward contract).
	if type(hub.GetQueuePadBuild) == "function" then
		local ok, build = pcall(hub.GetQueuePadBuild)
		if ok and type(build) == "table" then
			adoptBuild(build)
		end
	end

	-- Always honor the preserved zone contract.
	if zonePart == nil and type(hub.GetClockInZone) == "function" then
		local ok, zone = pcall(hub.GetClockInZone)
		if ok and typeof(zone) == "Instance" and zone:IsA("BasePart") then
			zonePart = zone
		end
	end
	if zonePart == nil then
		return false
	end

	local model = (zonePart :: BasePart).Parent
	if model ~= nil and model:IsA("Model") then
		discoverFromModel(model)
	end
	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Physically inside the clock-in volume right now (HubService.IsInClockInZone
-- delegates here; ShiftService's legacy queue collection uses that in turn).
function QueuePadService.IsOnPad(player: Player): boolean
	return inZone[player] == true
end

-- Non-nil exactly while a staged dispatch plan awaits the ShiftService
-- dispatcher (set at a T=0 with >= 1 bin, or by a passing Start-now vote;
-- replaced wholesale at the next T=0 if never consumed). Returns defensive
-- copies — mutating them cannot change the staged plan.
function QueuePadService.GetPendingDispatch(): { { Player } }?
	local staged = pendingBins
	if staged == nil then
		return nil
	end
	local copy: { { Player } } = {}
	for _, bin in staged do
		table.insert(copy, table.clone(bin))
	end
	return copy
end

-- Acknowledge + clear the staged plan: bins re-intersected with live players
-- (ShiftService re-checks again at teleport time), consumed players dropped
-- from the pad set (their bodies leave the zone on the dispatch pivot). One
-- ShiftSession per returned bin. Nil when nothing is staged.
function QueuePadService.ConsumeDispatch(): { { Player } }?
	local staged = pendingBins
	if staged == nil then
		return nil
	end
	pendingBins = nil
	local bins: { { Player } } = {}
	for _, bin in staged do
		local players: { Player } = {}
		for _, player in bin do
			if player.Parent == Players and aliveRoot(player) ~= nil then
				table.insert(players, player)
			end
		end
		for _, player in bin do
			removeMember(player)
		end
		if #players > 0 then
			table.insert(bins, players)
		end
	end
	if active then
		publish(now())
	end
	if #bins == 0 then
		return nil
	end
	return bins
end

-- Squad re-queue vote (ShiftService forwards RequeueShift here): membership
-- in the NEXT snapshot without standing on the pad. The 5 Hz step folds
-- voters in under the SAME entry gates as a physical body — including the
-- T-3 freeze (Security Scope §2: the freeze is not bypassable via
-- AddRequeueVote), the cooldown list, and the not-in-shift check. The vote
-- dissolves into ordinary membership when the voter walks on, and clears on
-- dispatch consumption, Queue.Leave, and leaving the server.
function QueuePadService.AddRequeueVote(player: Player)
	if not active then
		return
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return
	end
	requeueVoters[player] = true
	optedOut[player] = nil
	playerByUserId[player.UserId] = player
end

-- In-shift AFK strike report (WP5.2's per-session watchdog): INSHIFT_STRIKES
-- strikes earn a PAD_COOLDOWN_SECONDS pad cooldown (Change 6.1.6 — protects
-- Best Employees from AFK farming). Keyed by userId and NEVER cleared on
-- leave: rejoining the server does not launder strikes or a cooldown.
function QueuePadService.ReportAfkStrike(player: Player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local userId = player.UserId
	local strikes = (afkStrikes[userId] or 0) + 1
	afkStrikes[userId] = strikes
	if strikes >= DISPATCH.INSHIFT_STRIKES then
		padCooldownUntil[userId] = now() + DISPATCH.PAD_COOLDOWN_SECONDS
	end
end

--------------------------------------------------------------------------------
-- Remote handlers (fail-closed; never yield — Security Scope §2)
--------------------------------------------------------------------------------

local function onSetReady(player: Player, ready: unknown): { ok: boolean }
	if not active then
		return { ok = false }
	end
	if type(ready) ~= "boolean" then
		return { ok = false } -- arg must be EXACTLY a boolean; zero side effects
	end
	if not consumeRateToken(player, "SetReady") then
		return { ok = false }
	end
	if not isMember(player) then
		return { ok = false } -- only current snapshot members vote
	end
	local clock = now()
	if ready then
		votes[player.UserId] = true
		tryStartNowVote(clock) -- immediate extra dispatch when unanimous + slot
	else
		votes[player.UserId] = nil
	end
	publish(clock)
	return { ok = true }
end

local function onLeave(player: Player): { ok: boolean }
	if not active then
		return { ok = false }
	end
	if not consumeRateToken(player, "Leave") then
		return { ok = false }
	end
	-- Snapshot opt-out (Change 6.1.3): honored at ANY time, including the
	-- final 3 s DOORS-CLOSING freeze; never moves the epoch.
	local honored = isMember(player) or requeueVoters[player] == true
	if not honored then
		return { ok = false }
	end
	requeueVoters[player] = nil
	removeMember(player)
	if inZone[player] == true then
		-- Still standing on the pad: don't let the next poll re-enter them
		-- until they physically step off.
		optedOut[player] = true
	end
	publish(now())
	return { ok = true }
end

--------------------------------------------------------------------------------
-- Session cleanup
--------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
	local conn = characterConns[player]
	if conn ~= nil then
		conn:Disconnect()
		characterConns[player] = nil
	end
	local idleConn = idledConns[player]
	if idleConn ~= nil then
		idleConn:Disconnect()
		idledConns[player] = nil
	end
	removeMember(player)
	inZone[player] = nil
	optedOut[player] = nil
	requeueVoters[player] = nil
	callStamps[player] = nil
	lastIdledAt[player] = nil

	local userId = player.UserId
	friendPairs[userId] = nil
	for _, row in friendPairs do
		row[userId] = nil
	end
	if playerByUserId[userId] == player then
		playerByUserId[userId] = nil
	end
	-- afkStrikes / padCooldownUntil persist for the server session by design.
	if active then
		publish(now())
	end
end

-- Per-player wiring: immediate membership re-check on respawn (§6.3 known
-- reset dropouts), the Player.Idled AFK cross-check stamp, and the async
-- friendship-row build (cache-only reads at T=0).
local function watchPlayer(player: Player)
	if characterConns[player] == nil then
		characterConns[player] = player.CharacterAdded:Connect(function()
			task.defer(step)
		end)
	end
	if idledConns[player] == nil then
		idledConns[player] = player.Idled:Connect(function(_idleTime: number)
			lastIdledAt[player] = now()
		end)
	end
	cacheFriendships(player)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function QueuePadService:Init()
	if active then
		return
	end

	-- Alphabetical Init order guarantees HubService (H < Q) already built the
	-- pad. No zone volume = degraded boot: every API stays safe (IsOnPad
	-- false, GetPendingDispatch nil) and ShiftService keeps its legacy path.
	if not discoverFixtures() then
		warn("[QueuePadService] no clock-in zone available — queue pad disabled")
		return
	end

	soundTick = makeSound("QueueTick", SOUND_TICK_ID, 0.6)
	soundKaChunk = makeSound("QueueKaChunk", SOUND_KACHUNK_ID, 0.8)
	soundWhistle = makeSound("QueueWhistle", SOUND_WHISTLE_ID, 0.9)

	Remotes.GetFunction("Queue.SetReady").OnServerInvoke = onSetReady
	Remotes.GetFunction("Queue.Leave").OnServerInvoke = onLeave

	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Players.PlayerAdded:Connect(watchPlayer)

	active = true
end

function QueuePadService:Start()
	if not active then
		return
	end

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	-- Master clock: ONE GetServerTimeNow anchor, set once, mirrored once as
	-- the ShiftEpoch attribute. Nothing below ever writes it again.
	local epoch = now()
	shiftEpoch = epoch
	lastCycleIndex = 0
	for _, target in attributeTargets() do
		target:SetAttribute("ShiftEpoch", epoch)
	end

	publish(epoch)
	while true do
		task.wait(POLL_SECONDS)
		step()
	end
end

return QueuePadService
