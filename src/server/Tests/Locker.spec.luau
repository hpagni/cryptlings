--!strict
-- CRYPTLINGS: NIGHT SHIFT — LockerService spec (Stage 4 economy QA; SOP §1.5,
-- §3.1 ③, §3.3, §8.2; contracts §C, §D, §G, §I). TestEZ-style: run in Studio
-- via TestEZ (`Packages`/`DevPackages` testez) pointed at
-- ServerScriptService.Server.Tests.
--
-- Needs ONE player with a loaded PlayerDataService profile. In Studio Play Solo
-- (F5) the mock-mode (in-memory ProfileService .Mock) profile loads
-- automatically — nothing persists, so these tests freely mutate it. If no
-- loaded player exists the spec SKIPs with a clear warn; it can also fabricate
-- a player-like fixture when PlayerDataService exposes a
-- LoadMockProfileForTest seam (see openIssues — not shipped as of Stage 3).
--
-- Covered (§G locker rules, contract §I API):
--   * exactly FREE_OPENS_PER_DAY (3) opens, then blocked (remote err NO_OPENS)
--   * SetLastResetDayForTest day-flip hook restores the daily allowance
--   * extraOpenCredits consumed only AFTER free opens run dry
--   * VIP pass mock (SetVipForTest) -> VIP_OPENS_PER_DAY (6)
--   * AddCases / GrantExtraOpens persist into the profile (and validate input)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local LockerCore = require(Shared:WaitForChild("Logic"):WaitForChild("LockerCore"))
local Types = require(Shared:WaitForChild("Types"))

local PLAYER_LOAD_TIMEOUT_SECONDS = 5

local function requireService(name: string): any
	local testsFolder = script.Parent
	local serverRoot = testsFolder and testsFolder.Parent
	local servicesFolder = serverRoot and serverRoot:FindFirstChild("Services")
	local module = servicesFolder and servicesFolder:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, service = pcall(require, module)
	if ok and type(service) == "table" then
		return service
	end
	return nil
end

-- A loaded real player (Play Solo / Team Test), waiting briefly for the mock
-- profile to session-lock.
local function findLoadedPlayer(dataService: any): Player?
	local deadline = os.clock() + PLAYER_LOAD_TIMEOUT_SECONDS
	repeat
		for _, player in Players:GetPlayers() do
			if dataService.IsLoaded(player) then
				return player
			end
		end
		if #Players:GetPlayers() == 0 then
			return nil -- Run mode (F8): no players will ever join
		end
		task.wait(0.25)
	until os.clock() >= deadline
	return nil
end

-- Optional fixture seam (openIssues): a player-like table with a mock profile,
-- for runs without a real player. Parent = nil keeps LockerService's
-- owner-only LockerChanged pushes silent for the fixture.
local LOAD_SEAM_CANDIDATES = { "LoadMockProfileForTest", "LoadProfileForTest", "AddMockProfileForTest" }
local RELEASE_SEAM_CANDIDATES = { "ReleaseMockProfileForTest", "ReleaseProfileForTest", "RemoveMockProfileForTest" }

local function acquirePlayerFixture(dataService: any): (any?, () -> ())
	local realPlayer = findLoadedPlayer(dataService)
	if realPlayer ~= nil then
		return realPlayer, function() end
	end
	for _, loadName in LOAD_SEAM_CANDIDATES do
		if type(dataService[loadName]) == "function" then
			local fake: any =
				{ UserId = 90000001, Name = "LockerSpecPlayer", DisplayName = "LockerSpecPlayer", Parent = nil }
			local ok = pcall(dataService[loadName], fake)
			if ok and dataService.IsLoaded(fake) then
				return fake,
					function()
						for _, releaseName in RELEASE_SEAM_CANDIDATES do
							if type(dataService[releaseName]) == "function" then
								pcall(dataService[releaseName], fake)
								return
							end
						end
					end
			end
		end
	end
	return nil, function() end
end

local function makeStub(tier: number): Types.CaseStub
	return {
		uid = HttpService:GenerateGUID(false),
		tier = tier,
		lineId = "line1",
		acquiredAt = os.time(),
		source = "run" :: Types.CaseSource,
	}
