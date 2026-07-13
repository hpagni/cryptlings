--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShiftSession (R2 WP3.3; Lobby SOP Addendum 1
-- Change 6.2, migration step 2). ONE shift instance as a class: every piece of
-- the old module-level ShiftService FSM (state, deadline, floor handle, roster,
-- downed records, revive holds) is an instance field, so N sessions can run
-- concurrently in one server. This wave ShiftService still dispatches exactly
-- one session at a time (hard cap 1); WP5.2 lifts the cap with the slot pool.
--
-- NOT auto-loaded: Services/Shift/ is a folder module (like Services/FloorGen/)
-- and the Stage-0 loader only requires direct ModuleScript children of
-- Services/. ShiftService is the sole constructor.
--
-- Division of labor (Change 6.2.2):
--   * ShiftService (SessionManager facade) owns: remotes + payload fan-out,
--     hub spawn/returns, the playerToSession reverse index, seeds, the
--     dispatcher loop and the ONE global speed/teleport-validator loop.
--   * ShiftSession owns: one shift's lifecycle thread (:Run() = dispatch ->
--     Active watchdog -> Complete -> teardown), the downed/bleedout/revive
--     loyalty mechanic for ITS roster (§1.2), and floor teardown through its
--     FloorLike handle.
--
-- Hard rules (Change 6.2.1):
--   * :Run() executes on its own task.spawn thread; ANY error routes to
--     :Destroy() and must never kill the dispatcher.
--   * :Destroy() is idempotent: restore downed, lose un-extracted haul per
--     current semantics, CaseService.ClearShift(floorRoot) (today's
--     implementation ignores the argument and clears globally — WP4.1 scopes
--     it), Defect teardown, floorHandle:Destroy(), roster cleanup. Slot
--     release is the CALLER's job AFTER Destroy returns (WP5.2 slot pool).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))

--------------------------------------------------------------------------------
-- Tuning (carried over verbatim from the module-FSM ShiftService)
--------------------------------------------------------------------------------

local COMPLETE_STATE_SECONDS = 5 -- "shift complete" beat before the next intermission
local WATCHDOG_TICK_SECONDS = 1 -- Active-state poll cadence (clock / all-out checks)
local TELEPORT_SPREAD_STUDS = 4 -- crew spawns in a small ring, not inside each other
local REVIVE_RANGE_STUDS = GameConstants.REVIVE_RANGE_STUDS -- shared with the client's contextual targeting
local REVIVE_MOVE_ABORT_STUDS = 1.5 -- reviver movement past this aborts the hold

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

local ShiftSession = {}
ShiftSession.__index = ShiftSession

export type SessionState = "Intermission" | "Active" | "Complete"

type DownedRecord = { bleedoutThread: thread, position: Vector3 }

-- Floor contract: FloorGenService's R2 FloorHandle (WP1.5), or ShiftService's
-- wrapper around a legacy/fallback floor. Destroy must be idempotent.
export type FloorLike = {
	model: Instance,
	spawnCFrame: CFrame,
	dockSpawns: { BasePart },
	Destroy: (self: FloorLike) -> (),
}

-- Manager-provided seams (ShiftService): remote fan-out, hub returns, the
-- playerToSession index and the movement validator stay manager-owned so the
-- session never reaches around the facade.
export type SessionDeps = {
	getSibling: (name: string) -> any,
	returnToHub: (player: Player) -> (),
	noteServerTeleport: (player: Player) -> (),
	broadcastState: () -> (),
	sendStateTo: (player: Player) -> (),
	fireDownedState: (session: ShiftSession, player: Player, downed: boolean, position: Vector3?) -> (),
	bindPlayer: (player: Player, session: ShiftSession) -> (),
	onDestroyed: (session: ShiftSession) -> (),
}

export type SessionParams = {
	id: string,
	slot: number,
	seed: number,
	roster: { Player },
	floorHandle: FloorLike,
	deps: SessionDeps,
}

