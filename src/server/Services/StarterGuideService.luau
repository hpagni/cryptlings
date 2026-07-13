--!strict
-- CRYPTLINGS: NIGHT SHIFT — StarterGuideService (R8, server lane).
-- Sibling of WelcomeService. Owns the TWO server-authoritative teleports of the
-- first-time STARTER GUIDE (R8_TUTORIAL_SOP.md §3). The CLIENT never sets a CFrame;
-- it only REQUESTS a teleport at the correct step. The server validates, then moves
-- the character with character:PivotTo (NEVER TeleportService, NEVER root.CFrame=).
--
-- Two C->S RemoteFunctions, each returns { ok: boolean, err: string? }:
--   StarterGuide.TeleportToLot     -> pivot to LobbyPlotService.GetPlotForPlayer().stationCFrame
--   StarterGuide.TeleportToClockIn -> pivot to HubService.GetClockInZone().CFrame; persists starterGuideDone
--
-- GATING (fail-closed, server-authoritative; SOP §3.2) — every invoke runs inside
-- PlayerDataService.WithLock and REFUSES unless:
--   profile.onboarding.welcomeShown == true
--   profile.onboarding.starterGuideDone == false   (inert forever once true; no replay)
--   tutorialActive[player] == true                 (per-session; cleared on PlayerRemoving)
--   per-player step cursor matches ("lot" then "clockIn"; out-of-order -> err="OUT_OF_STEP")
-- plus a Bike-idiom rate limit (<=5 / 10s per player) -> err="RATE", cleared on PlayerRemoving.
--
-- ANTI-CHEAT (SOP §3.3, LOAD-BEARING) — for EVERY pivot:
--   pcall RequestStreamAroundAsync(targetPosition)  -- YIELDS; runs BEFORE the pivot
--   pcall BikeService.ForceDismount(player)         -- bike parity (symmetry with the dispatch wall)
--   character:PivotTo(targetCFrame * CFrame.new(0,4,0))
--   pcall ShiftService.NoteServerTeleport(player)   -- SAME THREAD, NO YIELD after the pivot
-- The note re-seeds the movement validator so a future lobby validator can never
-- snap the legitimate tutorial teleport back / speed-flag the player.
--
-- Optional siblings consumed via pcall-require getSibling (degrade gracefully):
--   PlayerDataService.IsLoaded/Get/Update/WithLock, LobbyPlotService.GetPlotForPlayer,
--   HubService.GetClockInZone, ShiftService.NoteServerTeleport, BikeService.ForceDismount

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local SCAN_INTERVAL_SECONDS = 1
local RATE_LIMIT_CALLS = 5 -- Bike idiom (BikeService.luau:73-74)
local RATE_LIMIT_WINDOW_SECONDS = 10
-- Flag-hygiene absolute timeout (SOP §6.3): well beyond any real tutorial session.
-- Beyond this, the once-ever flag is forced done so the teleport remotes can never be
-- replayed. This NEVER moves the player and NEVER simulates an action.
local TUTORIAL_HYGIENE_TIMEOUT_SECONDS = 600

local PIVOT_LIFT = CFrame.new(0, 4, 0) -- mirror ConsumableService exitWarp's +4 studs

--------------------------------------------------------------------------------
-- Lazy sibling resolution (pcall-require; verbatim WelcomeService idiom, lines
-- 47-68). A missing module degrades the feature, never the boot.
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

local StarterGuideService = {}

-- Per-session transient gate. Set lazily when an eligible profile is observed (the
-- welcome gate plus the cursor are sufficient; no separate "start tutorial" remote).
local tutorialActive: { [Player]: boolean } = {}
-- Per-player SERVER step cursor: "lot" -> "clockIn" -> "done".
local cursor: { [Player]: string } = {}
-- Bike sliding-window rate-limit timestamps.
local rate: { [Player]: { number } } = {}
-- First os.clock() at which each player became tutorial-active (for hygiene timeout).
local activeSince: { [Player]: number } = {}
-- Players settled by the Start scan (never re-read).
local settled: { [Player]: boolean } = {}

--------------------------------------------------------------------------------
-- Rate limiting (Bike idiom, BikeService.luau:130-147)
--------------------------------------------------------------------------------

local function consumeRateToken(player: Player): boolean
	local clock = os.clock()
	local times = rate[player]
	if times == nil then
		times = {}
		rate[player] = times
	end
	for index = #times, 1, -1 do
		if clock - times[index] > RATE_LIMIT_WINDOW_SECONDS then
			table.remove(times, index)
		end
	end
	if #times >= RATE_LIMIT_CALLS then
		return false
	end
	table.insert(times, clock)
	return true
