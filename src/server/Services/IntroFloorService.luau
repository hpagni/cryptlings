--!strict
-- CRYPTLINGS: NIGHT SHIFT — IntroFloorService (R9 intro runner, server lane intro-runner).
-- The brand-new player's FIRST sixty seconds: a tiny scripted "rescue run" on a
-- dedicated out-of-pool intro floor BEFORE the welcome panel / starter guide.
-- The kid grabs a couple of glowing boxes, a slow harmless chaser herds them to
-- the green exit, the boxes they carried are BANKED into the locker (substituting
-- for the free starter box), and they are returned to the hub. ONE TIME EVER.
--
-- Sibling of WelcomeService / StarterGuideService — same skeleton:
--   * pcall getSibling lazy resolution (degrade gracefully when a sibling is absent)
--   * per-player `settled` set + `running` guard, both cleared on PlayerRemoving
--   * a 1s scan in :Start() that, for each loaded/unsettled/not-running player,
--     reads the profile under PlayerDataService.WithLock and gates on
--     WelcomeGate.shouldEnterIntro; eligible -> task.spawn the run (NOT under lock)
--
-- WelcomeGate.shouldShow now ALSO requires introFloorDone == true, so the welcome
-- panel waits behind this run. On graceful failure we still set introFloorDone =
-- true (introBoxesBanked stays false) so WelcomeService grants the normal free
-- starter box and the panel proceeds — the player is never stranded.
--
-- TELEPORTS use the MANDATORY idiom (executePivot, copied from StarterGuideService):
--   pcall RequestStreamAroundAsync (YIELDS, before the pivot) ; pcall BikeService
--   ForceDismount ; character:PivotTo(target * +4y) ; SAME-THREAD pcall
--   ShiftService.NoteServerTeleport. NEVER TeleportService, NEVER root.CFrame=.
--
-- Optional siblings consumed via pcall (degrade gracefully):
--   PlayerDataService.IsLoaded/Get/Update/WithLock
--   FloorGenService.Generate ; CaseService.SpawnCaseAt/ServerPickup/TakeAllCarried/ClearShift
--   LockerService.AddCases/NotifyLockerChanged ; ShiftService.NoteServerTeleport
--   HubService.GetSpawnPosition ; BikeService.ForceDismount

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local WelcomeGate = require(Shared:WaitForChild("Logic"):WaitForChild("WelcomeGate"))

local INTRO = GameConstants.INTRO

local SCAN_INTERVAL_SECONDS = 1
local PIVOT_LIFT = CFrame.new(0, 4, 0) -- mirror StarterGuideService executePivot's +4 studs

-- DEDICATED out-of-pool floor origin: one full slot pitch PAST ShiftService's
-- five dispatch slots (SLOT_BASE (1200,0,1200) stepped by SLOT_PITCH_STUDS 2000
-- on X, slots 1..5 -> X 1200..9200). 1200 + 6*2000 = 13200 leaves a clear 2000-
-- stud margin so an intro floor can NEVER collide with a real session floor.
local INTRO_ORIGIN = Vector3.new(1200 + 6 * 2000, 0, 1200)

local TAG_INTRO_EXIT = "IntroExit" -- client beacon attaches to whatever carries this tag
local TAG_CASE_ANCHOR = "CaseAnchor" -- FloorGen room anchor markers (real walkable spots)
local INTRO_BOX_MAX_DISTANCE = 80 -- only use anchors within this many studs of spawn (a short journey, never across the maze)

local PICKUP_POLL_SECONDS = 0.12
local CHASE_TELEGRAPH_SECONDS = 1.2
local EXIT_POLL_SECONDS = 0.15
local CHASER_STEP_SECONDS = 0.2
local CHASER_CONTACT_RADIUS = 6 -- planar; back the chaser off on contact (non-lethal)
local CHASER_BACKOFF_SECONDS = 1
local RUN_HARD_TIMEOUT_SECONDS = 120 -- safety net: never strand a player on the intro floor
local EXIT_PHASE_TIMEOUT_SECONDS = 90 -- independent cap on the run-to-exit phase

--------------------------------------------------------------------------------
-- Lazy sibling resolution (verbatim WelcomeService idiom, lines 47-68).
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

local IntroFloorService = {}

