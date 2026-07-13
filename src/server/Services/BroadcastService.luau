--!strict
-- CRYPTLINGS: NIGHT SHIFT — BroadcastService (Stage 2 "Hub + unboxing theater";
-- SOP §1.2, §3.1 ②). Server-wide "RARE PULL" announcements: every Rare+ unbox
-- is fired to all clients in this server via the RarePullBroadcast remote AND
-- relayed cross-server through MessagingService topic "RarePull" (contract §B).
-- Every MessagingService call is pcall'd so the module is Studio/offline-safe —
-- broadcast theater must never break an unboxing.
--
-- Public API (contract §B / UnboxService):
--   BroadcastService.Announce(playerName, cryptlingId, rarity)
--     -> fires {playerName, cryptlingId, rarity} to all in-server clients and
--        publishes the same payload (plus jobId for self-dedupe) cross-server.

local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RarityTable = require(Shared:WaitForChild("Config"):WaitForChild("RarityTable"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

-- Roblox usernames cap at 20 chars and display names at 20 too; leave headroom
-- so a malformed cross-server payload can never balloon a client toast.
local MAX_NAME_LENGTH = 50

local BroadcastService = {}

local rarePullRemote: RemoteEvent? = nil
local localJobId = game.JobId -- "" in Studio; unique per live server
local publishWarned = false -- warn once, not once per rare pull, when offline

export type RarePullPayload = {
	playerName: string,
	cryptlingId: string,
	rarity: string,
}

--------------------------------------------------------------------------------
-- Payload hygiene — applied to OUR outgoing announces and to every incoming
-- cross-server message (other servers are trusted, but a bad deploy or schema
-- drift must degrade to "no toast", never to a client error).
--------------------------------------------------------------------------------

local function sanitize(playerName: any, cryptlingId: any, rarity: any): RarePullPayload?
	if type(playerName) ~= "string" or playerName == "" or #playerName > MAX_NAME_LENGTH then
		return nil
	end
	if type(cryptlingId) ~= "string" or RarityTable.GetCryptling(cryptlingId) == nil then
		return nil
	end
	if type(rarity) ~= "string" or RarityTable.RARITY_COLORS[rarity] == nil then
		return nil
	end
	return { playerName = playerName, cryptlingId = cryptlingId, rarity = rarity }
end

local function fireLocal(payload: RarePullPayload)
	if rarePullRemote ~= nil then
		rarePullRemote:FireAllClients(payload)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Announces a Rare+ pull to everyone in this server immediately, then relays it
-- cross-server (fire-and-forget; PublishAsync yields, so it runs spawned and
-- never delays the unboxing reply). Never errors, Studio-safe.
function BroadcastService.Announce(playerName: string, cryptlingId: string, rarity: string)
	local payload = sanitize(playerName, cryptlingId, rarity)
	if payload == nil then
		warn(
			`[BroadcastService] Announce dropped invalid payload`
				.. ` ({tostring(playerName)}, {tostring(cryptlingId)}, {tostring(rarity)})`
		)
		return
	end

	fireLocal(payload)

	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(Remotes.MESSAGING_TOPIC_RARE_PULL, {
				playerName = payload.playerName,
				cryptlingId = payload.cryptlingId,
				rarity = payload.rarity,
				jobId = localJobId, -- lets the subscriber skip its own publishes
			})
		end)
		if not ok and not publishWarned then
			publishWarned = true
			warn(`[BroadcastService] cross-server publish unavailable (Studio/offline?): {err}`)
		end
	end)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function BroadcastService:Init()
	-- Remotes already exist (init.server runs Remotes.InitServer() first).
	local ok, err = pcall(function()
		rarePullRemote = Remotes.GetEvent("RarePullBroadcast")
	end)
	if not ok then
		warn(`[BroadcastService] remote bind failed: {err}`)
	end
end

function BroadcastService:Start()
	-- Relay rare pulls from OTHER servers into this one (contract §B). May
	-- yield, so it lives in Start; pcall'd because MessagingService is
	-- unavailable in Studio/offline.
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(Remotes.MESSAGING_TOPIC_RARE_PULL, function(message: any)
			local data = if type(message) == "table" then message.Data else nil
			if type(data) ~= "table" then
				return
			end
			if data.jobId == localJobId then
				return -- our own publish; already shown locally by Announce
			end
			local payload = sanitize(data.playerName, data.cryptlingId, data.rarity)
			if payload ~= nil then
				fireLocal(payload)
			end
		end)
	end)
	if not ok then
		warn(`[BroadcastService] cross-server subscribe unavailable (Studio/offline?): {err}`)
	end
end

return BroadcastService
