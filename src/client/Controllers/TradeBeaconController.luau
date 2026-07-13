--!strict
-- CRYPTLINGS: NIGHT SHIFT — TradeBeaconController (R2 change set WP3.2;
-- Addendum 1 Change 5, AC-5). The swap-meet beacon is an industrial andon
-- light: steady full-bright white = available (NO animation — flashing while
-- idle would invert the convention), smooth green pulse = trade in progress.
--
-- Server side: PlazaBuilder builds the Neon head (tag "SwapMeetBeacon") and
-- TradeService stamps the boolean `TradeActive` attribute on it when a trade
-- session goes active, clearing it on complete/cancel/disconnect (all three
-- funnel through the same server path, so this controller needs no special
-- disconnect handling). EVERY tween runs client-side off that attribute —
-- server tweens replicate per-step and stutter (standing invariant).
--
--   * TradeActive -> true: SWAP_BEACON.TO_GREEN_SECONDS (0.4 s) tween white
--     -> dim green, then a looped TweenService tween on the part's **Color3**
--     between GREEN_DIM (40,120,60) and GREEN_BRIGHT (90,255,120), TweenInfo
--     (PULSE_SECONDS 1.2, Sine, InOut, -1, reverses) — the house LEGENDARY
--     cadence, ~0.8 Hz, far under the WCAG 2.3.1 3-flash/s ceiling — paired
--     with Transparency 0 <-> 0.25 in the same tween.
--   * TradeActive -> false: cancel the loop, TO_WHITE_SECONDS (0.6 s) tween
--     back to steady white + the part's as-built transparency.
--   * Never hard-blink, strobe, or red (fault/alarm reads); never tween a
--     Beam ColorSequence (not tweenable — the head is a Part, Color3 only).
--
-- Discovery is streaming-safe (GetTagged + added/removed signals, the
-- PodiumDisplayController idiom); zero Light instances, zero remotes, no
-- public API beyond the loader lifecycle.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

--------------------------------------------------------------------------------
-- Tuning (numbers of record live in LobbyConfig.SWAP_BEACON — Addendum 1 §5)
--------------------------------------------------------------------------------

local TAG_BEACON = "SwapMeetBeacon" -- PlazaBuilder tags the Neon head
local ATTR_TRADE_ACTIVE = "TradeActive" -- TradeService-stamped display mirror

local SWAP_BEACON = LobbyConfig.SWAP_BEACON

local function toColor3(rgb: { R: number, G: number, B: number }): Color3
	return Color3.fromRGB(rgb.R, rgb.G, rgb.B)
end

local COLOR_IDLE = toColor3(SWAP_BEACON.IDLE_COLOR) -- steady white (255,255,255)
local COLOR_GREEN_DIM = toColor3(SWAP_BEACON.GREEN_DIM)
local COLOR_GREEN_BRIGHT = toColor3(SWAP_BEACON.GREEN_BRIGHT)

local PULSE_MAX_TRANSPARENCY = 0.25 -- paired with the Color3 pulse (spec option taken)

local TWEEN_TO_GREEN = TweenInfo.new(SWAP_BEACON.TO_GREEN_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local TWEEN_TO_WHITE = TweenInfo.new(SWAP_BEACON.TO_WHITE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local TWEEN_PULSE =
	TweenInfo.new(SWAP_BEACON.PULSE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type BeaconEntry = {
	part: BasePart,
	baseTransparency: number, -- as-built idle transparency, restored on trade end
	connection: RBXScriptConnection,
	activeTween: Tween?, -- the in-flight to-green / to-white transition
	loopTween: Tween?, -- the perpetual green pulse
	token: number, -- invalidates a stale to-green Completed handler
}

local TradeBeaconController = {}

local beacons: { [BasePart]: BeaconEntry } = {}

--------------------------------------------------------------------------------
-- Tween lifecycle
--------------------------------------------------------------------------------

local function cancelTweens(entry: BeaconEntry)
	entry.token += 1
	if entry.activeTween ~= nil then
		entry.activeTween:Cancel()
		entry.activeTween = nil
	end
	if entry.loopTween ~= nil then
		entry.loopTween:Cancel()
		entry.loopTween = nil
	end
end

-- Active trade: 0.4 s white -> dim green, then the looped 1.2 s Sine pulse
-- between the two greens (Color3 + Transparency in the same tween).
local function applyActive(entry: BeaconEntry)
	cancelTweens(entry)
	local token = entry.token

	local toGreen = TweenService:Create(entry.part, TWEEN_TO_GREEN, {
		Color = COLOR_GREEN_DIM,
		Transparency = 0,
	})
	entry.activeTween = toGreen
	toGreen.Completed:Connect(function(playbackState: Enum.PlaybackState)
		if entry.token ~= token or playbackState ~= Enum.PlaybackState.Completed then
			return -- cancelled (trade ended / beacon unbound mid-transition)
		end
		entry.activeTween = nil
		local pulse = TweenService:Create(entry.part, TWEEN_PULSE, {
			Color = COLOR_GREEN_BRIGHT,
			Transparency = PULSE_MAX_TRANSPARENCY,
		})
		entry.loopTween = pulse
		pulse:Play()
	end)
	toGreen:Play()
end

-- Trade over (complete, cancel, or disconnect — the server attribute clears
-- on all three): kill the pulse, 0.6 s back to steady white.
local function applyIdle(entry: BeaconEntry)
	cancelTweens(entry)
	local toWhite = TweenService:Create(entry.part, TWEEN_TO_WHITE, {
		Color = COLOR_IDLE,
		Transparency = entry.baseTransparency,
	})
	entry.activeTween = toWhite
	toWhite:Play()
end

local function refresh(entry: BeaconEntry)
	if entry.part:GetAttribute(ATTR_TRADE_ACTIVE) == true then
		applyActive(entry)
	else
		applyIdle(entry)
	end
end

--------------------------------------------------------------------------------
-- Discovery (streaming-safe: tagged parts come and go with the stream)
--------------------------------------------------------------------------------

local function bind(instance: Instance)
	if not instance:IsA("BasePart") or beacons[instance] ~= nil then
		return
	end
	local entry: BeaconEntry = {
		part = instance,
		baseTransparency = instance.Transparency,
		connection = instance:GetAttributeChangedSignal(ATTR_TRADE_ACTIVE):Connect(function()
			local current = beacons[instance]
			if current ~= nil then
				refresh(current)
			end
		end),
		activeTween = nil,
		loopTween = nil,
		token = 0,
	}
	beacons[instance] = entry

	-- A trade may already be running when the beacon streams in: animate to
	-- green; otherwise snap to the idle read (no animation while available).
	if instance:GetAttribute(ATTR_TRADE_ACTIVE) == true then
		applyActive(entry)
	else
		instance.Color = COLOR_IDLE
		instance.Transparency = entry.baseTransparency
	end
end

local function unbind(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local entry = beacons[instance]
	if entry == nil then
		return
	end
	beacons[instance] = nil
	cancelTweens(entry)
	entry.connection:Disconnect()
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function TradeBeaconController:Init()
	-- Connections only (Init must not yield). Beacons tagged before Start are
	-- picked up by the Start sweep below.
	CollectionService:GetInstanceAddedSignal(TAG_BEACON):Connect(function(instance: Instance)
		-- Deferred so a just-streamed head's attributes replicate before we read.
		task.defer(bind, instance)
	end)
	CollectionService:GetInstanceRemovedSignal(TAG_BEACON):Connect(unbind)
end

function TradeBeaconController:Start()
	for _, instance in CollectionService:GetTagged(TAG_BEACON) do
		bind(instance)
	end
end

return TradeBeaconController