type SessionFields = {
	id: string,
	slot: number,
	seed: number,
	state: SessionState,
	stateEndsAt: number?,
	floorHandle: FloorLike,
	participants: { [Player]: boolean },
	extracted: { [Player]: boolean },
	downedRecords: { [Player]: DownedRecord },
	revivesInProgress: { [Player]: boolean },
	janitor: { () -> () }, -- session-scoped cleanups (WP5.2's AFK watchdog registers here)
	_roster: { Player },
	_deps: SessionDeps,
	_destroyed: boolean,
	_floorTorndown: boolean,
}

export type ShiftSession = typeof(setmetatable({} :: SessionFields, ShiftSession))

--------------------------------------------------------------------------------
-- Sibling helpers (same pcall discipline as the manager; deps.getSibling is
-- the manager's cached resolver)
--------------------------------------------------------------------------------

local function track(deps: SessionDeps, player: Player, event: string, props: { [string]: any }?)
	local analytics = deps.getSibling("AnalyticsService")
	if analytics ~= nil and type(analytics.Track) == "function" then
		pcall(analytics.Track, player, event, props)
	end
end

local function updateData(deps: SessionDeps, player: Player, fn: (any) -> ()): boolean
	local dataService = deps.getSibling("PlayerDataService")
	if dataService ~= nil and type(dataService.Update) == "function" then
		return dataService.Update(player, fn) == true
	end
	return false
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function ShiftSession.new(params: SessionParams): ShiftSession
	local self: SessionFields = {
		id = params.id,
		slot = params.slot,
		seed = params.seed,
		state = "Intermission" :: SessionState,
		stateEndsAt = nil :: number?,
		floorHandle = params.floorHandle,
		participants = {},
		extracted = {},
		downedRecords = {},
		revivesInProgress = {},
		janitor = {},
		_roster = table.clone(params.roster),
		_deps = params.deps,
		_destroyed = false,
		_floorTorndown = false,
	}
	return setmetatable(self, ShiftSession)
end

--------------------------------------------------------------------------------
-- Read API (facade-routed by ShiftService)
--------------------------------------------------------------------------------

function ShiftSession.IsParticipant(self: ShiftSession, player: Player): boolean
	return self.participants[player] == true
end

function ShiftSession.HasExtracted(self: ShiftSession, player: Player): boolean
	return self.extracted[player] == true
end

function ShiftSession.IsDowned(self: ShiftSession, player: Player): boolean
	return self.downedRecords[player] ~= nil
end

function ShiftSession.GetFloorRoot(self: ShiftSession): Instance?
	if self._floorTorndown then
		return nil
	end
	return self.floorHandle.model
end

--------------------------------------------------------------------------------
-- Downed / bleedout / revive (§1.2 loyalty mechanic, session-scoped)
--------------------------------------------------------------------------------

-- Anchored ragdoll-lite. Drops NOTHING: cases stay welded on the downed player,
-- so teammates can RequestPickupCase them off the body (carry-out-the-box).
function ShiftSession.DownPlayer(self: ShiftSession, player: Player)
	if self.downedRecords[player] ~= nil then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or humanoid == nil or root == nil or not root:IsA("BasePart") then
		return
	end
	if humanoid.Health <= 0 then
		return
	end

	humanoid.PlatformStand = true
	root.Anchored = true
	local position = root.Position

	local bleedout = task.delay(GameConstants.DOWNED_BLEEDOUT_SECONDS, function()
		if self.downedRecords[player] == nil then
			return
		end
		self.downedRecords[player] = nil
		self._deps.fireDownedState(self, player, false, nil)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local rootNow = char and char:FindFirstChild("HumanoidRootPart")
		if rootNow ~= nil and rootNow:IsA("BasePart") then
			rootNow.Anchored = false
		end
		if hum ~= nil then
			hum.Health = 0 -- the Died handler scatters their carried cases as world pickups
		end
	end)

	self.downedRecords[player] = { bleedoutThread = bleedout, position = position }
	self._deps.fireDownedState(self, player, true, position)
	track(self._deps, player, "downed")
end

-- Cancels bleedout and stands the player back up. Returns false if not downed.
function ShiftSession._restoreDowned(self: ShiftSession, player: Player): boolean
	local record = self.downedRecords[player]
	if record == nil then
		return false
	end
	self.downedRecords[player] = nil
	pcall(task.cancel, record.bleedoutThread)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		root.Anchored = false
	end
	if humanoid ~= nil then
		humanoid.PlatformStand = false
		local caseService = self._deps.getSibling("CaseService")
		if caseService ~= nil and type(caseService.ApplyCarrySpeed) == "function" then
			caseService.ApplyCarrySpeed(player)
		else
			humanoid.WalkSpeed = GameConstants.WALKSPEED_BASE
		end
	end
	self._deps.fireDownedState(self, player, false, nil)
	return true
end

-- Public revive (contract §I): restores a downed player through the SAME
-- internal path as a completed teammate revive — cancelling the private
-- bleedout timer — so ConsumableService's revive beacon never needs the
-- observable-contract fallback. The caller owns any analytics.
function ShiftSession.RevivePlayer(self: ShiftSession, player: Player): boolean
	return self:_restoreDowned(player)
end

-- RequestReviveTeammate (contract B): server-timed hold with movement-abort.
-- The manager resolves the TARGET's session and routes here; both the busy
-- guard and the downed record live on this session.
function ShiftSession.RunReviveHold(self: ShiftSession, player: Player, target: Player): { [string]: any }
	if self.revivesInProgress[player] then
		return { ok = false, err = "BUSY" }
	end
	if self.downedRecords[target] == nil then
		return { ok = false, err = "NOT_DOWNED" }
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or humanoid == nil or humanoid.Health <= 0 or self.downedRecords[player] ~= nil then
		return { ok = false, err = "REVIVER_INCAPACITATED" }
	end
	if root == nil or not root:IsA("BasePart") then
		return { ok = false, err = "REVIVER_INCAPACITATED" }
	end

	local targetCharacter = target.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetRoot == nil or not targetRoot:IsA("BasePart") then
		return { ok = false, err = "BAD_TARGET" }
	end
	if (root.Position - targetRoot.Position).Magnitude > REVIVE_RANGE_STUDS then
		return { ok = false, err = "TOO_FAR" }
	end

	self.revivesInProgress[player] = true
	local startPosition = root.Position
	local result: { [string]: any } = { ok = true }
	local deadline = os.clock() + GameConstants.REVIVE_HOLD_SECONDS

	while os.clock() < deadline do
		task.wait(0.1)
		if self.downedRecords[target] == nil then
			result = { ok = false, err = "TARGET_LOST" } -- bled out, revived elsewhere, or left
			break
		end
		local charNow = player.Character
		local humNow = charNow and charNow:FindFirstChildOfClass("Humanoid")
		local rootNow = charNow and charNow:FindFirstChild("HumanoidRootPart")
		if charNow == nil or humNow == nil or humNow.Health <= 0 or rootNow == nil or not rootNow:IsA("BasePart") then
			result = { ok = false, err = "REVIVER_INCAPACITATED" }
			break
		end
		if (rootNow.Position - startPosition).Magnitude > REVIVE_MOVE_ABORT_STUDS then
			result = { ok = false, err = "MOVED" } -- movement-abort (spec)
			break
		end
		local targetCharNow = target.Character
		local targetRootNow = targetCharNow and targetCharNow:FindFirstChild("HumanoidRootPart")
		if
			targetRootNow == nil
			or not targetRootNow:IsA("BasePart")
			or (rootNow.Position - targetRootNow.Position).Magnitude > REVIVE_RANGE_STUDS + 2
		then
			result = { ok = false, err = "TOO_FAR" }
			break
		end
	end
	self.revivesInProgress[player] = nil

	if result.ok == true then
		if self:_restoreDowned(target) then
			track(self._deps, target, "revived", { byUserId = player.UserId })
		else
			result = { ok = false, err = "TARGET_LOST" }
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- Roster mutation (manager-routed)
--------------------------------------------------------------------------------

-- ExtractionService (via the facade) calls this once the dock dwell completes.
-- Extracted players wait out the shift at the hub (greybox spectate).
function ShiftSession.MarkExtracted(self: ShiftSession, player: Player)
	if self.participants[player] then
		self.extracted[player] = true
		self._deps.sendStateTo(player) -- participant=false: reopen the storefront for the hub wait
	end
	self._deps.returnToHub(player)
end

-- Player left the server: drop them from the roster (an empty roster ends the
-- session early via the Active watchdog's all-out check).
function ShiftSession.RemovePlayer(self: ShiftSession, player: Player)
	local record = self.downedRecords[player]
	if record ~= nil then
		self.downedRecords[player] = nil
		pcall(task.cancel, record.bleedoutThread)
		-- Tell clients the leaver is no longer downed (like every other clear
		-- path) so their revive/steal gating drops the stale entry.
		self._deps.fireDownedState(self, player, false, nil)
	end
	self.participants[player] = nil
	self.extracted[player] = nil
	self.revivesInProgress[player] = nil
end

-- Real deaths scatter carried cases at the body (world pickups). Routed by the
-- manager's Died handler via playerToSession.
function ShiftSession.HandleDeath(self: ShiftSession, player: Player, character: Model)
	local deps = self._deps
	local record = self.downedRecords[player]
	if record ~= nil then
		self.downedRecords[player] = nil
		pcall(task.cancel, record.bleedoutThread)
		deps.fireDownedState(self, player, false, nil)
	end

	local caseService = deps.getSibling("CaseService")
	local root = character:FindFirstChild("HumanoidRootPart")
	local position: Vector3? = nil
	if root ~= nil and root:IsA("BasePart") then
		position = root.Position
	elseif record ~= nil then
		position = record.position
	end

	if self.state == "Active" and self.participants[player] and not self.extracted[player] then
		self.participants[player] = nil
		deps.sendStateTo(player) -- unlock the storefront/run music immediately, not at shift end
		local lost = 0
		if caseService ~= nil then
			if position ~= nil and type(caseService.ScatterCarried) == "function" then
				lost = caseService.ScatterCarried(player, position) or 0
			elseif type(caseService.LoseCarried) == "function" then
				lost = caseService.LoseCarried(player) or 0
			end
		end
		track(deps, player, "death", { casesLost = lost, reason = "died" })
		updateData(deps, player, function(data)
			data.stats.deaths += 1
		end)
	elseif caseService ~= nil and type(caseService.LoseCarried) == "function" then
		caseService.LoseCarried(player) -- outside the active run, carried cases just clean up
	end
end

--------------------------------------------------------------------------------
-- Lifecycle (Run -> _start -> _watchdog -> _complete -> Destroy)
--------------------------------------------------------------------------------

function ShiftSession._allParticipantsOut(self: ShiftSession): boolean
	for player in self.participants do
		if not self.extracted[player] then
			return false
		end
	end
	return true
end

-- Today's startShift body, reading self: pivot the roster onto the floor,
-- mark participants, broadcast, then seed cases/weapons/Defect.
function ShiftSession._start(self: ShiftSession)
	local deps = self._deps
	local handle = self.floorHandle

	local rng = Random.new(self.seed)
	local duration = GameConstants.SHIFT_MIN_SECONDS
		+ rng:NextNumber() * (GameConstants.SHIFT_MAX_SECONDS - GameConstants.SHIFT_MIN_SECONDS)

	self.state = "Active"
	self.stateEndsAt = os.time() + math.floor(duration)
	-- participants MUST be marked before the broadcast: the per-player payload
	-- carries payload.participant, and broadcasting first would tell every
	-- runner they were a bystander (no run music, no mid-run shop lock).

	local noiseService = deps.getSibling("NoiseService")
	local dockSpawns = handle.dockSpawns
	for index, player in self._roster do
		local character = player.Character
		if character ~= nil then
			-- R3-5 hard rule (Addendum 2; R3 plan decision §7): the bike is
			-- cleared BEFORE the dispatch pivot and therefore before
			-- deps.noteServerTeleport(player) — a bike can never exist on a
			-- factory floor, and the manager's speed validator never sees a
			-- bike-speed participant.
			local bikeService = deps.getSibling("BikeService")
			if bikeService ~= nil and type(bikeService.ForceDismount) == "function" then
				pcall(bikeService.ForceDismount, player)
			end
			-- Per-player pad assignment when the floor shipped dock pads;
			-- otherwise a small ring around the single spawn CFrame.
			if #dockSpawns > 0 then
				local pad = dockSpawns[(index - 1) % #dockSpawns + 1]
				character:PivotTo(pad.CFrame + Vector3.new(0, 4, 0))
			else
				local angle = (index - 1) / math.max(#self._roster, 1) * math.pi * 2
				character:PivotTo(
					handle.spawnCFrame
						* CFrame.new(
							math.cos(angle) * TELEPORT_SPREAD_STUDS,
							0,
							math.sin(angle) * TELEPORT_SPREAD_STUDS
						)
				)
			end
			-- Change 6.6 teleport hygiene: the dispatch pivot is a legitimate
			-- long jump — re-seed the validator so it is never snapped back.
			deps.noteServerTeleport(player)
			self.participants[player] = true
			deps.bindPlayer(player, self)
			updateData(deps, player, function(data)
				data.stats.shifts += 1
			end)
			-- Initial NoiseMeter snapshot so the client HUD knows maxCarry
			-- (PASS_CARRY) before the first pickup/noise event.
			if noiseService ~= nil and type(noiseService.PushMeter) == "function" then
				pcall(noiseService.PushMeter, player)
			end
		end
	end
	deps.broadcastState()

	local floorRoot = handle.model
	local caseService = deps.getSibling("CaseService")
	if caseService ~= nil and type(caseService.SpawnForShift) == "function" then
		caseService.SpawnForShift(floorRoot, Random.new(self.seed + 1))
	end

	-- Free cartoon weapon pickups (boxing gloves / nunchucks), seeded like cases.
	local combat = deps.getSibling("CombatService")
	if combat ~= nil and type(combat.SpawnFloorWeapons) == "function" then
		pcall(combat.SpawnFloorWeapons, floorRoot, Random.new(self.seed + 2))
	end

	local defect = deps.getSibling("DefectService")
	if defect ~= nil then
		if type(defect.OnShiftActive) == "function" then
			pcall(defect.OnShiftActive, floorRoot)
		elseif type(defect.OnShiftStart) == "function" then
			pcall(defect.OnShiftStart, floorRoot, self.seed)
		end
	end
end

-- Active-state watchdog: runs the shift clock down, ends early when everyone
-- is extracted/dead/gone. Speed/teleport validation is NOT here — that is the
-- manager's ONE global loop over playerToSession (Change 6.6).
function ShiftSession._watchdog(self: ShiftSession)
	while self.state == "Active" and os.time() < (self.stateEndsAt or 0) do
		if self:_allParticipantsOut() then
			break -- everyone extracted/dead/gone; no reason to run the clock out
		end
		task.wait(WATCHDOG_TICK_SECONDS)
	end
end

-- Un-extracted players lose their carried haul (the loss-drama clip; §1.2)
-- and are returned to the hub. Shared by _complete and the crash path.
function ShiftSession._failStragglers(self: ShiftSession)
	local deps = self._deps
	local caseService = deps.getSibling("CaseService")
	for player in self.participants do
		if not self.extracted[player] then
			self:_restoreDowned(player)
			local lost = 0
			if caseService ~= nil and type(caseService.LoseCarried) == "function" then
				lost = caseService.LoseCarried(player) or 0
			end
			-- reason distinguishes a real death from a shift-clock timeout on
			-- the analytics dashboard (both lose the haul, §1.2).
			track(deps, player, "death", { casesLost = lost, reason = "shift_end" })
			deps.returnToHub(player)
		end
	end
end

-- Case/Defect/floor teardown. Idempotent; every sibling call is pcall-fenced
-- so a failing sibling can never leak the floor model or block the dispatcher.
function ShiftSession._teardownFloor(self: ShiftSession)
	if self._floorTorndown then
		return
	end
	self._floorTorndown = true
	local deps = self._deps
	local floorRoot = self.floorHandle.model

	local caseService = deps.getSibling("CaseService")
	if caseService ~= nil and type(caseService.ClearShift) == "function" then
		-- WP4.1 upgrades ClearShift to clear per-floor; today's implementation
		-- ignores the argument and clears globally (single session — same set).
		pcall(caseService.ClearShift, floorRoot)
	end

	local defect = deps.getSibling("DefectService")
	if defect ~= nil then
		if type(defect.OnShiftEnded) == "function" then
			-- WP4.2 adds the optional floorRoot (nil = all); extra arg is
			-- ignored by today's signature.
			pcall(defect.OnShiftEnded, floorRoot)
		elseif type(defect.OnShiftEnd) == "function" then
			pcall(defect.OnShiftEnd)
		end
	end

	pcall(function()
		self.floorHandle:Destroy()
	end)
end

-- Today's completeShift body, reading self.
function ShiftSession._complete(self: ShiftSession)
	self.state = "Complete"
	self.stateEndsAt = os.time() + COMPLETE_STATE_SECONDS
	self._deps.broadcastState()

	self:_failStragglers()
	self:_teardownFloor()

	table.clear(self.participants)
	table.clear(self.extracted)

	task.wait(COMPLETE_STATE_SECONDS)
end

-- The session's own lifecycle thread. ANY error still routes to :Destroy()
-- and never kills the dispatcher (Change 6.2.1).
function ShiftSession.Run(self: ShiftSession)
	task.spawn(function()
		local ok, err = pcall(function()
			self:_start()
			self:_watchdog()
			self:_complete()
		end)
		if not ok then
			warn(`[ShiftSession] session {self.id} crashed: {err} — destroying`)
		end
		self:Destroy()
	end)
end

-- Idempotent full teardown. Slot release is the CALLER's job AFTER Destroy
-- returns (the model is guaranteed destroyed by then — Change 6.2.3).
function ShiftSession.Destroy(self: ShiftSession)
	if self._destroyed then
		return
	end
	self._destroyed = true

	-- Crash-path stragglers: anyone still on the roster is restored/penalized
	-- exactly like a shift-end straggler (idempotent: the healthy path already
	-- emptied the roster in _complete).
	pcall(self._failStragglers, self)
	pcall(self._teardownFloor, self)

	for _, cleanup in self.janitor do
		pcall(cleanup)
	end
	table.clear(self.janitor)

	-- Roster cleanup: cancel any bleedout timer that survived the straggler
	-- sweep (e.g. an extracted-then-downed edge) before dropping the records.
	for _, record in self.downedRecords do
		pcall(task.cancel, record.bleedoutThread)
	end
	table.clear(self.downedRecords)
	table.clear(self.participants)
	table.clear(self.extracted)
	table.clear(self.revivesInProgress)

	self._deps.onDestroyed(self)
end

return ShiftSession