end

--------------------------------------------------------------------------------
-- Shared fail-closed gate. MUST be called inside PlayerDataService.WithLock so a
-- concurrent rejoin/handler can never interleave the read with the cursor advance.
--------------------------------------------------------------------------------

local function gateOpen(player: Player, dataService: any, expectedCursor: string): (boolean, string?)
	if type(dataService.IsLoaded) ~= "function" or not dataService.IsLoaded(player) then
		return false, "NOT_LOADED"
	end
	local data = dataService.Get(player) :: Types.ProfileData?
	if data == nil then
		return false, "NO_PROFILE"
	end
	if data.onboarding.welcomeShown ~= true then
		return false, "OUT_OF_STEP"
	end
	if data.onboarding.starterGuideDone ~= false then
		return false, "OUT_OF_STEP"
	end
	-- Lazily activate the tutorial session the first time an eligible profile
	-- invokes, so a legitimate teleport never depends on the slow scan having
	-- seeded tutorialActive yet. (At join the scan can observe welcomeShown ==
	-- false and must NOT settle the player; once WelcomeService flips
	-- welcomeShown true the very next invoke activates here regardless of timing.)
	if tutorialActive[player] ~= true then
		tutorialActive[player] = true
		if activeSince[player] == nil then
			activeSince[player] = os.clock()
		end
	end
	if (cursor[player] or "lot") ~= expectedCursor then
		return false, "OUT_OF_STEP"
	end
	return true, nil
end

--------------------------------------------------------------------------------
-- Teleport execution (SOP §3.3). RequestStreamAroundAsync YIELDS and MUST run
-- BEFORE the pivot/note pair. NoteServerTeleport runs SAME-THREAD with NO YIELD
-- after PivotTo. Returns (true) on success, or (false, err) before any movement.
--------------------------------------------------------------------------------

local function executePivot(player: Player, targetCFrame: CFrame): (boolean, string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if character == nil or root == nil or not root:IsA("BasePart") then
		return false, "NO_CHARACTER"
	end

	-- (yields ALLOWED here, BEFORE the pivot/note pair)
	pcall(function()
		player:RequestStreamAroundAsync(targetCFrame.Position)
	end)

	-- Bike parity (matches the dispatch wall; the tutorial player is never mounted
	-- but stay symmetric with the rest of the lobby teleport idioms).
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

	return true, nil
end

--------------------------------------------------------------------------------
-- TeleportToLot — honored ONLY when cursor == "lot"; advances cursor to "clockIn".
--------------------------------------------------------------------------------

local function teleportToLot(player: Player): { ok: boolean, err: string? }
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or type(dataService.WithLock) ~= "function" then
		return { ok = false, err = "NO_DATA" }
	end
	if not consumeRateToken(player) then
		return { ok = false, err = "RATE" }
	end

	local result: { ok: boolean, err: string? } = { ok = false, err = "OUT_OF_STEP" }
	local okLock = dataService.WithLock(player, function()
		local open, gateErr = gateOpen(player, dataService, "lot")
		if not open then
			result = { ok = false, err = gateErr }
			return
		end

		local plot = nil
		local lobbyPlot = getSibling("LobbyPlotService")
		if lobbyPlot ~= nil and type(lobbyPlot.GetPlotForPlayer) == "function" then
			local okPlot, info = pcall(lobbyPlot.GetPlotForPlayer, player)
			if okPlot then
				plot = info
			end
		end
		if plot == nil or typeof(plot.stationCFrame) ~= "CFrame" then
			result = { ok = false, err = "NO_PLOT" }
			return
		end

		local moved, moveErr = executePivot(player, plot.stationCFrame :: CFrame)
		if not moved then
			result = { ok = false, err = moveErr }
			return -- do NOT advance the cursor
		end

		cursor[player] = "clockIn"
		result = { ok = true }
	end)

	if not okLock then
		return { ok = false, err = "LOCK" }
	end
	return result
end

--------------------------------------------------------------------------------
-- TeleportToClockIn — honored ONLY when cursor == "clockIn"; advances to "done"
-- AND persists onboarding.starterGuideDone = true (remotes inert forever after).
--------------------------------------------------------------------------------

local function teleportToClockIn(player: Player): { ok: boolean, err: string? }
	local dataService = getSibling("PlayerDataService")
	if dataService == nil or type(dataService.WithLock) ~= "function" then
		return { ok = false, err = "NO_DATA" }
	end
	if not consumeRateToken(player) then
		return { ok = false, err = "RATE" }
	end

	local result: { ok: boolean, err: string? } = { ok = false, err = "OUT_OF_STEP" }
	local okLock = dataService.WithLock(player, function()
		local open, gateErr = gateOpen(player, dataService, "clockIn")
		if not open then
			result = { ok = false, err = gateErr }
			return
		end

		local zone = nil
		local hub = getSibling("HubService")
		if hub ~= nil and type(hub.GetClockInZone) == "function" then
			local okZone, part = pcall(hub.GetClockInZone)
			if okZone then
				zone = part
			end
		end
		if zone == nil or typeof(zone) ~= "Instance" or not zone:IsA("BasePart") then
			result = { ok = false, err = "NO_ZONE" }
			return
		end

		local moved, moveErr = executePivot(player, (zone :: BasePart).CFrame)
		if not moved then
			result = { ok = false, err = moveErr }
			return -- do NOT advance the cursor / persist
		end

		-- Persist completion AFTER the successful pivot. Update is safe inside
		-- WithLock (distinct mutex; WelcomeService idiom, lines 124-142).
		cursor[player] = "done"
		if type(dataService.Update) == "function" then
			dataService.Update(player, function(d: Types.ProfileData)
				d.onboarding.starterGuideDone = true
			end)
		end
		tutorialActive[player] = nil
		activeSince[player] = nil
		result = { ok = true }
	end)

	if not okLock then
		return { ok = false, err = "LOCK" }
	end
	return result
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function StarterGuideService:Init()
	local ok, err = pcall(function()
		Remotes.GetFunction("StarterGuide.TeleportToLot").OnServerInvoke = function(player: Player)
			return teleportToLot(player)
		end
		Remotes.GetFunction("StarterGuide.TeleportToClockIn").OnServerInvoke = function(player: Player)
			return teleportToClockIn(player)
		end
	end)
	if not ok then
		warn(`[StarterGuideService] remote bind failed: {err}`)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		tutorialActive[player] = nil
		cursor[player] = nil
		rate[player] = nil
		activeSince[player] = nil
		settled[player] = nil
	end)
