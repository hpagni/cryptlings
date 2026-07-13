--!strict
-- CRYPTLINGS: NIGHT SHIFT — DecorBuilder: bench/prop clusters and the
-- first-join guidance-beam anchor (LOBBY_SOP §9, §11.2/§11.3; plan WP2.5).
-- The static night-shift NPC dummies that stood beside the swap meet were
-- removed entirely per Addendum 1 Change 8 (pure removal, no replacement
-- props). Pure construction — no signals, no loops over time, no player
-- logic; invoked once by the Wave-3 HubService orchestrator:
--   DecorBuilder.Build(parent, origin)
--
-- Layout convention (binding for all Wave-2 builders): origin is the hub
-- origin, the street runs along X with the Factory plaza at the east (+X)
-- end, and the corridor is centered on Z = 0. Placement discipline:
--   * clusters sit at lot boundaries (inside the 8-stud gaps behind the
--     sidewalk line) and at both plaza ends — semi-random via a fixed-seed
--     Random, never evenly spaced (SOP §9);
--   * every cluster carries its own thin Neon accent strip, NO Light
--     instance (SOP §2.7 — unlit props vanish at night; zero light budget);
--   * every part is decor-flagged (CanCollide/CanTouch/CanQuery = false,
--     CastShadow = false — SOP §10);
--   * nothing within LobbyConfig.DECOR_SIDEWALK_CLEARANCE_STUDS of the
--     sidewalk centerline, and the queue-pad approach lane (Z ~ 0 on the
--     Factory plaza) stays prop-free (SOP §11.3).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))
local PartKit = require(script.Parent:WaitForChild("PartKit"))

local TAG_BEAM_ANCHOR = "OnboardingBeamAnchor"

-- Fixed seed: semi-random placement that is identical on every server, so
-- screenshots, part budgets, and overlap QA stay reproducible.
local DECOR_SEED = 94609

-- Palette (greybox night tones; the neon strip is the one accent material).
local COLOR_WOOD = Color3.fromRGB(60, 52, 46)
local COLOR_CRATE = Color3.fromRGB(70, 62, 50)
local COLOR_BARREL = Color3.fromRGB(55, 60, 70)
local COLOR_BIN = Color3.fromRGB(45, 48, 55)
local COLOR_NEON_STRIP = Color3.fromRGB(255, 180, 110) -- warm amber, matches lamp pools

-- Lift every prop bottom slightly off the ground slab (no coplanar z-fighting,
-- SOP §11.2).
local GROUND_LIFT = 0.05

local DecorBuilder = {}

export type DecorBuild = {
	model: Model,
	beamAnchor: BasePart,
}

--------------------------------------------------------------------------------
-- Prop pieces (all local-space around a base CFrame whose -Z faces the street)
--------------------------------------------------------------------------------

-- Bench: seat + 2 legs + backrest + thin Neon strip along the backrest top.
-- 5 parts, ~4 studs long so a cluster always fits the 8-stud lot gap.
local function buildBench(parent: Instance, base: CFrame)
	PartKit.MakePart(parent, "BenchSeat", Vector3.new(4, 0.4, 1.6), base * CFrame.new(0, 1.15 + GROUND_LIFT, 0), {
		color = COLOR_WOOD,
		decor = true,
	})
	for _, side in { -1, 1 } do
		PartKit.MakePart(
			parent,
			"BenchLeg",
			Vector3.new(0.4, 1.1, 1.4),
			base * CFrame.new(side * 1.6, 0.55 + GROUND_LIFT, 0),
			{ color = COLOR_WOOD, decor = true }
		)
	end
	PartKit.MakePart(parent, "BenchBack", Vector3.new(4, 1.6, 0.3), base * CFrame.new(0, 2 + GROUND_LIFT, 0.7), {
		color = COLOR_WOOD,
		decor = true,
	})
	PartKit.MakePart(
		parent,
		"BenchNeonStrip",
		Vector3.new(3.7, 0.12, 0.12),
		base * CFrame.new(0, 2.86 + GROUND_LIFT, 0.7),
		{
			color = COLOR_NEON_STRIP,
			material = Enum.Material.Neon,
			decor = true,
		}
	)
end

-- Small side props: crate / barrel / trash bin (1 part each).
local function buildSideProp(parent: Instance, base: CFrame, rng: Random)
	local kind = rng:NextInteger(1, 3)
	if kind == 1 then
		PartKit.MakePart(parent, "Crate", Vector3.new(1.8, 1.8, 1.8), base * CFrame.new(0, 0.9 + GROUND_LIFT, 0), {
			color = COLOR_CRATE,
			decor = true,
		})
	elseif kind == 2 then
		PartKit.MakeUprightCylinder(
			parent,
			"Barrel",
			2.8,
			2,
			base.Position + Vector3.new(0, 1.4 + GROUND_LIFT, 0),
			{ color = COLOR_BARREL, decor = true }
		)
	else
		PartKit.MakeUprightCylinder(
			parent,
			"TrashBin",
			2.4,
			1.6,
			base.Position + Vector3.new(0, 1.2 + GROUND_LIFT, 0),
			{ color = COLOR_BIN, decor = true }
		)
	end
