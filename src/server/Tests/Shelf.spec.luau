--!strict
-- CRYPTLINGS: NIGHT SHIFT — ShelfService spec (Stage 5 display shelf rooms;
-- SOP §3.1 ⑤, §3.2; contracts §B, §D, §G). TestEZ-style: run in Studio via
-- TestEZ (`Packages`/`DevPackages` testez) pointed at
-- ServerScriptService.Server.Tests.
--
-- Needs ONE player with a loaded PlayerDataService profile (Play Solo mock-mode
-- profile loads automatically; nothing persists, so these tests freely mutate
-- it) or the LoadMockProfileForTest fixture seam (Run mode).
--
-- Covered (ShelfService API + acceptance):
--   * Place displays WITHOUT consuming: collection counts never change
--   * displayed copies capped by owned copies (second slot needs a second copy);
--     re-placing the same id in the same slot is a clean overwrite
--   * slot grammar: canonical "s1".."s60" only — "s0"/"s01"/"slot_1"/"s61" are
--     BAD_SLOT (one key form per slot in the profile table)
--   * 9th slot rejected with TIER_LOCKED at tier 0; allowed after
--     SetHousingTierForTest (s60 ok at Mansion, s61 still BAD_SLOT);
--     GetMaxSlots follows the housing tier
--   * UNKNOWN_CRYPTLING / NOT_OWNED errors; Remove idempotent
--   * lazy reconcile: a Cryptling traded away (collection count drops) empties
--     its slot on the next reconcile pass (any Place/Remove)
--   * misprint_trophy (notInPool Starter Pack shelf trophy) is placeable

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
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