end

-- Slow scan: seed the per-session gate for any eligible profile (welcomeShown &&
-- !starterGuideDone) so the first TeleportToLot is honored, and apply the SOP §6.3
-- absolute-timeout flag-hygiene. Mirrors WelcomeService:Start (lines 168-201).
function StarterGuideService:Start()
	while true do
		task.wait(SCAN_INTERVAL_SECONDS)
		local dataService = getSibling("PlayerDataService")
		if dataService == nil or type(dataService.IsLoaded) ~= "function" then
			continue
		end
		for _, player in Players:GetPlayers() do
			-- Flag-hygiene: a long-stalled tutorial-active player has the once-ever
			-- flag forced done so the remotes can never be replayed. Never moves the
			-- player; never simulates an action.
			if tutorialActive[player] == true then
				local since = activeSince[player]
				if since ~= nil and os.clock() - since > TUTORIAL_HYGIENE_TIMEOUT_SECONDS then
					if type(dataService.Update) == "function" then
						dataService.Update(player, function(d: Types.ProfileData)
							d.onboarding.starterGuideDone = true
						end)
					end
					tutorialActive[player] = nil
					cursor[player] = "done"
					activeSince[player] = nil
					settled[player] = true
				end
				continue
			end

			if settled[player] == true then
				continue
			end
			if not dataService.IsLoaded(player) then
				continue -- profile still loading; try next tick
			end
			local data = dataService.Get(player) :: Types.ProfileData?
			if data == nil then
				continue -- raced/dropped profile; retry next tick
			end
			if data.onboarding.welcomeShown == true and data.onboarding.starterGuideDone == false then
				-- Eligible now: seed the per-session gate + cursor.
				if cursor[player] == nil then
					cursor[player] = "lot"
				end
				tutorialActive[player] = true
				if activeSince[player] == nil then
					activeSince[player] = os.clock()
				end
			elseif
				data.onboarding.starterGuideDone == true
				or (data.stats ~= nil and (data.stats :: any).firstShiftDone == true)
			then
				-- Already complete, OR a veteran who will never be shown the welcome
				-- (WelcomeGate): settle so we stop re-reading their profile every tick.
				settled[player] = true
			end
			-- else: brand-new player whose welcome hasn't fired yet (welcomeShown
			-- false, firstShiftDone false) — do NOT settle; keep scanning until
			-- WelcomeService flips welcomeShown true, then seed on the next tick.
		end
	end
end

return StarterGuideService