-- Players already handled this server (run done, or determined never-eligible).
-- Stops the scan from re-reading their profile. Cleared on PlayerRemoving.
local settled: { [Player]: boolean } = {}
-- Per-player run guard: true while the scripted run is in flight (so the scan
-- never double-spawns it). Cleared at teardown and on PlayerRemoving.
local running: { [Player]: boolean } = {}

local introBeatRemote: RemoteEvent? = nil

--------------------------------------------------------------------------------
-- IntroBeat (owner-only S->C). Payload { beat, data? } per the client contract.
--------------------------------------------------------------------------------

local function fireBeat(player: Player, beat: string, data: { boxesNeeded: number?, boxesGot: number? }?)
	if introBeatRemote == nil or not player:IsDescendantOf(Players) then
		return
	end
	pcall(function()
		(introBeatRemote :: RemoteEvent):FireClient(player, { beat = beat, data = data })
	end)
end

--------------------------------------------------------------------------------
-- Teleport execution — MANDATORY idiom (copied from StarterGuideService.luau
-- executePivot, lines 160-189). RequestStreamAroundAsync YIELDS and MUST run
-- BEFORE the pivot/note pair; NoteServerTeleport runs SAME-THREAD, NO YIELD
-- after PivotTo so the movement validator never speed-flags the legit teleport.
--------------------------------------------------------------------------------

local function executePivot(player: Player, targetCFrame: CFrame): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or root == nil or not root:IsA("BasePart") then
		return false
	end

	-- (yields ALLOWED here, BEFORE the pivot/note pair)
	pcall(function()
		player:RequestStreamAroundAsync(targetCFrame.Position)
	end)

	-- Bike parity (symmetry with the rest of the lobby teleport idioms).
	local bike = getSibling("BikeService")
	if bike ~= nil and type(bike.ForceDismount) == "function" then
		pcall(bike.ForceDismount, player)
	end

	-- THE PIVOT (welded assemblies move cleanly; never root.CFrame=).
	character:PivotTo(targetCFrame * PIVOT_LIFT)

	-- SAME THREAD, NO YIELD between PivotTo and the note — re-seed the validator.
	local shift = getSibling("ShiftService")
	if shift ~= nil and type(shift.NoteServerTeleport) == "function" then
		pcall(shift.NoteServerTeleport, player)
	end

	return true
end

-- Returns the player to the hub spawn using the mandatory idiom. Used by both the
-- success path and graceful failure (so an errored run never leaves the kid
-- floating where the torn-down intro floor used to be).
local function returnToHub(player: Player)
	local hubPos: Vector3? = nil
	local hub = getSibling("HubService")
	if hub ~= nil and type(hub.GetSpawnPosition) == "function" then
		local okHub, pos = pcall(hub.GetSpawnPosition)
		if okHub and typeof(pos) == "Vector3" then
			hubPos = pos
		end
	end
	if hubPos == nil then
		local shift = getSibling("ShiftService")
		if shift ~= nil and type(shift.GetHubSpawnPosition) == "function" then
			local okShift, pos = pcall(shift.GetHubSpawnPosition)
			if okShift and typeof(pos) == "Vector3" then
				hubPos = pos
			end
		end
	end
	if hubPos ~= nil then
		executePivot(player, CFrame.new(hubPos :: Vector3))
	end
end

--------------------------------------------------------------------------------
-- Intro box placement: BOX_COUNT glowing Rare (Tier 3 — already glows) boxes,
-- on the CaseAnchor markers nearest the spawn, falling back to a scripted
-- breadcrumb line from the spawn toward the exit when anchors are scarce.
--------------------------------------------------------------------------------