-- Fixture seam (PlayerDataService.LoadMockProfileForTest): a player-like table
-- with a fresh in-memory profile, for runs without a real player. Parent = nil
-- keeps ShelfService's room-builder lookups (GetPlayerByUserId) silent for it.
local function acquirePlayerFixture(dataService: any): (any?, () -> ())
	local realPlayer = findLoadedPlayer(dataService)
	if realPlayer ~= nil then
		return realPlayer, function() end
	end
	if type(dataService.LoadMockProfileForTest) == "function" then
		local fake: any = { UserId = 90000005, Name = "ShelfSpecPlayer", DisplayName = "ShelfSpecPlayer", Parent = nil }
		local ok = pcall(dataService.LoadMockProfileForTest, fake)
		if ok and dataService.IsLoaded(fake) then
			return fake,
				function()
					if type(dataService.ReleaseMockProfileForTest) == "function" then
						pcall(dataService.ReleaseMockProfileForTest, fake)
					end
				end
		end
	end
	return nil, function() end
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
			"[Shelf.spec] TestEZ globals missing — run via TestEZ from Packages/DevPackages"
				.. " (wally install); spec skipped"
		)
		return
	end

	local ShelfService = requireService("ShelfService")
	local PlayerDataService = requireService("PlayerDataService")
	if ShelfService == nil or PlayerDataService == nil then
		warn("[Shelf.spec] ShelfService/PlayerDataService not found under Server.Services; spec skipped")
		return
	end

	local player, releaseFixture = acquirePlayerFixture(PlayerDataService)
	if player == nil then
		warn(
			"[Shelf.spec] no player with a loaded mock-mode profile — run in Studio Play Solo (F5),"
				.. " or via PlayerDataService.LoadMockProfileForTest; spec skipped"
		)
		describe("ShelfService", function()
			itSKIP("requires a player with a loaded PlayerDataService mock-mode profile", function() end)
		end)
		return
	end

	local BASE = GameConstants.SHELF_BASE_SLOTS -- 8
	local MAX = GameConstants.HOUSING_MAX_SLOTS -- 60 (Mansion)
	local TIER_SLOTS = GameConstants.HOUSING_TIER_SLOTS -- {12, 24, 60}

	-- Two distinct in-pool ids straight from the roster of record.
	local poolIds: { string } = {}
	for _, def in RarityTable.CRYPTLINGS :: { any } do
		if def.notInPool ~= true then
			table.insert(poolIds, def.id)
		end
	end
	assert(#poolIds >= 2, "Shelf.spec: roster has fewer than two in-pool Cryptlings")
	local ID_A = poolIds[1]
	local ID_B = poolIds[2]

	local function getProfile(): Types.ProfileData
		local data = PlayerDataService.Get(player) :: Types.ProfileData?
		assert(data ~= nil, "Shelf.spec: profile unloaded mid-test")
		return data
	end

	local function resetShelfState()
		PlayerDataService.Update(player, function(data: Types.ProfileData)
			table.clear(data.shelf.slots)
			table.clear(data.collection)
		end)
	end

	local function setOwned(cryptlingId: string, count: number)
		PlayerDataService.Update(player, function(data: Types.ProfileData)
			if count > 0 then
				data.collection[cryptlingId] = count
			else
				data.collection[cryptlingId] = nil
			end
		end)
	end

	describe("ShelfService (mock-mode profile)", function()
		beforeEach(function()
			ShelfService.SetHousingTierForTest(player, 0) -- deterministic starter lot
			resetShelfState()
		end)

		afterEach(function()
			ShelfService.SetHousingTierForTest(player, nil)
			resetShelfState()
		end)

		afterAll(function()
			releaseFixture()
		end)

		it("places an owned Cryptling without consuming the copy", function()
			setOwned(ID_A, 1)
			local result = ShelfService.Place(player, "s1", ID_A)
			expect(result.ok).to.equal(true)
			expect(getProfile().shelf.slots.s1).to.equal(ID_A)
			expect(getProfile().collection[ID_A]).to.equal(1) -- display, never spend
		end)

		it("caps displayed copies at the owned count (second slot needs a second copy)", function()
			setOwned(ID_A, 1)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			local second = ShelfService.Place(player, "s2", ID_A)
			expect(second.ok).to.equal(false)
			expect(second.err).to.equal("NOT_OWNED")

			setOwned(ID_A, 2) -- the dupe arrives (unbox/trade) — now it fits
			expect(ShelfService.Place(player, "s2", ID_A).ok).to.equal(true)
			expect(getProfile().shelf.slots.s2).to.equal(ID_A)
		end)

		it("re-placing the same id in the same slot is a clean overwrite", function()
			setOwned(ID_A, 1)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			expect(getProfile().shelf.slots.s1).to.equal(ID_A)
		end)

		it("swaps a slot's occupant via overwrite (ShelfUI swap path)", function()
			setOwned(ID_A, 1)
			setOwned(ID_B, 1)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			expect(ShelfService.Place(player, "s1", ID_B).ok).to.equal(true)
			expect(getProfile().shelf.slots.s1).to.equal(ID_B)
		end)

		it("rejects non-canonical slot ids with BAD_SLOT", function()
			setOwned(ID_A, 1)
			for _, slotId in { "s0", "s01", "slot_1", `s{MAX + 1}`, "x1", "" } do
				local result = ShelfService.Place(player, slotId, ID_A)
				expect(result.ok).to.equal(false)
				expect(result.err).to.equal("BAD_SLOT")
			end
		end)

		it("rejects unknown cryptling ids with UNKNOWN_CRYPTLING", function()
			local result = ShelfService.Place(player, "s1", "definitely_not_a_cryptling")
			expect(result.ok).to.equal(false)
			expect(result.err).to.equal("UNKNOWN_CRYPTLING")
		end)

		it(`rejects slot {BASE + 1} on the starter lot (TIER_LOCKED)`, function()
			setOwned(ID_A, 1)
			local result = ShelfService.Place(player, `s{BASE + 1}`, ID_A)
			expect(result.ok).to.equal(false)
			expect(result.err).to.equal("TIER_LOCKED")
			expect(ShelfService.GetMaxSlots(player)).to.equal(BASE)
		end)

		it("widens capacity per housing tier (House 12 / 2-Story 24 / Mansion 60)", function()
			setOwned(ID_A, 3)
			for tier = 1, 3 do
				ShelfService.SetHousingTierForTest(player, tier)
				expect(ShelfService.GetMaxSlots(player)).to.equal(TIER_SLOTS[tier])
				expect(ShelfService.GetHousingTier(player)).to.equal(tier)
				expect(ShelfService.Place(player, `s{TIER_SLOTS[tier]}`, ID_A).ok).to.equal(true)
				local over = ShelfService.Place(player, `s{TIER_SLOTS[tier] + 1}`, ID_A)
				expect(over.ok).to.equal(false)
				expect(over.err).to.equal(if tier == 3 then "BAD_SLOT" else "TIER_LOCKED")
				ShelfService.Remove(player, `s{TIER_SLOTS[tier]}`)
			end
		end)

		it(`unlocks s{BASE + 1}..s{MAX} at the Mansion tier`, function()
			ShelfService.SetHousingTierForTest(player, 3)
			setOwned(ID_A, 2)
			expect(ShelfService.GetMaxSlots(player)).to.equal(MAX)
			expect(ShelfService.Place(player, `s{BASE + 1}`, ID_A).ok).to.equal(true)
			expect(ShelfService.Place(player, `s{MAX}`, ID_A).ok).to.equal(true)
			local past = ShelfService.Place(player, `s{MAX + 1}`, ID_A)
			expect(past.ok).to.equal(false)
			expect(past.err).to.equal("BAD_SLOT") -- beyond the widest tier = bad id
		end)

		it("Remove clears a slot and is idempotent on empty slots", function()
			setOwned(ID_A, 1)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			expect(ShelfService.Remove(player, "s1").ok).to.equal(true)
			expect(getProfile().shelf.slots.s1).to.equal(nil)
			expect(ShelfService.Remove(player, "s1").ok).to.equal(true) -- already empty: still ok
			local bad = ShelfService.Remove(player, "slot_1")
			expect(bad.ok).to.equal(false)
			expect(bad.err).to.equal("BAD_SLOT")
		end)

		it("reconcile empties the slot of a Cryptling traded away (Stage 4)", function()
			setOwned(ID_A, 1)
			setOwned(ID_B, 1)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			setOwned(ID_A, 0) -- the trade takes the last copy
			-- Any Place/Remove runs the lazy reconcile pass first.
			expect(ShelfService.Place(player, "s3", ID_B).ok).to.equal(true)
			expect(getProfile().shelf.slots.s1).to.equal(nil) -- pruned
			expect(getProfile().shelf.slots.s3).to.equal(ID_B) -- untouched
		end)

		it("reconcile prunes excess copies highest-numbered slot first", function()
			setOwned(ID_A, 2)
			expect(ShelfService.Place(player, "s1", ID_A).ok).to.equal(true)
			expect(ShelfService.Place(player, "s5", ID_A).ok).to.equal(true)
			setOwned(ID_A, 1) -- one copy traded away
			expect(ShelfService.Remove(player, "s12").ok).to.equal(true) -- triggers reconcile
			expect(getProfile().shelf.slots.s1).to.equal(ID_A) -- lowest slot keeps the copy
			expect(getProfile().shelf.slots.s5).to.equal(nil)
		end)

		it("misprint_trophy (Starter Pack shelf exclusive) is placeable from the collection", function()
			expect(RarityTable.GetCryptling("misprint_trophy")).to.be.ok()
			setOwned("misprint_trophy", 1)
			local result = ShelfService.Place(player, "s1", "misprint_trophy")
			expect(result.ok).to.equal(true)
			expect(getProfile().shelf.slots.s1).to.equal("misprint_trophy")
		end)
	end)
end
