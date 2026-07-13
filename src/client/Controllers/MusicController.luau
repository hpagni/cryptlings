--!strict
-- CRYPTLINGS: NIGHT SHIFT — MusicController (dynamic spooky score).
-- Real licensed ambience from the Roblox Creator Store (free-to-use library
-- audio, validated to load in this experience) layered into a tension ramp
-- driven by the shift clock:
--   * AMBIENT bed  — "Forgotten Crypt Ambient": loops for the whole run.
--   * TENSION layer — "Wailing Winds": silent at first, fades in over the
--     back half of the shift, and its PlaybackSpeed climbs as the clock
--     drains (the "music speeds up as time runs out" beat).
-- Mixed LOW on purpose (background score, not foreground). The old repeating
-- bass pulse was cut per playtest feedback ("constant buzz"); the tempo ramp
-- lives in the tension layer's speed climb. Plays only while THIS player is
-- mid-run (ShiftState payload.participant); hub bystanders get silence.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

local LocalPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tuning (cosmetic, this module's domain)
--------------------------------------------------------------------------------

-- Creator Store library audio (validated: loads + correct length in Studio).
local AMBIENT_SOUND_ID = "rbxassetid://139743346356072" -- "Forgotten Crypt Ambient" (218s)
local TENSION_SOUND_ID = "rbxassetid://138056737764176" -- "Wailing Winds" (127s)

local AMBIENT_VOLUME_CALM = 0.15
local AMBIENT_VOLUME_PANIC = 0.22 -- creeps up slightly so the mix never drops

local TENSION_START_FRACTION = 0.5 -- tension layer enters at half time left
local TENSION_VOLUME_MAX = 0.3
local TENSION_SPEED_CALM = 1.0
local TENSION_SPEED_PANIC = 1.25 -- pitch/tempo climb as the clock drains

local MIX_STEP_SECONDS = 0.25 -- volume/speed ramp update cadence
local FADE_OUT_SECONDS = 1.5 -- run end: quick fade instead of a hard cut

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local MusicController = {}

local playing = false
local shiftEndsAt = 0 -- unix; from ShiftState
local shiftDuration = 1 -- seconds; measured when the run starts

local ambientSound: Sound? = nil
local tensionSound: Sound? = nil

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

local function makeSound(parent: Instance, name: string, soundId: string, looped: boolean): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Looped = looped
	sound.Parent = parent
	return sound
end

-- 1 with a full clock -> 0 at shift end (server-synced unix clock).
local function remainingFraction(): number
	local remaining = shiftEndsAt - workspace:GetServerTimeNow()
	return math.clamp(remaining / math.max(shiftDuration, 1), 0, 1)
end

local function startMusic(endsAt: number)
	shiftEndsAt = endsAt
	shiftDuration = math.max(endsAt - workspace:GetServerTimeNow(), 1)
	if playing then
		return
	end
	playing = true
	local ambient = ambientSound
	if ambient ~= nil then
		ambient.Volume = AMBIENT_VOLUME_CALM
		ambient:Play()
	end
	local tension = tensionSound
	if tension ~= nil then
		tension.Volume = 0
		tension.PlaybackSpeed = TENSION_SPEED_CALM
		tension:Play()
	end
end

local function stopMusic()
	if not playing then
		return
	end
	playing = false
	-- Quick fade so extraction/death never hard-cuts the score.
	task.spawn(function()
		local ambient = ambientSound
		local tension = tensionSound
		-- Fade from the CURRENT mix, not the end-of-shift one: an early end can
		-- arrive while the tension layer is still silent, and snapping it to the
		-- panic level would pop it in from nothing.
		local ambientStart = if ambient ~= nil then ambient.Volume else 0
		local tensionStart = if tension ~= nil then tension.Volume else 0
		local steps = 10
		for step = 1, steps do
			if playing then
				return -- a new run started mid-fade; leave its levels alone
			end
			local mult = 1 - step / steps
			if ambient ~= nil then
				ambient.Volume = ambientStart * mult
			end
			if tension ~= nil then
				tension.Volume = tensionStart * mult
			end
			task.wait(FADE_OUT_SECONDS / steps)
		end
		if not playing then
			if ambient ~= nil then
				ambient:Stop()
			end
			if tension ~= nil then
				tension:Stop()
			end
		end
	end)
end

local function onShiftState(payload: any)
	if type(payload) ~= "table" or type(payload.state) ~= "string" then
		return
	end
	if payload.state == "Active" and payload.participant == true and type(payload.shiftEndsAt) == "number" then
		startMusic(payload.shiftEndsAt)
	else
		stopMusic()
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function MusicController:Init(_registry: any) end

function MusicController:Start()
	local gui = Instance.new("ScreenGui") -- sound container only; renders nothing
	gui.Name = "MusicController"
	gui.ResetOnSpawn = false
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	ambientSound = makeSound(gui, "Ambient", AMBIENT_SOUND_ID, true)
	tensionSound = makeSound(gui, "Tension", TENSION_SOUND_ID, true)

	Remotes.GetEvent("ShiftState").OnClientEvent:Connect(onShiftState)

	-- The local run also ends on extraction or death, but the server only
	-- re-broadcasts ShiftState at state transitions — stop the score here so
	-- it never keeps ramping over the hub while teammates finish the shift.
	Remotes.GetEvent("ExtractionResult").OnClientEvent:Connect(function(_payload: any)
		stopMusic() -- owner-only remote: any payload means OUR run just ended
	end)

	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid ~= nil and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(stopMusic)
		end
	end
	LocalPlayer.CharacterAdded:Connect(watchCharacter)
	if LocalPlayer.Character ~= nil then
		task.spawn(watchCharacter, LocalPlayer.Character)
	end

	-- Mix ramp: tension fades in and speeds up as the clock drains.
	task.spawn(function()
		while true do
			if playing then
				local frac = remainingFraction()
				local panic = 1 - frac
				local ambient = ambientSound
				if ambient ~= nil then
					ambient.Volume = AMBIENT_VOLUME_CALM + (AMBIENT_VOLUME_PANIC - AMBIENT_VOLUME_CALM) * panic
				end
				local tension = tensionSound
				if tension ~= nil then
					local enter = math.clamp((TENSION_START_FRACTION - frac) / TENSION_START_FRACTION, 0, 1)
					tension.Volume = TENSION_VOLUME_MAX * enter
					tension.PlaybackSpeed = TENSION_SPEED_CALM + (TENSION_SPEED_PANIC - TENSION_SPEED_CALM) * panic
				end
			end
			task.wait(MIX_STEP_SECONDS)
		end
	end)
end

return MusicController