local function gatherIntroBoxes(handle: any): { string }
	local uids: { string } = {}
	local caseService = getSibling("CaseService")
	if caseService == nil or type(caseService.SpawnCaseAt) ~= "function" then
		return uids
	end

	local spawnCF = handle.spawnCFrame :: CFrame
	local spawnPos = spawnCF.Position
	local model: Instance? = handle.model

	-- Prefer real FloorGen room anchors NEAR the spawn, so the boxes sit a short
	-- walk into the first room or two (a real little journey the kid explores),
	-- never stacked on the spawn pad and never scattered across the whole maze.
	local anchors: { Vector3 } = {}
	if model ~= nil then
		for _, inst in CollectionService:GetTagged(TAG_CASE_ANCHOR) do
			if inst:IsA("BasePart") and inst:IsDescendantOf(model) then
				if (inst.Position - spawnPos).Magnitude <= INTRO_BOX_MAX_DISTANCE then
					table.insert(anchors, inst.Position)
				end
			end
		end
		table.sort(anchors, function(a, b)
			return (a - spawnPos).Magnitude < (b - spawnPos).Magnitude
		end)
	end

	-- Forward-line fallback (along the spawn look direction) for any box a nearby
	-- anchor did not cover.
	local forward = Vector3.new(spawnCF.LookVector.X, 0, spawnCF.LookVector.Z)
	if forward.Magnitude < 0.1 then
		forward = Vector3.new(0, 0, 1)
	end
	forward = forward.Unit
	local right = Vector3.new(forward.Z, 0, -forward.X)

	for i = 1, INTRO.BOX_COUNT do
		local pos: Vector3
		if anchors[i] ~= nil then
			pos = anchors[i] + Vector3.new(0, 2, 0)
		else
			local along = 12 + (i - 1) * 9
			local lateral = (if i % 2 == 0 then 5 else -5)
			pos = spawnPos + forward * along + right * lateral + Vector3.new(0, 2, 0)
		end
		local ok, uid = pcall(caseService.SpawnCaseAt, 3, pos, "Rare")
		if ok and type(uid) == "string" then
			table.insert(uids, uid)
		end
	end
	return uids
end

--------------------------------------------------------------------------------
-- Bespoke non-lethal chaser. A lightweight standalone humanoid model (NEVER
-- DefectService internals). MoveTo's toward the player, biased to herd toward
-- the exit. NEVER touches the player's Humanoid.Health and NEVER calls
-- ShiftService.DownPlayer — on contact it just backs off. Destroyed at teardown.
--------------------------------------------------------------------------------

type Chaser = { model: Model, stop: () -> () }

local function spawnChaser(
	parent: Instance,
	startPos: Vector3,
	getTarget: () -> Vector3?,
	onContact: (() -> ())?
): Chaser
	-- Use the REAL Defect visual (torso/head/dragging arms/mismatched glowing
	-- eyes/red glow) so the chaser reads as a monster, not a glowing box. The
	-- model carries NO AI and is not Defect-tagged, so we drive it ourselves.
	local model: Model? = nil
	local humanoid: Humanoid? = nil
	local defect = getSibling("DefectService")
	if defect ~= nil and type(defect.BuildCosmeticModel) == "function" then
		local ok, m, h = pcall(defect.BuildCosmeticModel, CFrame.new(startPos + Vector3.new(0, 5, 0)))
		if ok and typeof(m) == "Instance" and m:IsA("Model") then
			model = m
			humanoid = h
		end
	end

	if model == nil then
		-- Fallback only if DefectService is unavailable: a simple dark hulk (still
		-- humanoid-shaped, never a neon box).
		local m = Instance.new("Model")
		m.Name = "IntroChaser"
		local r = Instance.new("Part")
		r.Name = "HumanoidRootPart"
		r.Size = Vector3.new(4, 6, 2)
		r.Color = Color3.fromRGB(120, 30, 30)
		r.Material = Enum.Material.SmoothPlastic
		r.CFrame = CFrame.new(startPos + Vector3.new(0, 5, 0))
		r.Parent = m
		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(255, 60, 40)
		glow.Brightness = 1.4
		glow.Range = 18
		glow.Parent = r
		local h = Instance.new("Humanoid")
		h.Parent = m
		m.PrimaryPart = r
		model = m
		humanoid = h
	end

	local liveModel = model :: Model
	local liveHumanoid = (humanoid or liveModel:FindFirstChildOfClass("Humanoid")) :: Humanoid
	liveHumanoid.WalkSpeed = INTRO.CHASER_SPEED
	liveModel.Parent = parent

	-- A snarl on spawn (the real model carries a Roar sound under its head).
	local roar = liveModel:FindFirstChild("Roar", true)
	if roar ~= nil and roar:IsA("Sound") then
		pcall(function()
			(roar :: Sound):Play()
		end)
	end

	local root = liveModel.PrimaryPart :: BasePart
	local alive = true
	local backoffUntil = 0

	task.spawn(function()
		while alive and liveModel.Parent ~= nil do
			local target = getTarget()
			if target ~= nil then
				local now = os.clock()
				local planar = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
				if planar.Magnitude <= CHASER_CONTACT_RADIUS then
					-- Non-lethal contact: encourage the kid (once per backoff), then
					-- back off briefly so they are never pinned. NEVER harms them.
					if now >= backoffUntil and onContact ~= nil then
						pcall(onContact)
					end
					backoffUntil = now + CHASER_BACKOFF_SECONDS
				end
				local goal: Vector3
				if now < backoffUntil then
					-- Retreat a little so the kid is never pinned.
					local away = Vector3.new(root.Position.X - target.X, 0, root.Position.Z - target.Z)
					if away.Magnitude < 1 then
						away = Vector3.new(0, 0, 1)
					end
					goal = root.Position + away.Unit * 8
				else
					-- Pure pursuit: chase the player's position only. We deliberately do
					-- NOT lead toward the exit (that could cut the chaser between the
					-- kid and the green door); running to the door always escapes.
					goal = target
				end
				liveHumanoid.WalkSpeed = INTRO.CHASER_SPEED
				liveHumanoid:MoveTo(Vector3.new(goal.X, root.Position.Y, goal.Z))
			end
			task.wait(CHASER_STEP_SECONDS)
		end
	end)

	local function stop()
		if not alive then
			return
		end
		alive = false
		liveModel:Destroy()
	end

	return { model = liveModel, stop = stop }
