--!strict
-- CRYPTLINGS: NIGHT SHIFT — OnboardingService (Stage 2, module onboarding-first-shift).
-- SOP §3.2: NO tutorial screens — a ~30-second scripted beat inside the player's
-- real first shift teaches everything. Runs only for profiles with
-- stats.firstShiftDone == false (veterans see nothing). Sequence (OnboardingBeat
-- remote, contract B; analytics onboarding_beat{beat} per beat, contract H):
--
--   ClockIn          on first-shift spawn (subtitle text provided server-side)
--   ForemanLine      t+3s — the foreman PA line (verbatim from the stage spec)
--   FirstCase        t+10s — picks the guaranteed Tier1 case nearest the dock
--                    (FloorGen's TIME_TO_FIRST_CASE guarantee, §G) and attaches a
--                    greybox beacon: highlight Part + Attachment beam. Beat
--                    carries the case position (time-to-fun <= 90s, §3.2).
--   DefectFlyby      after their first pickup, at t+~60s —
--                    DefectService.PlayFlyby(player) (scripted NON-aggro pass,
--                    contract I) + the beat.
--   FirstExtraction  ~5s later — beat carries the dock position (client renders
--                    the soft directional arrow).
--   Done             on extraction — stats.firstShiftDone = true, beat carries
--                    freeOpens so the client can pulse the Locker tab chip
--                    ("open your case" — first unboxing within session 1, §3.2:
--                    3 free opens/day; R2 Addendum 1 Change 4: physical lockers
--                    are gone, the on-screen tab is the sole entry point).
--
-- Hard 120s failsafe: any beat stuck longer than BEAT_FAILSAFE_SECONDS advances
-- anyway, and a shift that ends mid-session fast-forwards the remaining beats —
-- every started session reaches Done unless the player leaves, so nobody is
-- re-onboarded forever by an unlucky first run.
--
-- Public API (siblings may pcall this):
--   OnboardingService.IsOnboarding(player) -> boolean
--
-- Optional siblings consumed via pcall (degrade gracefully when absent):
--   ShiftService.IsActive/IsParticipant/HasExtracted/GetFloorRoot
--     (+ R2 additive GetSessionOf/GetFloorRootFor, preferred when present —
--     Lobby SOP Addendum 1 Change 6.5 / WP4.3: floor + activity reads are
--     scoped to the PLAYER's own session under concurrent floors)
--   CaseService.GetCarriedCount(player)
--   DefectService.PlayFlyby(player)
--   FloorGenService.GetExtractZone() -> BasePart?
--   PlayerDataService.Get/Update · AnalyticsService.Track

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

--------------------------------------------------------------------------------
-- Tuning — beat timings promoted to GameConstants (no-magic-numbers rule)
--------------------------------------------------------------------------------

local FOREMAN_LINE_AT_SECONDS = GameConstants.ONBOARDING_FOREMAN_LINE_AT_SECONDS -- ClockIn -> ForemanLine
local FIRST_CASE_AT_SECONDS = GameConstants.ONBOARDING_FIRST_CASE_AT_SECONDS -- spec: FirstCase at t+10s
local FLYBY_AT_SECONDS = GameConstants.ONBOARDING_FLYBY_AT_SECONDS -- spec: flyby at t+~60s (after first pickup)
local FLYBY_TO_EXTRACTION_SECONDS = GameConstants.ONBOARDING_FLYBY_TO_EXTRACTION_SECONDS
local BEAT_FAILSAFE_SECONDS = GameConstants.ONBOARDING_BEAT_FAILSAFE_SECONDS
local SCAN_INTERVAL_SECONDS = 1
local POLL_INTERVAL_SECONDS = 0.25
local BEACON_HEIGHT_STUDS = 26
local BEACON_COLOR = Color3.fromRGB(235, 190, 52) -- guidance gold (§E Godly accent)

-- Server-side subtitle copy (spec: text provided server-side; the client only
-- renders). The ForemanLine text is verbatim from the stage spec.
local TEXT_CLOCK_IN = "NIGHT SHIFT — CLOCKED IN."
local TEXT_FOREMAN_LINE = "New hire! Grab a case, keep it quiet, and clock out at the dock. Don't meet the night staff."
local TEXT_FIRST_CASE = "There — your first case. Grab it."
local TEXT_DEFECT_FLYBY = "Quiet! That's the night staff. Don't get heard."
local TEXT_FIRST_EXTRACTION = "Now clock out — get that case to the dock."
-- R2 (Addendum 1 Change 4 / WP4.3): points at the on-screen Locker tab — the
-- physical locker bank no longer exists.
local TEXT_DONE = "Good work, new hire. Your case is in your locker — open it from your Locker tab."

-- CollectionService tags shared with CaseService / FloorGenService / ShiftService.
local TAG_CASE = "Case"
local TAG_EXTRACTION_DOCK = "ExtractionDock"

--------------------------------------------------------------------------------
-- Lazy sibling resolution (pcall-require; missing modules degrade gracefully)
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
-- State
--------------------------------------------------------------------------------

type Session = {
	player: Player,
	startedClock: number,
	beacon: Folder?,
	caseAttachment: Attachment?,
}

local OnboardingService = {}

local sessions: { [Player]: Session } = {}
-- In-memory veteran/finished cache so the scan loop stops reading profiles for
-- players who will never onboard again this server.
local settled: { [Player]: boolean } = {}

local onboardingBeatRemote: RemoteEvent? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

function OnboardingService.IsOnboarding(player: Player): boolean
	return sessions[player] ~= nil
end

-- R2 (WP4.3): with concurrent sessions, "the shift" is the PLAYER's session —
-- preferred via the additive GetSessionOf facade when a player is given; the
-- global any-session aggregate keeps the legacy behavior otherwise.
local function isShiftActive(player: Player?): boolean
	local shift = getSibling("ShiftService")
	if shift == nil then
		return false
	end
	if player ~= nil and type(shift.GetSessionOf) == "function" then
		local ok, session = pcall(shift.GetSessionOf, player)
		if ok then
			return session ~= nil and (session :: any).state == "Active"
		end
	end
	return type(shift.IsActive) == "function" and shift.IsActive() == true
end

local function hasExtracted(player: Player): boolean
	local shift = getSibling("ShiftService")
	return shift ~= nil and type(shift.HasExtracted) == "function" and shift.HasExtracted(player) == true
end

local function getCarriedCount(player: Player): number
	local caseService = getSibling("CaseService")
	if caseService ~= nil and type(caseService.GetCarriedCount) == "function" then
		local ok, count = pcall(caseService.GetCarriedCount, player)
		if ok and type(count) == "number" then
			return count
		end
	end
	return 0
end

local function toPositionArray(position: Vector3): { number }
	return { position.X, position.Y, position.Z }
end

-- skipTrack: beacon retargets re-fire FirstCase with a new position; the client
-- just moves its marker and the analytics event stays one-per-beat.
local function fireBeat(session: Session, beat: string, extra: { [string]: any }?, skipTrack: boolean?)
	local payload: { [string]: any } = { beat = beat }
	if extra ~= nil then
		for key, value in extra do
			payload[key] = value
		end
	end
	if onboardingBeatRemote ~= nil and session.player.Parent ~= nil then
		onboardingBeatRemote:FireClient(session.player, payload)
	end
	if skipTrack ~= true then
		track(session.player, "onboarding_beat", { beat = beat })
	end
end

-- Waits for pred() with the hard failsafe. Returns:
--   "ok"          pred satisfied
--   "timeout"     failsafe elapsed — caller advances the beat anyway (spec)
--   "fastforward" shift ended mid-session — caller rushes the remaining beats
--   "gone"        player left — caller aborts
local function sessionWaitUntil(session: Session, pred: () -> boolean, timeoutSeconds: number): string
	local deadline = os.clock() + timeoutSeconds
	while true do
		if session.player.Parent == nil then
			return "gone"
		end
		if pred() then
			return "ok"
		end
		if not isShiftActive(session.player) then
			return "fastforward"
		end
		if os.clock() >= deadline then
			return "timeout"
		end
		task.wait(POLL_INTERVAL_SECONDS)
	end
end

local function sessionWait(session: Session, seconds: number): string
	local result = sessionWaitUntil(session, function()
		return false
	end, seconds)
	return if result == "timeout" then "ok" else result
end

--------------------------------------------------------------------------------
-- Dock & case targeting
--------------------------------------------------------------------------------

local function getDockPosition(player: Player): Vector3?
	-- R2 (WP4.3): prefer the PLAYER's own session floor (GetFloorRootFor) so a
	-- concurrent neighbor floor's dock is never targeted; the legacy global
	-- GetFloorRoot read is the fallback when the facade lacks the additive API.
	local shift = getSibling("ShiftService")
	local floorRoot: Instance? = nil
	if shift ~= nil then
		if type(shift.GetFloorRootFor) == "function" then
			local ok, root = pcall(shift.GetFloorRootFor, player)
			if ok and typeof(root) == "Instance" then
				floorRoot = root
			end
		end
		if floorRoot == nil and type(shift.GetFloorRoot) == "function" then
			local ok, root = pcall(shift.GetFloorRoot)
			if ok and typeof(root) == "Instance" then
				floorRoot = root
			end
		end
	end
	if floorRoot ~= nil then
		for _, instance in CollectionService:GetTagged(TAG_EXTRACTION_DOCK) do
			if
				instance:IsA("BasePart")
				and instance:IsDescendantOf(Workspace)
				and instance:IsDescendantOf(floorRoot)
			then
				return instance.Position
			end
		end
	end

	-- Legacy fallbacks (no facade floor): the single-floor FloorGen shim, then
	-- any live tagged dock — exactly the pre-R2 behavior.
	local floorGen = getSibling("FloorGenService")
	if floorGen ~= nil and type(floorGen.GetExtractZone) == "function" then
		local ok, zone = pcall(floorGen.GetExtractZone)
		if ok and typeof(zone) == "Instance" and zone:IsA("BasePart") then
			return zone.Position
		end
	end
	for _, instance in CollectionService:GetTagged(TAG_EXTRACTION_DOCK) do
		if instance:IsA("BasePart") and instance:IsDescendantOf(Workspace) then
			return instance.Position
		end
	end
	return nil
end

local function getCaseBody(model: Model): BasePart?
	local primary = model.PrimaryPart
	if primary ~= nil then
		return primary
	end
	return model:FindFirstChildWhichIsA("BasePart")
end

-- Carried cases are parented under the holder's character (CaseService contract:
-- "descendant of a character" == carried); world cases live in the cases folder.
local function isWorldCase(model: Model): boolean
	local parent = model.Parent
	return parent ~= nil and parent:FindFirstChildOfClass("Humanoid") == nil
end

-- The guaranteed first case (§G / FloorGen guarantee): the Tier1 world case
-- nearest `referencePosition` (the dock). Falls back to the nearest case of any
-- tier so onboarding still points somewhere on a degenerate floor.
local function findFirstCaseTarget(referencePosition: Vector3): (Model?, Vector3?)
	local bestTier1: Model? = nil
	local bestTier1Position: Vector3? = nil
	local bestTier1Distance = math.huge
	local bestAny: Model? = nil
	local bestAnyPosition: Vector3? = nil
	local bestAnyDistance = math.huge

	for _, instance in CollectionService:GetTagged(TAG_CASE) do
		if instance:IsA("Model") and instance:IsDescendantOf(Workspace) and isWorldCase(instance) then
			local body = getCaseBody(instance)
			if body ~= nil then
				local distance = (body.Position - referencePosition).Magnitude
				if distance < bestAnyDistance then
					bestAny = instance
					bestAnyPosition = body.Position
					bestAnyDistance = distance
				end
				if instance:GetAttribute("CaseTier") == 1 and distance < bestTier1Distance then
					bestTier1 = instance
					bestTier1Position = body.Position
					bestTier1Distance = distance
				end
			end
		end
	end

	if bestTier1 ~= nil then
		return bestTier1, bestTier1Position
	end
	return bestAny, bestAnyPosition
end

--------------------------------------------------------------------------------
-- Beacon (greybox: highlight Part + Attachment beam over the first case)
--------------------------------------------------------------------------------

local function destroyBeacon(session: Session)
	if session.caseAttachment ~= nil then
		pcall(function()
			(session.caseAttachment :: Attachment):Destroy()
		end)
		session.caseAttachment = nil
	end
	if session.beacon ~= nil then
		pcall(function()
			(session.beacon :: Folder):Destroy()
		end)
		session.beacon = nil
	end
end

local function buildBeacon(session: Session, caseModel: Model)
	destroyBeacon(session)
	local body = getCaseBody(caseModel)
	if body == nil then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = `OnboardingBeacon_{session.player.UserId}`

	-- Highlight shaft: a tall neon column above the case (visible across the floor).
	local shaft = Instance.new("Part")
	shaft.Name = "BeaconShaft"
	shaft.Size = Vector3.new(0.7, BEACON_HEIGHT_STUDS, 0.7)
	shaft.CFrame = CFrame.new(body.Position + Vector3.new(0, BEACON_HEIGHT_STUDS / 2 + 1, 0))
	shaft.Anchored = true
	shaft.CanCollide = false
	shaft.CanQuery = false
	shaft.CanTouch = false
	shaft.Material = Enum.Material.Neon
	shaft.Color = BEACON_COLOR
	shaft.Transparency = 0.35
	shaft.Parent = folder

	local topAttachment = Instance.new("Attachment")
	topAttachment.Name = "BeaconTop"
	topAttachment.Position = Vector3.new(0, BEACON_HEIGHT_STUDS / 2, 0)
	topAttachment.Parent = shaft

	-- Attachment on the case body itself so the beam hugs the case even as it
	-- wobbles (CaseService's squirm jitter).
	local caseAttachment = Instance.new("Attachment")
	caseAttachment.Name = "OnboardingBeaconAttachment"
	caseAttachment.Parent = body

	local beam = Instance.new("Beam")
	beam.Attachment0 = caseAttachment
	beam.Attachment1 = topAttachment
	beam.Width0 = 2.5
	beam.Width1 = 0.4
	beam.Color = ColorSequence.new(BEACON_COLOR)
	beam.Transparency = NumberSequence.new(0.15)
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Parent = shaft

	folder.Parent = Workspace
	session.beacon = folder
	session.caseAttachment = caseAttachment
end

--------------------------------------------------------------------------------
-- The scripted first shift
--------------------------------------------------------------------------------

-- Marks the profile and returns the free opens remaining today (§3.2: "they
-- have 3 free opens" — new accounts have used none, but compute it anyway).
local function markFirstShiftDone(player: Player): number
	local freeOpens = GameConstants.FREE_OPENS_PER_DAY
	local dataService = getSibling("PlayerDataService")
	if dataService ~= nil and type(dataService.Update) == "function" then
		local saved = dataService.Update(player, function(data)
			data.stats.firstShiftDone = true
			freeOpens = math.max(0, GameConstants.FREE_OPENS_PER_DAY - data.locker.freeOpensUsed)
		end)
		if saved ~= true then
			warn(`[OnboardingService] could not persist firstShiftDone for {player.Name} (profile not loaded?)`)
		end
	end
	return freeOpens
end

-- Runs the whole beat sequence. Returns true when the session reached Done
-- (false only when the player left mid-session).
local function runSession(session: Session): boolean
	local player = session.player
	local function elapsed(): number
		return os.clock() - session.startedClock
	end

	-- 1) ClockIn: on first-shift spawn.
	fireBeat(session, "ClockIn", { text = TEXT_CLOCK_IN })
	if sessionWait(session, FOREMAN_LINE_AT_SECONDS) == "gone" then
		return false
	end

	-- 2) ForemanLine: the PA line (server-side text, spec-verbatim).
	fireBeat(session, "ForemanLine", { text = TEXT_FOREMAN_LINE })
	local stepResult = sessionWaitUntil(session, function()
		return elapsed() >= FIRST_CASE_AT_SECONDS
	end, FIRST_CASE_AT_SECONDS + 1)
	if stepResult == "gone" then
		return false
	end

	-- 3) FirstCase: guaranteed Tier1 nearest the dock, beacon attached, position
	-- in the payload (the crew spawns AT the dock, so this case is reachable
	-- well inside TIME_TO_FIRST_CASE_SECONDS).
	local character = player.Character
	local characterPivot = if character ~= nil then character:GetPivot().Position else Vector3.zero
	local referencePosition = getDockPosition(player) or characterPivot
	local targetCase, targetPosition = findFirstCaseTarget(referencePosition)
	if targetCase ~= nil then
		buildBeacon(session, targetCase)
	end
	fireBeat(session, "FirstCase", {
		text = TEXT_FIRST_CASE,
		position = if targetPosition ~= nil then toPositionArray(targetPosition) else nil,
	})

	-- Wait for THEIR first pickup (any case counts); keep the beacon glued to a
	-- valid world case if someone else grabs the highlighted one.
	stepResult = sessionWaitUntil(session, function()
		if getCarriedCount(player) > 0 then
			return true
		end
		if targetCase == nil or targetCase.Parent == nil or not isWorldCase(targetCase :: Model) then
			local newCase, newPosition = findFirstCaseTarget(referencePosition)
			if newCase ~= nil and newCase ~= targetCase then
				targetCase = newCase
				buildBeacon(session, newCase)
				fireBeat(session, "FirstCase", {
					text = TEXT_FIRST_CASE,
					position = if newPosition ~= nil then toPositionArray(newPosition) else nil,
				}, true)
			end
		end
		return false
	end, BEAT_FAILSAFE_SECONDS)
	destroyBeacon(session)
	if stepResult == "gone" then
		return false
	end

	-- 4) DefectFlyby at t+~60s: the scripted non-aggro pass (the "first
	-- jump-scare within 90 seconds" half of the §3.2 time-to-fun gate).
	if stepResult == "ok" then -- only pace toward t+60 when the flow is on rails
		stepResult = sessionWaitUntil(session, function()
			return elapsed() >= FLYBY_AT_SECONDS
		end, BEAT_FAILSAFE_SECONDS)
		if stepResult == "gone" then
			return false
		end
	end
	if isShiftActive(player) then
		local defectService = getSibling("DefectService")
		if defectService ~= nil and type(defectService.PlayFlyby) == "function" then
			pcall(defectService.PlayFlyby, player)
		end
	end
	fireBeat(session, "DefectFlyby", { text = TEXT_DEFECT_FLYBY })
	if sessionWait(session, FLYBY_TO_EXTRACTION_SECONDS) == "gone" then
		return false
	end

	-- 5) FirstExtraction: point them at the dock.
	local dockPosition = getDockPosition(player)
	fireBeat(session, "FirstExtraction", {
		text = TEXT_FIRST_EXTRACTION,
		position = if dockPosition ~= nil then toPositionArray(dockPosition) else nil,
	})
	stepResult = sessionWaitUntil(session, function()
		return hasExtracted(player)
	end, BEAT_FAILSAFE_SECONDS)
	if stepResult == "gone" then
		return false
	end

	-- 6) Done: persist, then hand the client the locker hint (one-time "open
	-- your case" pulse — first unboxing within session 1, §3.2).
	local freeOpens = markFirstShiftDone(player)
	fireBeat(session, "Done", { text = TEXT_DONE, freeOpens = freeOpens })
	return true
end

local function startSession(player: Player)
	local session: Session = {
		player = player,
		startedClock = os.clock(),
		beacon = nil,
		caseAttachment = nil,
	}
	sessions[player] = session
	task.spawn(function()
		local ok, finished = pcall(runSession, session)
		destroyBeacon(session)
		if sessions[player] == session then
			sessions[player] = nil
		end
		if not ok then
			warn(`[OnboardingService] session for {player.Name} failed: {finished}`)
		elseif finished == true then
			settled[player] = true
		end
	end)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function OnboardingService:Init()
	local ok, err = pcall(function()
		onboardingBeatRemote = Remotes.GetEvent("OnboardingBeat")
	end)
	if not ok then
		warn(`[OnboardingService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		settled[player] = nil
		local session = sessions[player]
		if session ~= nil then
			-- The session thread notices player.Parent == nil within one poll
			-- tick and exits; reclaim the world objects immediately anyway.
			destroyBeacon(session)
		end
	end)
end

function OnboardingService:Start()
	-- First-shift detector: a fresh profile (stats.firstShiftDone == false) that
	-- is spawned into an active shift starts the scripted beat. Veterans are
	-- cached into `settled` after one profile read and never scanned again.
	while true do
		task.wait(SCAN_INTERVAL_SECONDS)
		local shift = getSibling("ShiftService")
		if shift == nil or type(shift.IsActive) ~= "function" or not shift.IsActive() then
			continue
		end
		local dataService = getSibling("PlayerDataService")
		if dataService == nil or type(dataService.Get) ~= "function" then
			continue
		end
		for _, player in Players:GetPlayers() do
			if sessions[player] ~= nil or settled[player] == true then
				continue
			end
			if type(shift.IsParticipant) ~= "function" or not shift.IsParticipant(player) then
				continue
			end
			if hasExtracted(player) then
				continue
			end
			local data = dataService.Get(player)
			if data == nil then
				continue -- profile still loading; try next tick
			end
			if data.stats.firstShiftDone == true then
				settled[player] = true -- veteran: sees nothing, ever (§3.2)
				continue
			end
			startSession(player)
		end
	end
end

return OnboardingService
