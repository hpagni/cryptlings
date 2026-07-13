--!strict
-- CRYPTLINGS: NIGHT SHIFT — BikeRigPose (Addendum 3 R4-3; R4 plan WP1.4).
-- Client-side ride pose for the lobby bicycle: zero-asset, runtime
-- Motor6D.Transform posing (the hoverboard / ride-pet pattern). Runs for
-- EVERY visible rider — Motor6D.Transform does NOT replicate, so each client
-- poses every character whose server-set "BikeActive" attribute is true.
--
-- Timing contract (the whole trick): pose writes happen on RunService.Stepped
-- ONLY. The Animator overwrites Transform after PreAnimation / before
-- PreSimulation, so Stepped writes land AFTER the Animator and win; writes on
-- the pre-render step get clobbered within the same frame. The Animator
-- stomps Transform even with no animation playing (staff-acknowledged bug),
-- so the per-frame write is mandatory regardless.
--
-- Authority / ownership:
--   * BikeService (server) owns "BikeActive" and the welded cosmetic; this
--     module never writes the attribute and never touches Humanoid move
--     speed — the two existing speed owners (server CaseService
--     .ApplyCarrySpeed and the InputController client formula) stay the only
--     writers (PetPerks line 8 rule). This module writes HipHeight (owning
--     client only) and Motor6D.Transform / weld C0s, nothing else.
--   * HipHeight: the OWNING client stores the prior value, adds +0.6 on
--     mount, and restores the EXACT stored prior on dismount (never assume
--     2.0 — R15 scales vary).
--   * Weld-name contract (frozen; server-built in BikeService.buildBike):
--     "FrameWeld" in Frame (Part0 = root), "SpinWeld" in each wheel
--     (Part0 = Frame). Clients mutate C0 LOCALLY only (spin / lean juice).
--
-- Pose recipe (R15; signs are per-rig — verified visually in Wave-2 smoke):
-- hips CFrame.Angles(rad(-80), 0, ±rad(8)) straddle, knees ~rad(85) bend,
-- shoulders ~-35° forward + elbows ~25° for handlebar reach, Waist ~12°
-- forward lean composed ON TOP of the Animator's value to keep walk bob.
-- R6 degrades to hips-only (~90°, joints live in Torso). Every joint is
-- resolved via FindFirstChild + IsA("Motor6D") (mid-spawn rigs lack joints).
--
-- Fallback of record if the pose slips (placeholder ONLY — no straddle or
-- handlebar reach): Roblox-owned R15 sit rbxassetid://2506281703 at Action
-- priority (loads in any game).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConstants = require(Shared:WaitForChild("Config"):WaitForChild("GameConstants"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Pose constants (Addendum 3 recipe; tuned visually in smoke)
--------------------------------------------------------------------------------

local POSE_LEFT_HIP = CFrame.Angles(math.rad(-80), 0, math.rad(8))
local POSE_RIGHT_HIP = CFrame.Angles(math.rad(-80), 0, -math.rad(8))
local POSE_KNEE = CFrame.Angles(math.rad(85), 0, 0)
local POSE_SHOULDER = CFrame.Angles(math.rad(-35), 0, 0)
local POSE_ELBOW = CFrame.Angles(math.rad(25), 0, 0)
-- Waist lean composes onto the Animator's Transform so walk bob survives.
local WAIST_LEAN = CFrame.Angles(math.rad(-12), 0, 0)
-- R6 fallback: only the two hip Motor6Ds exist (in Torso) — hips-only degrade.
local POSE_R6_LEFT_HIP = CFrame.Angles(0, 0, math.rad(90))
local POSE_R6_RIGHT_HIP = CFrame.Angles(0, 0, -math.rad(90))

-- Owning-client saddle bump: bent legs clear the ground, wheels touch.
local HIP_HEIGHT_BUMP = 0.6

--------------------------------------------------------------------------------
-- Juice tuning (all cosmetic, all client-local)
--------------------------------------------------------------------------------

local LEAN_MAX_ROLL = math.rad(15) -- clamp band for the turn lean
local LEAN_ROLL_GAIN = 0.08 -- rad of roll per rad/s of signed turn rate
local LEAN_PITCH_MAX = math.rad(5) -- slight nose-up at top speed
-- (MODEL_HEIGHT + 0.4) / 2 of record; replaced by the live wheel size once
-- the server-built parts replicate in.
local WHEEL_RADIUS_FALLBACK = 0.7
-- Top speed for the pitch ramp: base speed x bike multiplier (30.8 studs/s).
local TOP_SPEED = GameConstants.WALKSPEED_BASE * GameConstants.BIKE_SPEED_MULT

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type RideState = {
	character: Model,
	stepped: RBXScriptConnection?,
	-- Owning-client HipHeight restore (exact stored prior, never a default).
	bumpedHumanoid: Humanoid?,
	priorHipHeight: number?,
	-- Juice state. Base C0s are captured ONCE per weld instance (rest pose).
	spinAngle: number,
	roll: number,
	lastYaw: number?,
	wheelRadius: number,
	frameWeld: Weld?,
	frameBaseC0: CFrame?,
	frontWeld: Weld?,
	frontBaseC0: CFrame?,
	rearWeld: Weld?,
	rearBaseC0: CFrame?,
}

local rides: { [Player]: RideState } = {}
local watchConnections: { [Player]: { RBXScriptConnection } } = {}

--------------------------------------------------------------------------------
-- Strict instance resolution (mid-spawn rigs lack joints; never throw)
--------------------------------------------------------------------------------

-- A poseable joint: legacy Motor6D OR the new-rig AnimationConstraint — both
-- expose the animator-owned Transform CFrame with identical write-after-Animate
-- semantics. Live R15 rigs in this place ship 15 AnimationConstraints and ZERO
-- Motor6Ds (R4 smoke finding P1), so the dual check is load-bearing.
type PoseJoint = Motor6D | AnimationConstraint

local function getMotor(parent: Instance?, name: string): PoseJoint?
	if parent == nil then
		return nil
	end
	local child = parent:FindFirstChild(name)
	if child ~= nil and (child:IsA("Motor6D") or child:IsA("AnimationConstraint")) then
		return child :: PoseJoint
	end
	return nil
end

local function getWeld(parent: Instance?, name: string): Weld?
	if parent == nil then
		return nil
	end
	local child = parent:FindFirstChild(name)
	if child ~= nil and child:IsA("Weld") then
		return child :: Weld
	end
	return nil
end

--------------------------------------------------------------------------------
-- Pose (every frame; plain assignment stops the run cycle swinging limbs)
--------------------------------------------------------------------------------

local function applyPose(character: Model, humanoid: Humanoid)
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		local torso = character:FindFirstChild("Torso")
		local leftHip = getMotor(torso, "Left Hip")
		if leftHip ~= nil then
			leftHip.Transform = POSE_R6_LEFT_HIP
		end
		local rightHip = getMotor(torso, "Right Hip")
		if rightHip ~= nil then
			rightHip.Transform = POSE_R6_RIGHT_HIP
		end
		return
	end

	-- R15: every joint lives in the CHILD part of its pair.
	local leftHip = getMotor(character:FindFirstChild("LeftUpperLeg"), "LeftHip")
	if leftHip ~= nil then
		leftHip.Transform = POSE_LEFT_HIP
	end
	local rightHip = getMotor(character:FindFirstChild("RightUpperLeg"), "RightHip")
	if rightHip ~= nil then
		rightHip.Transform = POSE_RIGHT_HIP
	end
	local leftKnee = getMotor(character:FindFirstChild("LeftLowerLeg"), "LeftKnee")
	if leftKnee ~= nil then
		leftKnee.Transform = POSE_KNEE
	end
	local rightKnee = getMotor(character:FindFirstChild("RightLowerLeg"), "RightKnee")
	if rightKnee ~= nil then
		rightKnee.Transform = POSE_KNEE
	end
	local leftShoulder = getMotor(character:FindFirstChild("LeftUpperArm"), "LeftShoulder")
	if leftShoulder ~= nil then
		leftShoulder.Transform = POSE_SHOULDER
	end
	local rightShoulder = getMotor(character:FindFirstChild("RightUpperArm"), "RightShoulder")
	if rightShoulder ~= nil then
		rightShoulder.Transform = POSE_SHOULDER
	end
	local leftElbow = getMotor(character:FindFirstChild("LeftLowerArm"), "LeftElbow")
	if leftElbow ~= nil then
		leftElbow.Transform = POSE_ELBOW
	end
	local rightElbow = getMotor(character:FindFirstChild("RightLowerArm"), "RightElbow")
	if rightElbow ~= nil then
		rightElbow.Transform = POSE_ELBOW
	end
	local waist = getMotor(character:FindFirstChild("UpperTorso"), "Waist")
	if waist ~= nil then
		-- Compose on top of the Animator's value: the Animator rewrote
		-- Transform earlier this frame (pre-simulation), so this never
		-- accumulates — and the walk bob survives under the lean. Without an
		-- Animator to reset the joint, composition would integrate forever,
		-- so degrade to plain assignment.
		if humanoid:FindFirstChildOfClass("Animator") ~= nil then
			waist.Transform = waist.Transform * WAIST_LEAN
		else
			waist.Transform = WAIST_LEAN
		end
	end
end

--------------------------------------------------------------------------------
-- Juice (wheel spin, frame lean, first-person fade — all weld-C0 local)
--------------------------------------------------------------------------------

local function applyJuice(player: Player, state: RideState, root: BasePart, deltaTime: number)
	local bike = state.character:FindFirstChild("LobbyBike")
	if bike == nil or not bike:IsA("Model") then
		return -- server cosmetic not replicated yet; pose-only this frame
	end

	-- (Re)capture rest-pose base C0s once per weld INSTANCE — the attribute
	-- can replicate before the server-built welds land.
	local framePart = bike:FindFirstChild("Frame")
	local frameWeld = getWeld(framePart, "FrameWeld")
	if frameWeld ~= nil and frameWeld ~= state.frameWeld then
		state.frameWeld = frameWeld
		state.frameBaseC0 = frameWeld.C0
	end
	local frontPart = bike:FindFirstChild("FrontWheel")
	local frontWeld = getWeld(frontPart, "SpinWeld")
	if frontWeld ~= nil and frontWeld ~= state.frontWeld then
		state.frontWeld = frontWeld
		state.frontBaseC0 = frontWeld.C0
		if frontPart ~= nil and frontPart:IsA("BasePart") then
			state.wheelRadius = math.max(frontPart.Size.Y / 2, 0.1) -- cylinder diameter = Y
		end
	end
	local rearWeld = getWeld(bike:FindFirstChild("RearWheel"), "SpinWeld")
	if rearWeld ~= nil and rearWeld ~= state.rearWeld then
		state.rearWeld = rearWeld
		state.rearBaseC0 = rearWeld.C0
	end

	-- Wheel spin: integrate planar ground speed over the wheel radius
	-- (~4.9 rev/s at 30.8 studs/s on a 0.7-stud wheel).
	local velocity = root.AssemblyLinearVelocity
	local planarSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	state.spinAngle = (state.spinAngle + (planarSpeed / state.wheelRadius) * deltaTime) % (math.pi * 2)
	local spinCF = CFrame.Angles(state.spinAngle, 0, 0) -- cylinder axis = X (the axle)
	local frontBaseC0 = state.frontBaseC0
	if state.frontWeld ~= nil and frontBaseC0 ~= nil then
		state.frontWeld.C0 = frontBaseC0 * spinCF
	end
	local rearBaseC0 = state.rearBaseC0
	if state.rearWeld ~= nil and rearBaseC0 ~= nil then
		state.rearWeld.C0 = rearBaseC0 * spinCF
	end

	-- Frame lean: roll into the turn (signed yaw rate, clamped ±15°,
	-- lerp-smoothed) + slight nose-up pitch at speed.
	local look = root.CFrame.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	local lastYaw = state.lastYaw
	local turnRate = 0
	if lastYaw ~= nil and deltaTime > 0 then
		local delta = (yaw - lastYaw + math.pi) % (math.pi * 2) - math.pi -- wrap to ±pi
		turnRate = delta / deltaTime
	end
	state.lastYaw = yaw
	local targetRoll = math.clamp(-turnRate * LEAN_ROLL_GAIN, -LEAN_MAX_ROLL, LEAN_MAX_ROLL)
	local alpha = 1 - 0.001 ^ deltaTime -- framerate-independent smoothing
	state.roll += (targetRoll - state.roll) * alpha
	local pitch = LEAN_PITCH_MAX * math.min(planarSpeed / TOP_SPEED, 1)
	local frameBaseC0 = state.frameBaseC0
	if state.frameWeld ~= nil and frameBaseC0 ~= nil then
		state.frameWeld.C0 = frameBaseC0 * CFrame.Angles(pitch, 0, state.roll)
	end

	-- First person (LOCAL rider only): mirror a body part's per-frame fade
	-- onto the bike parts so the frame never blocks the camera (complements
	-- the R4-2 cursor work).
	if player == LocalPlayer then
		local head = state.character:FindFirstChild("Head")
		if head ~= nil and head:IsA("BasePart") then
			local fade = head.LocalTransparencyModifier
			for _, part in bike:GetChildren() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = fade
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Ride session (ONE Stepped connection per rider)
--------------------------------------------------------------------------------

local function stepRide(player: Player, state: RideState, deltaTime: number)
	local character = state.character
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") then
		return -- mid-spawn rig; try again next step
	end

	-- Owning-client saddle bump, applied once the Humanoid resolves; the
	-- EXACT prior value is restored on dismount (see stopRide).
	if player == LocalPlayer and state.bumpedHumanoid == nil then
		state.priorHipHeight = humanoid.HipHeight
		humanoid.HipHeight += HIP_HEIGHT_BUMP
		state.bumpedHumanoid = humanoid
	end

	applyPose(character, humanoid)
	applyJuice(player, state, root, deltaTime)
end

local function stopRide(player: Player)
	local state = rides[player]
	if state == nil then
		return
	end
	rides[player] = nil
	if state.stepped ~= nil then
		state.stepped:Disconnect()
	end
	-- Owning client: restore the exact stored prior (never assume a default).
	local humanoid = state.bumpedHumanoid
	local prior = state.priorHipHeight
	if humanoid ~= nil and prior ~= nil then
		humanoid.HipHeight = prior
	end
	-- Motor6D Transforms self-heal next frame as the Animator reclaims the
	-- joints; the bike model (and its mutated C0s) is destroyed server-side.
end

local function startRide(player: Player)
	if rides[player] ~= nil then
		return -- already posing this rider
	end
	local character = player.Character
	if character == nil then
		return
	end
	local state: RideState = {
		character = character,
		spinAngle = 0,
		roll = 0,
		wheelRadius = WHEEL_RADIUS_FALLBACK,
	}
	rides[player] = state
	-- Stepped of record (see header timing contract) — never the render step.
	state.stepped = RunService.Stepped:Connect(function(_elapsed: number, deltaTime: number)
		stepRide(player, state, deltaTime)
	end)
end

--------------------------------------------------------------------------------
-- Player watch (attribute + character lifecycle)
--------------------------------------------------------------------------------

local function evaluate(player: Player)
	if player:GetAttribute("BikeActive") == true and player.Character ~= nil then
		startRide(player)
	else
		stopRide(player)
	end
end

local function watchPlayer(player: Player)
	local connections: { RBXScriptConnection } = {
		player:GetAttributeChangedSignal("BikeActive"):Connect(function()
			evaluate(player)
		end),
		player.CharacterAdded:Connect(function()
			evaluate(player)
		end),
		player.CharacterRemoving:Connect(function()
			stopRide(player) -- Transforms die with the rig; HipHeight restored
		end),
	}
	watchConnections[player] = connections
	evaluate(player)
end

--------------------------------------------------------------------------------
-- Lifecycle (auto-registered by the Stage 0 loader; no public API)
--------------------------------------------------------------------------------

local BikeRigPose = {}

function BikeRigPose:Start()
	Players.PlayerAdded:Connect(watchPlayer)
	Players.PlayerRemoving:Connect(function(player: Player)
		stopRide(player)
		local connections = watchConnections[player]
		watchConnections[player] = nil
		if connections ~= nil then
			for _, connection in connections do
				connection:Disconnect()
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
end

return BikeRigPose