end

--------------------------------------------------------------------------------
-- Profile mutation helpers (WithLock + Update idiom, WelcomeService lines 124-142).
--------------------------------------------------------------------------------

-- Builds a banked CaseStub for one carried intro box (guaranteed Rare; source
-- "bundle" is valid per LockerService.VALID_SOURCES — same as the starter box).
local function buildIntroStub(): Types.CaseStub
	return {
		uid = HttpService:GenerateGUID(false),
		tier = 3,
		lineId = RarityTable.LINE_ID,
		acquiredAt = os.time(),
		source = "bundle" :: Types.CaseSource,
		guaranteedRarity = "Rare",
	}
end

-- Graceful-failure flag write: introFloorDone = true, introBoxesBanked LEFT
-- false. WelcomeService then grants the normal free starter box and the welcome
-- panel proceeds (shouldShow now passes since introFloorDone == true).
local function markFloorDoneOnly(player: Player)
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or type(dataService.WithLock) ~= "function" then
		return
	end
	pcall(function()
		dataService.WithLock(player, function()
			if type(dataService.Update) == "function" then
				dataService.Update(player, function(d: Types.ProfileData)
					d.onboarding.introFloorDone = true
				end)
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- The scripted run. Wrapped in pcall by the caller; on ANY error the caller does
-- the graceful-failure teardown. Holds NO WithLock across the whole run — only
-- the final bank Update sits inside a lock.
--------------------------------------------------------------------------------

local function runIntro(player: Player)
	local caseService = getSibling("CaseService")
	local floorGen = getSibling("FloorGenService")
	if floorGen == nil or type(floorGen.Generate) ~= "function" then
		error("FloorGenService.Generate unavailable")
	end

	local seed = player.UserId
	local introId = HttpService:GenerateGUID(false)

	-- 3) Build the dedicated out-of-pool floor (MUST pass sessionId).
	local handle = floorGen.Generate(seed, {
		origin = INTRO_ORIGIN,
		sessionId = introId,
		lightDensityScale = 1,
	})

	-- Bound the whole run so a wedged step can never strand the player.
	local runDeadline = os.clock() + RUN_HARD_TIMEOUT_SECONDS
	local banked = false

	local exitPos: Vector3? = nil
	if handle.extractZone ~= nil and (handle.extractZone :: BasePart):IsA("BasePart") then
		exitPos = (handle.extractZone :: BasePart).Position
		-- Tag the real dock so the client's exit "north-star" beacon attaches to it
		-- (the dock is tagged ExtractionDock by FloorGenService, which the client
		-- guide does not look for — IntroExit is the contract it watches).
		pcall(function()
			CollectionService:AddTag(handle.extractZone, TAG_INTRO_EXIT)
		end)
	end

	-- Track which intro boxes the player has actually carried.
	local introUids: { string } = {}
	local carried: { [string]: boolean } = {}
	local got = 0

	-- Local teardown shared by every exit path of this function.
	local chaser: Chaser? = nil
	local function teardown()
		if chaser ~= nil then
			chaser.stop()
			chaser = nil
		end
		player:SetAttribute("CarrySpeedExempt", nil)
		if caseService ~= nil and type(caseService.ClearShift) == "function" then
			pcall(caseService.ClearShift, handle.model)
		end
		pcall(function()
			handle:Destroy()
		end)
	end

	local ok, err = pcall(function()
		-- 4) Place the glowing Rare boxes.
		introUids = gatherIntroBoxes(handle)

		-- 5) Carry-speed exemption for the whole run (carrying never drops the
		-- player below CHASER_SPEED, so the chase stays un-loseable).
		player:SetAttribute("CarrySpeedExempt", true)

		-- 6) ENTER teleport (mandatory idiom), then the enter beat. The character
		-- loads asynchronously (CharacterAutoLoads=false), so the profile can be
		-- ready before the HumanoidRootPart exists — wait for it, else the kid
		-- would sit in the HUB while the floor runs 13000 studs away.
		local entered = executePivot(player, handle.spawnCFrame)
		if not entered then
			local waited = 0
			while not entered and waited < 8 and running[player] == true do
				task.wait(0.25)
				waited += 0.25
				entered = executePivot(player, handle.spawnCFrame)
			end
		end
		if not entered then
			error("character never materialized for the intro enter teleport")
		end
		fireBeat(player, "enter")

		-- 7) PICKUP loop: server-authoritative proximity pickup of the intro boxes.
		while running[player] == true and got < INTRO.BOXES_NEEDED do
			if os.clock() > runDeadline then
				break
			end
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root ~= nil and root:IsA("BasePart") and caseService ~= nil and type(caseService.ServerPickup) == "function" then
				for _, uid in introUids do
					if not carried[uid] then
						-- Proximity gate: resolve the live box position via CaseService
						-- (the case model lives under the cases folder, not handle.model,
						-- and the uid attribute is on the Model — GetCasePosition handles
						-- both). ServerPickup is server-authoritative and returns true
						-- only when it actually committed the carry.
						local boxPos: Vector3? = nil
						if type(caseService.GetCasePosition) == "function" then
							local okPos, p = pcall(caseService.GetCasePosition, uid)
							if okPos and typeof(p) == "Vector3" then
								boxPos = p
							end
						end
						-- PLANAR (XZ) distance: the enter teleport lifts the character a
						-- few studs, so a 3D check could keep "standing on a box" just
						-- out of range. Flat distance makes walking onto a box reliable.
						local planarToBox = math.huge
						if boxPos ~= nil then
							local bp = boxPos :: Vector3
							planarToBox = math.sqrt((root.Position.X - bp.X) ^ 2 + (root.Position.Z - bp.Z) ^ 2)
						end
						if boxPos ~= nil and planarToBox <= INTRO.PICKUP_RADIUS then
							local okPick, committed = pcall(caseService.ServerPickup, player, uid)
							if okPick and committed == true then
								carried[uid] = true
								got += 1
								fireBeat(player, "grabbed", { boxesGot = got, boxesNeeded = INTRO.BOXES_NEEDED })
							end
						end
					end
				end
			end
			task.wait(PICKUP_POLL_SECONDS)
		end

		if running[player] ~= true then
			error("player left during pickup")
		end

		-- 8) Chase: telegraph -> start -> spawn the chaser behind the player.
		fireBeat(player, "chaseTelegraph")
		task.wait(CHASE_TELEGRAPH_SECONDS)
		fireBeat(player, "chaseStart")

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			-- Spawn the chaser on the FAR side of the player from the exit, so the
			-- green door is always the direction AWAY from danger (never have the
			-- chaser between the kid and the door). Fall back to "behind" if no exit.
			local awayFromExit: Vector3
			if exitPos ~= nil then
				awayFromExit = Vector3.new(root.Position.X - (exitPos :: Vector3).X, 0, root.Position.Z - (exitPos :: Vector3).Z)
			else
				local back = -(root.CFrame.LookVector)
				awayFromExit = Vector3.new(back.X, 0, back.Z)
			end
			if awayFromExit.Magnitude < 1 then
				awayFromExit = Vector3.new(0, 0, 1)
			end
			local startPos = root.Position + awayFromExit.Unit * INTRO.CHASER_SPAWN_DISTANCE
			chaser = spawnChaser(handle.model, startPos, function(): Vector3?
				local c = player.Character
				local r = c and c:FindFirstChild("HumanoidRootPart")
				if r ~= nil and r:IsA("BasePart") then
					return (r :: BasePart).Position
				end
				return nil
			end, function()
				-- Soft contact: encourage the kid, never harm them.
				fireBeat(player, "bump")
			end)
		end

		-- 9) EXIT: poll continuous dwell inside the extract zone (or a scripted
		-- pad fallback when the floor has none).
		local dwellPart: BasePart? = handle.extractZone
		if dwellPart == nil then
			-- Degraded floor with no dock: build a VISIBLE green exit pad so the kid
			-- still has an obvious goal, and tag it so the client beacon attaches.
			local pad = Instance.new("Part")
			pad.Name = "IntroExitPad"
			pad.Anchored = true
			pad.CanCollide = false
			pad.Transparency = 0.45
			pad.Material = Enum.Material.Neon
			pad.Color = Color3.fromRGB(90, 255, 150)
			pad.Size = Vector3.new(12, 8, 12)
			local padCenter = exitPos
			if padCenter == nil and #handle.dockSpawns > 0 then
				padCenter = handle.dockSpawns[1].Position
			end
			if padCenter == nil then
				padCenter = (handle.spawnCFrame :: CFrame).Position
			end
			pad.CFrame = CFrame.new((padCenter :: Vector3) + Vector3.new(0, 4, 0))
			pad.Parent = handle.model
			pcall(function()
				CollectionService:AddTag(pad, TAG_INTRO_EXIT)
			end)
			dwellPart = pad
			exitPos = pad.Position
		end

		-- The exit phase gets its OWN deadline so a slow pickup phase can never eat
		-- the whole budget and silently auto-skip the "run to the door" lesson.
		local exitDeadline = os.clock() + EXIT_PHASE_TIMEOUT_SECONDS
		local dwellSince: number? = nil
		while running[player] == true do
			if os.clock() > runDeadline or os.clock() > exitDeadline then
				break
			end
			local c = player.Character
			local r = c and c:FindFirstChild("HumanoidRootPart")
			local inZone = false
			if r ~= nil and r:IsA("BasePart") and dwellPart ~= nil then
				local d = (dwellPart :: BasePart)
				local delta = d.CFrame:PointToObjectSpace((r :: BasePart).Position)
				local half = d.Size * 0.5
				inZone = math.abs(delta.X) <= half.X
					and math.abs(delta.Z) <= half.Z
					and math.abs(delta.Y) <= (half.Y + 6)
			end
			if inZone then
				if dwellSince == nil then
					dwellSince = os.clock()
				elseif os.clock() - (dwellSince :: number) >= INTRO.EXIT_DWELL_SECONDS then
					break
				end
			else
				dwellSince = nil
			end
			task.wait(EXIT_POLL_SECONDS)
		end

		if running[player] ~= true then
			error("player left before exit")
		end

		-- Stop the chase the instant they reach the exit.
		if chaser ~= nil then
			chaser.stop()
			chaser = nil
		end
		fireBeat(player, "reachExit")

		-- 10) BANK + SUBSTITUTION in ONE Update inside WithLock.
		local taken: { { uid: string, tier: number, mega: boolean? } } = {}
		if caseService ~= nil and type(caseService.TakeAllCarried) == "function" then
			local okTake, result = pcall(caseService.TakeAllCarried, player)
			if okTake and type(result) == "table" then
				taken = result
			end
		end

		local stubCount = #taken
		if stubCount < INTRO.BOXES_NEEDED then
			-- The kid grabbed too few (or none): still bank BOXES_NEEDED stubs so
			-- they always have boxes to open.
			stubCount = INTRO.BOXES_NEEDED
		end
		local stubs: { Types.CaseStub } = {}
		for _ = 1, stubCount do
			table.insert(stubs, buildIntroStub())
		end

		local dataService = getSibling("PlayerDataService")
		if dataService ~= nil and type(dataService.WithLock) == "function" then
			-- banked is true ONLY if the lock actually ran — otherwise we must fall
			-- through to markFloorDoneOnly so the player still gets the free box.
			local okBank = dataService.WithLock(player, function()
				local locker = getSibling("LockerService")
				if locker ~= nil and type(locker.AddCases) == "function" then
					pcall(locker.AddCases, player, stubs)
				end
				if type(dataService.Update) == "function" then
					dataService.Update(player, function(d: Types.ProfileData)
						d.onboarding.introFloorDone = true
						d.onboarding.introBoxesBanked = true
						d.onboarding.starterCaseGranted = true
					end)
				end
				if locker ~= nil and type(locker.NotifyLockerChanged) == "function" then
					pcall(locker.NotifyLockerChanged, player)
				end
			end)
			banked = okBank == true
		end

		-- 11) EXIT teleport back to the hub spawn (mandatory idiom), then done.
		returnToHub(player)
		fireBeat(player, "done")
	end)

	-- 12) TEARDOWN (every path).
	teardown()

	if ok then
		-- Ran clean, but if the bank could not persist (degraded server: no
		-- PlayerDataService), fall back so the welcome path still grants the free
		-- starter box and the panel can proceed (shouldShow needs introFloorDone).
		if not banked then
			markFloorDoneOnly(player)
		end
	else
		-- GRACEFUL FAILURE: clear the client intro UI, return the kid to the hub
		-- (the floor is now torn down), and if we errored BEFORE banking set
		-- introFloorDone only (introBoxesBanked stays false) so WelcomeService
		-- grants the free starter box and the panel proceeds. Never stranded.
		fireBeat(player, "done")
		returnToHub(player)
		if not banked then
			markFloorDoneOnly(player)
		end
		warn(`[IntroFloorService] intro run for {player.Name} failed: {err}`)
	end
