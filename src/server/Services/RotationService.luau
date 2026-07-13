--!strict
-- CRYPTLINGS: NIGHT SHIFT — RotationService (Stage 3 "Locker + 3-free-opens/day",
-- module rotation-countdown; SOP §3.3, §1.2, §3.1 ③).
-- The authority for time-based live-ops:
--   * Nightly floor rotation (§3.3 "nightly floor rotation"): the rotation seed
--     IS the unix day, so every server on Earth flips floors at the same moment
--     (00:00 UTC) with zero coordination. ShiftService already prefers
--     RotationService.GetNightlySeed() via pcall (Stage 1 contract) and mixes a
--     per-shift counter on top, so the NEXT intermission after a day flip picks
--     up the new floor automatically — no push needed from this module.
--   * Toy-line countdown (§1.2 Adopt-Me egg-cycle model, §3.3 "toy-line
--     countdown timer on the hub wall"): GetToyLineEndsAt() honours the live-ops
--     override Flags.toyLineEndsAt when set (>0), else derives the next boundary
--     of a fixed epoch-anchored TOYLINE_SEASON_SECONDS grid — deterministic
--     across servers with no DataStore or MessagingService involved.
--   * CountdownSync broadcast (contract §B): {toyLineEndsAt, nightlyRotationAt}
--     to all clients every 30s, to each new joiner immediately, and once extra
--     the instant the unix day flips mid-server (so wall/HUD timers correct
--     fast). CountdownUI renders the wall, the <24h FOMO chip (§4.3: timers are
--     allowed; hiding odds is not) and the client-side "factory floor is
--     rearranging" announcement when nightlyRotationAt passes.
--
-- Public API (contract I / Stage 1 ShiftService hook):
--   RotationService.GetNightlySeed() -> number       -- floor(os.time()/86400), the unix day
--   RotationService.GetNightlyRotationAt(now?) -> number -- (unixDay+1)*86400 (next 00:00 UTC)
--   RotationService.GetToyLineEndsAt(now?) -> number  -- Flags override or season-grid boundary
--
-- Pure time math is argument-injectable (now?) so TestEZ can simulate day flips
-- without stubbing os.time.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local Flags = require(Shared:WaitForChild("Economy"):WaitForChild("Flags"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

--------------------------------------------------------------------------------
-- Tuning (Stage-3 local; SYNC interval is fixed by contract §B)
--------------------------------------------------------------------------------

local SYNC_INTERVAL_SECONDS = 30 -- contract §B: CountdownSync "every 30s" (contract-fixed, not tunable)
local DAY_FLIP_POLL_SECONDS = 1 -- how often the loop checks for the unix-day flip

-- Season-grid anchor (2026-01-01T00:00:00Z) lives in GameConstants
-- (§G TOYLINE_EPOCH_ANCHOR — the §5.4 live-ops calendar reads the same value).
-- Toy-line boundaries fall at anchor + k * TOYLINE_SEASON_SECONDS, identical on
-- every server forever, with no cross-server coordination.

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local RotationService = {}

local countdownSyncRemote: RemoteEvent? = nil
local lastUnixDay = -1 -- day the loop last saw; -1 until Start

--------------------------------------------------------------------------------
-- Public time math (pure; `now` injectable for tests, defaults to os.time())
--------------------------------------------------------------------------------

-- Stage 1 contract: ShiftService pcalls this and mixes in its per-shift counter.
-- The unix day IS the seed — day-derived, so a mid-server day flip means the
-- next intermission's floor regenerates differently with no extra signalling.
function RotationService.GetNightlySeed(): number
	return Util.UnixDay()
end

-- Next 00:00 UTC after `now` — the moment the nightly seed (and therefore the
-- floor layout pool) rotates. Always strictly in the future.
function RotationService.GetNightlyRotationAt(now: number?): number
	return Util.NextDayBoundary(now)
end

-- Unix time the current toy line leaves (§1.2 egg-cycle wall timer).
-- Flags.toyLineEndsAt (>0) is the live-ops override of record (§4.4 home);
-- otherwise the next boundary of the fixed epoch-anchored season grid —
-- strictly after `now`, identical across all servers.
function RotationService.GetToyLineEndsAt(now: number?): number
	local override = Flags.toyLineEndsAt
	if type(override) == "number" and override > 0 then
		return override
	end
	return Util.NextGridBoundary(GameConstants.TOYLINE_EPOCH_ANCHOR, GameConstants.TOYLINE_SEASON_SECONDS, now)
end

--------------------------------------------------------------------------------
-- CountdownSync broadcast
--------------------------------------------------------------------------------

local function buildPayload(): { toyLineEndsAt: number, nightlyRotationAt: number }
	local now = os.time()
	return {
		toyLineEndsAt = RotationService.GetToyLineEndsAt(now),
		nightlyRotationAt = RotationService.GetNightlyRotationAt(now),
	}
end

local function broadcast()
	local remote = countdownSyncRemote
	if remote ~= nil then
		remote:FireAllClients(buildPayload())
	end
end

local function syncPlayer(player: Player)
	local remote = countdownSyncRemote
	if remote ~= nil then
		remote:FireClient(player, buildPayload())
	end
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function RotationService:Init()
	-- Remotes already exist (init.server runs Remotes.InitServer() first);
	-- pcall'd so a mid-construction build degrades to "no sync", never a boot error.
	local ok, err = pcall(function()
		countdownSyncRemote = Remotes.GetEvent("CountdownSync")
	end)
	if not ok then
		warn(`[RotationService] remote bind failed: {err}`)
	end

	lastUnixDay = RotationService.GetNightlySeed()

	-- New joiners get the timers immediately instead of waiting out the 30s tick
	-- (the wall must read correct within the <45s mobile join gate, §3.2).
	Players.PlayerAdded:Connect(syncPlayer)
end

function RotationService:Start()
	-- Spawned by the loader; runs forever. One loop does both jobs: the 30s
	-- contract broadcast and a 1s unix-day-flip watch. On a mid-server flip the
	-- seed is already new (day-derived — ShiftService's next intermission picks
	-- it up automatically); we broadcast immediately so clients learn the new
	-- nightlyRotationAt fast and CountdownUI can run its hub PA announcement.
	broadcast()
	local sinceSync = 0
	while true do
		task.wait(DAY_FLIP_POLL_SECONDS)
		sinceSync += DAY_FLIP_POLL_SECONDS

		local unixDay = RotationService.GetNightlySeed()
		if unixDay ~= lastUnixDay then
			lastUnixDay = unixDay
			print(`[RotationService] unix-day flip -> nightly seed {unixDay}; next intermission rotates the floor`)
			broadcast()
			sinceSync = 0
		elseif sinceSync >= SYNC_INTERVAL_SECONDS then
			broadcast()
			sinceSync = 0
		end
	end
end

return RotationService