end

return function()
	-- TestEZ injects describe/it/expect into this function's environment
	-- (setfenv). Localize through getfenv so the file stays --!strict clean.
	local env = getfenv() :: any
	local describe: (string, () -> ()) -> () = env.describe
	local it: (string, () -> ()) -> () = env.it
	local itSKIP: (string, () -> ()) -> () = env.itSKIP
	local expect: (any) -> any = env.expect
	local beforeEach: (() -> ()) -> () = env.beforeEach
	local afterEach: (() -> ()) -> () = env.afterEach
	local afterAll: (() -> ()) -> () = env.afterAll
	if type(describe) ~= "function" or type(it) ~= "function" or type(expect) ~= "function" then
		warn(
			"[Locker.spec] TestEZ globals missing — run via TestEZ from Packages/DevPackages"
				.. " (wally install); spec skipped"
		)
		return
	end

	local LockerService = requireService("LockerService")
	local PlayerDataService = requireService("PlayerDataService")
	if LockerService == nil or PlayerDataService == nil then
		warn("[Locker.spec] LockerService/PlayerDataService not found under Server.Services; spec skipped")
		return
	end

	local player, releaseFixture = acquirePlayerFixture(PlayerDataService)
	if player == nil then
		warn(
			"[Locker.spec] no player with a loaded mock-mode profile — run in Studio Play Solo (F5),"
				.. " or expose PlayerDataService.LoadMockProfileForTest(playerLike); spec skipped"
		)
		describe("LockerService", function()
			itSKIP("requires a player with a loaded PlayerDataService mock-mode profile", function() end)
		end)
		return
	end

	local FREE = GameConstants.FREE_OPENS_PER_DAY -- 3
	local VIP = GameConstants.VIP_OPENS_PER_DAY -- 6

	local function getProfile(): Types.ProfileData
		local data = PlayerDataService.Get(player) :: Types.ProfileData?
		assert(data ~= nil, "Locker.spec: profile unloaded mid-test")
		return data
	end

	-- Every test starts from a clean, just-reset locker on today's unix day.
	local function resetLockerState()
		PlayerDataService.Update(player, function(data: Types.ProfileData)
			table.clear(data.locker.cases)
			data.locker.freeOpensUsed = 0
			data.locker.extraOpenCredits = 0
			data.locker.lastResetDay = LockerCore.WindowIndex(os.time())
		end)
	end

	local function consumeAllFreeOpens()
		for _ = 1, FREE do
			expect((LockerService.TryConsumeOpen(player))).to.equal(true)
		end
	end

	describe("LockerService (mock-mode profile)", function()
		beforeEach(function()
			resetLockerState()
			LockerService.SetVipForTest(player, false) -- deterministic non-VIP baseline
		end)

		afterEach(function()
			LockerService.SetVipForTest(player, nil)
			resetLockerState()
		end)

		afterAll(function()
			releaseFixture()
		end)

		it(`consumes exactly {FREE} free opens, then blocks (NO_OPENS)`, function()
			for expectedLeft = FREE - 1, 0, -1 do
				local ok, remaining = LockerService.TryConsumeOpen(player)
				expect(ok).to.equal(true)
				expect(remaining).to.equal(expectedLeft)
			end
			local blockedOk, blockedRemaining = LockerService.TryConsumeOpen(player)
			expect(blockedOk).to.equal(false) -- RequestOpenCase surfaces this as err NO_OPENS
			expect(blockedRemaining).to.equal(0)
			expect(getProfile().locker.freeOpensUsed).to.equal(FREE)
		end)

		it("restores the allowance when the day-flip test hook backdates the reset", function()
			consumeAllFreeOpens()
			expect((LockerService.TryConsumeOpen(player))).to.equal(false)

			expect(LockerService.SetLastResetDayForTest(player, LockerCore.WindowIndex(os.time()) - 1)).to.equal(true)

			-- GetLockerState applies EnsureDailyReset: full allowance is back.
			local state = LockerService.GetLockerState(player) :: Types.LockerState
			expect(state.freeOpensRemaining).to.equal(FREE)
			expect(state.nextResetAt).to.equal(
				(LockerCore.WindowIndex(os.time()) + 1) * GameConstants.LOCKER_RESET_WINDOW_SECONDS
			)

			local ok, remaining = LockerService.TryConsumeOpen(player)
			expect(ok).to.equal(true)
			expect(remaining).to.equal(FREE - 1)
		end)

		it("consumes extraOpenCredits only AFTER the free opens run dry", function()
			expect(LockerService.GrantExtraOpens(player, 2)).to.equal(true)
			consumeAllFreeOpens()
			-- Free opens spent first: both credits must still be intact.
			expect(getProfile().locker.extraOpenCredits).to.equal(2)

			local ok4, remaining4 = LockerService.TryConsumeOpen(player)
			expect(ok4).to.equal(true)
			expect(remaining4).to.equal(1)
			expect(getProfile().locker.extraOpenCredits).to.equal(1)

			local ok5, remaining5 = LockerService.TryConsumeOpen(player)
			expect(ok5).to.equal(true)
			expect(remaining5).to.equal(0)
			expect(getProfile().locker.extraOpenCredits).to.equal(0)

			expect((LockerService.TryConsumeOpen(player))).to.equal(false)
		end)

		it(`grants {VIP} opens/day with the VIP pass mock`, function()
			LockerService.SetVipForTest(player, true)
			local state = LockerService.GetLockerState(player) :: Types.LockerState
			expect(state.opensPerDay).to.equal(VIP)
			expect(state.freeOpensRemaining).to.equal(VIP)

			for expectedLeft = VIP - 1, 0, -1 do
				local ok, remaining = LockerService.TryConsumeOpen(player)
				expect(ok).to.equal(true)
				expect(remaining).to.equal(expectedLeft)
			end
			expect((LockerService.TryConsumeOpen(player))).to.equal(false)
			expect(getProfile().locker.freeOpensUsed).to.equal(VIP)
		end)

		it("persists AddCases stubs into profile.locker.cases", function()
			local stubA = makeStub(2)
			local stubB = makeStub(3)
			expect(LockerService.AddCases(player, { stubA, stubB })).to.equal(true)

			local cases = getProfile().locker.cases
			expect(#cases).to.equal(2)
			expect(cases[1].uid).to.equal(stubA.uid)
			expect(cases[2].uid).to.equal(stubB.uid)

			-- The wire snapshot reflects the same cases but is a CLONE: mutating
			-- it must never touch saved state.
			local state = LockerService.GetLockerState(player) :: Types.LockerState
			expect(#state.cases).to.equal(2)
			table.remove(state.cases)
			expect(#getProfile().locker.cases).to.equal(2)
		end)

		it("skips malformed stubs and rejects empty AddCases", function()
			local good = makeStub(1)
			local malformed: any = { uid = "", tier = 5, lineId = "line1", acquiredAt = 0, source = "hax" }
			expect(LockerService.AddCases(player, { good, malformed })).to.equal(true)
			expect(#getProfile().locker.cases).to.equal(1)
			expect(getProfile().locker.cases[1].uid).to.equal(good.uid)

			expect(LockerService.AddCases(player, { malformed })).to.equal(false)
			expect(LockerService.AddCases(player, {})).to.equal(false)
			expect(#getProfile().locker.cases).to.equal(1)
		end)

		it("persists GrantExtraOpens and validates n as a positive integer", function()
			expect(LockerService.GrantExtraOpens(player, 3)).to.equal(true)
			expect(getProfile().locker.extraOpenCredits).to.equal(3)
			expect(LockerService.GrantExtraOpens(player, 2)).to.equal(true)
			expect(getProfile().locker.extraOpenCredits).to.equal(5)

			expect(LockerService.GrantExtraOpens(player, 0)).to.equal(false)
			expect(LockerService.GrantExtraOpens(player, -2)).to.equal(false)
			expect(LockerService.GrantExtraOpens(player, 1.5)).to.equal(false)
			expect(getProfile().locker.extraOpenCredits).to.equal(5)
		end)
	end)
end