end

--------------------------------------------------------------------------------
-- Scan: eligibility gate (under WithLock) -> spawn the run (NOT under lock).
--------------------------------------------------------------------------------

-- Returns true when this player is settled (never eligible) — the scan stops
-- re-reading them. Returns false + sets running[player]=true when it kicked off
-- a run. Returns false (and does not settle) when the profile raced/dropped.
local function tryStartRun(player: Player, dataService: any): boolean
	local eligible = false
	local resolved = false
	local okLock = dataService.WithLock(player, function()
		local data = dataService.Get(player) :: Types.ProfileData?
		if data == nil then
			return -- dropped mid-flight; retry next tick (not settled)
		end
		resolved = true
		eligible = WelcomeGate.shouldEnterIntro(data.onboarding, data.stats)
	end)

	if not okLock or not resolved then
		return false -- raced/dropped: retry next tick, do not settle
	end
	if not eligible then
		return true -- veteran / already past the intro: settle
	end

	-- Eligible: guard against double-spawn, then run OUTSIDE the lock.
	running[player] = true
	task.spawn(function()
		local okRun = pcall(runIntro, player)
		if not okRun then
			-- runIntro pcalls its own body; this guards an outright crash of the
			-- wrapper itself. Minimal flag write so the player is never stranded.
			markFloorDoneOnly(player)
		end
		running[player] = nil
		settled[player] = true
	end)
	return false -- not settled here; the run thread settles on completion
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function IntroFloorService:Init()
	-- Remotes.Get YIELDS, so bind in :Init() only the connect-less event handle is
	-- safe — but to stay consistent with the house rule (connect remotes in Start)
	-- we only RESOLVE the owner-only S->C event here; we never connect to it.
	Players.PlayerRemoving:Connect(function(player: Player)
		settled[player] = nil
		running[player] = nil
	end)
end

function IntroFloorService:Start()
	-- IntroBeat is owner-only S->C: we only FireClient it, never connect. Resolve
	-- the handle in :Start() (GetEvent yields) per the house rule.
	local ok, err = pcall(function()
		introBeatRemote = Remotes.GetEvent("IntroBeat")
	end)
	if not ok then
		warn(`[IntroFloorService] remote bind failed: {err}`)
	end

	while true do
		task.wait(SCAN_INTERVAL_SECONDS)
		local dataService = getSibling("PlayerDataService")
		if dataService == nil or type(dataService.IsLoaded) ~= "function" or type(dataService.WithLock) ~= "function" then
			continue
		end
		for _, player in Players:GetPlayers() do
			if settled[player] == true or running[player] == true then
				continue
			end
			if not dataService.IsLoaded(player) then
				continue -- profile still loading; try next tick
			end
			local doneSettle = tryStartRun(player, dataService)
			if doneSettle then
				settled[player] = true
			end
		end
	end
end

return IntroFloorService