end

-- One bench cluster: bench (with its neon accent) + 1-2 side props, yaw
-- jitter so no two clusters ever read as mirrored copies.
local function buildCluster(parent: Instance, base: CFrame, rng: Random)
	local cluster = Instance.new("Model")
	cluster.Name = "PropCluster"

	local benchYaw = math.rad(rng:NextNumber(-12, 12))
	buildBench(cluster, base * CFrame.Angles(0, benchYaw, 0))

	local propCount = rng:NextInteger(1, 2)
	local firstSide = if rng:NextNumber() < 0.5 then -1 else 1
	for index = 1, propCount do
		local side = if index == 1 then firstSide else -firstSide
		local propBase = base
			* CFrame.new(side * rng:NextNumber(2.6, 2.9), 0, rng:NextNumber(-0.5, 0.5))
			* CFrame.Angles(0, rng:NextNumber(-math.pi, math.pi), 0)
		buildSideProp(cluster, propBase, rng)
	end

	cluster.Parent = parent
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function DecorBuilder.Build(parent: Model, origin: Vector3): DecorBuild
	local model = Instance.new("Model")
	model.Name = "Decor"

	local rng = Random.new(DECOR_SEED)

	-- Shared corridor arithmetic (same derivation StreetBuilder uses).
	local lotPitch = LobbyConfig.LOT_FRONTAGE_STUDS + LobbyConfig.LOT_GAP_STUDS
	local lotRun = LobbyConfig.LOTS_PER_SIDE * LobbyConfig.LOT_FRONTAGE_STUDS
		+ (LobbyConfig.LOTS_PER_SIDE - 1) * LobbyConfig.LOT_GAP_STUDS
	local halfRun = lotRun / 2
	local corridorHalf = LobbyConfig.CORRIDOR_WIDTH_STUDS / 2 -- sidewalk outer edge
	local sidewalkCenter = LobbyConfig.STREET_ASPHALT_WIDTH_STUDS / 2 + LobbyConfig.SIDEWALK_WIDTH_STUDS / 2

	-- Cluster row sits in the lot-gap columns just behind the sidewalk line.
	local clusterDepth = corridorHalf + 4
	assert(
		clusterDepth - sidewalkCenter >= LobbyConfig.DECOR_SIDEWALK_CLEARANCE_STUDS,
		"[DecorBuilder] cluster row violates the sidewalk clearance rule"
	)

	-- 1) Lot-boundary clusters: walk the 9 gaps per side, keep roughly every
	--    other one (parity per side differs + a small random extra chance), so
	--    spacing is semi-random and never mirrored across the street (SOP §9).
	for sideIndex, side in { -1, 1 } do
		local parity = sideIndex % 2
		for gap = 1, LobbyConfig.LOTS_PER_SIDE - 1 do
			local keep = (gap + parity) % 2 == 0 or rng:NextNumber() < 0.15
			if keep then
				local x = gap * lotPitch - LobbyConfig.LOT_GAP_STUDS / 2 - halfRun
				local z = side * (clusterDepth + rng:NextNumber(0, 2))
				-- Face the street: -Z is the default LookVector, so the south
				-- (+Z) row faces it as-is and the north row turns around.
				local facing = if side > 0 then CFrame.Angles(0, 0, 0) else CFrame.Angles(0, math.pi, 0)
				buildCluster(model, CFrame.new(origin + Vector3.new(x, 0, z)) * facing, rng)
			end
		end
	end

	-- 2) Plaza-end clusters (both ends, SOP §9), pulled to the corridor
	--    corners so the queue-pad approach lane along Z ~ 0 stays clear.
	for _, side in { -1, 1 } do
		local factoryCorner = origin + Vector3.new(halfRun + 9, 0, side * (21 + rng:NextNumber(0, 2)))
		buildCluster(model, CFrame.new(factoryCorner) * CFrame.Angles(0, math.pi / 2, 0), rng)

		local comingSoonCorner = origin + Vector3.new(-halfRun - 9, 0, side * (19 + rng:NextNumber(0, 2)))
		buildCluster(model, CFrame.new(comingSoonCorner) * CFrame.Angles(0, -math.pi / 2, 0), rng)
	end

	-- 3) First-join guidance-beam anchor: invisible decor part on the
	--    spawn-to-queue-pad line, ~6 studs up; OnboardingController adorns the
	--    actual beam client-side (SOP §6.4 first-join onboarding).
	local beamAnchor = PartKit.MakePart(
		model,
		"OnboardingBeamAnchor",
		Vector3.one,
		CFrame.new(origin + Vector3.new(halfRun + 26, 6, 0)),
		{ decor = true, transparency = 1 }
	)
	CollectionService:AddTag(beamAnchor, TAG_BEAM_ANCHOR)

	model.Parent = parent
	return { model = model, beamAnchor = beamAnchor }
end

return DecorBuilder
