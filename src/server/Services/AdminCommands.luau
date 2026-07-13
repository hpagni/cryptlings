--!strict
-- CRYPTLINGS: NIGHT SHIFT — AdminCommands (R4-1 chat capture + parse + reply;
-- LOBBY_SOP_ADDENDUM_3 §R4-1, LOBBY_BUILD_PLAN_R4 WP1.1).
--
-- ZERO authority of its own: every mutation goes through AdminService
-- (Grant/Revoke/UnlockAll all first-line re-assert the actor) and
-- MonetizationService.GrantSkuForAdmin gates again at the grant itself. This
-- module only captures chat, dedupes, rate-limits, resolves targets, replies.
--
-- Dual chat capture (legacy chat was force-migrated to TextChatService
-- April 30 2025):
--   * Primary: SERVER-created TextChatCommand instances under TextChatService
--     (client-created commands fail to sink messages — known engine bug):
--     /unlockall (SecondaryAlias /ua), /admin, /unadmin — all with
--     AutocompleteVisible = false so non-admins never see them. Identity is
--     ONLY originTextSource.UserId (engine-supplied, unspoofable); the raw
--     text is parsed for ARGUMENTS only, never for identity. Matched messages
--     are sunk from public chat.
--   * Fallback: player.Chatted filtered to a "/" prefix (slash-prefix Chatted
--     regressed Aug 2025 and was restored by staff, who recommend
--     TextChatCommand.Triggered as primary — the fallback is insurance only).
--   * Dedupe: BOTH paths funnel into handle(), keyed userId.."\0"..rawText
--     with a 0.5 s suppression window, so one message reaching both paths
--     executes exactly once.
--
-- handle() order of operations: dedupe -> token bucket (AdminConfig.RateLimit,
-- 5 commands / 10 s; over-limit gets an error reply if admin, SILENT drop
-- otherwise) -> AdminService.IsAdmin (non-admins: silent return — zero
-- feedback, no probing surface) -> string.split dispatch.
--
-- Replies go over the Admin.Reply RemoteEvent (S->C, invoker-only; rendered by
-- AdminReplyUI) because TextChannel:DisplaySystemMessage is client-only
-- (server-side support declined; unshipped as of mid-2026).
--
-- Studio test seam: RunCommandForTest(invoker, raw) — IsStudio FIRST LINE,
-- funnels into the same handle() as both chat paths.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminConfig = require(Shared:WaitForChild("Config"):WaitForChild("AdminConfig"))
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local DEDUPE_WINDOW_SECONDS = 0.5 -- dual-path suppression (R4-1 §1)
local RATE_LIMIT_MAX = AdminConfig.RateLimit.max -- 5 commands ...
local RATE_LIMIT_WINDOW_SECONDS = AdminConfig.RateLimit.windowSec -- ... per 10 s

--------------------------------------------------------------------------------
-- Lazy sibling resolution (house pattern: a missing parallel-stage module
-- degrades the feature, never the boot)
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

local AdminCommands = {}

-- Dedupe: (userId .. "\0" .. rawText) -> os.clock() of last execution.
local recentCommands: { [string]: number } = {}

-- Token bucket: userId -> os.clock() stamps inside the sliding window.
local commandStamps: { [number]: { number } } = {}

-- Chatted-fallback double-wire guard (Start connect + catch-up sweep race).
local chattedWired: { [Player]: boolean } = {}

--------------------------------------------------------------------------------
-- Reply — Admin.Reply (S->C, invoker-only). pcall'd: the remote name is
-- registered by the same-wave Remotes change; mid-construction builds degrade
-- to log-only instead of erroring.
--------------------------------------------------------------------------------

local function reply(player: Player, text: string, isError: boolean)
	local ok, err = pcall(function()
		Remotes.GetEvent("Admin.Reply"):FireClient(player, text, isError)
	end)
	if not ok then
		warn(`[AdminCommands] Admin.Reply push failed for {player.Name}: {err}`)
	end
end

--------------------------------------------------------------------------------
-- Dedupe + rate limit
--------------------------------------------------------------------------------

local function isDuplicate(userId: number, rawText: string): boolean
	local now = os.clock()
	-- Prune stale keys first so the dual-path map can never grow unbounded.
	for key, stamp in recentCommands do
		if now - stamp > DEDUPE_WINDOW_SECONDS then
			recentCommands[key] = nil
		end
	end
	local key = tostring(userId) .. "\0" .. rawText
	if recentCommands[key] ~= nil then
		return true -- the other capture path already executed this message
	end
	recentCommands[key] = now
	return false
end

-- Sliding-window token bucket: returns true when this command must be DROPPED.
-- Only under-limit commands consume a token, so a flood can't extend its own
-- lockout past the window.
local function overRateLimit(userId: number): boolean
	local now = os.clock()
	local stamps = commandStamps[userId]
	if stamps == nil then
		stamps = {}
		commandStamps[userId] = stamps
	end
	local i = 1
	while i <= #stamps do
		if now - stamps[i] > RATE_LIMIT_WINDOW_SECONDS then
			table.remove(stamps, i)
		else
			i += 1
		end
	end
	if #stamps >= RATE_LIMIT_MAX then
		return true
	end
	table.insert(stamps, now)
	return false
end

--------------------------------------------------------------------------------
-- Partial-name target resolver (R4-1 §4). Live players only; NEVER auto-picks
-- on ambiguity (display names are non-unique).
--------------------------------------------------------------------------------

local function resolve(query: string?, invoker: Player): (Player?, string?)
	if query == nil or query == "" or string.lower(query) == "me" then
		return invoker, nil
	end
	local q = string.lower(query)
	local matches: { Player } = {}
	for _, candidate in Players:GetPlayers() do
		if string.lower(candidate.Name) == q then
			return candidate, nil -- exact Name match short-circuits ("Bob" beats "Bobby2")
		end
		if
			string.sub(string.lower(candidate.Name), 1, #q) == q
			or string.sub(string.lower(candidate.DisplayName), 1, #q) == q
		then
			table.insert(matches, candidate)
		end
	end
	if #matches == 0 then
		return nil, `No player matching '{query}'`
	end
	if #matches > 1 then
		local names: { string } = {}
		for _, match in matches do
			table.insert(names, match.Name)
		end
		return nil, `Ambiguous: {table.concat(names, ", ")}`
	end
	return matches[1], nil
end

--------------------------------------------------------------------------------
-- Command runners — authority lives in AdminService, never here.
--------------------------------------------------------------------------------

local function runUnlockAll(adminService: any, invoker: Player, query: string?)
	local target, resolveErr = resolve(query, invoker)
	if target == nil then
		reply(invoker, resolveErr or "No matching player", true)
		return
	end
	local result = adminService.UnlockAll(target, invoker.UserId)
	if type(result) == "table" and result.ok == true then
		reply(
			invoker,
			`Unlocked everything for {target.Name}: granted={tostring(result.granted)}, skipped={tostring(
				result.skipped
			)}.`,
			false
		)
	else
		local why = if type(result) == "table" then tostring(result.err) else "ERROR"
		reply(invoker, `Unlock failed: {why}`, true)
	end
end

local function runAdminGrant(adminService: any, invoker: Player, query: string?)
	local target, resolveErr = resolve(query, invoker)
	if target == nil then
		reply(invoker, resolveErr or "No matching player", true)
		return
	end
	local result = adminService.Grant(target, invoker.UserId)
	if type(result) == "table" and result.ok == true then
		-- R4-1 §3: /admin replies to BOTH granter and grantee.
		reply(invoker, `{target.Name} can use admin commands for this session.`, false)
		if target ~= invoker then
			reply(target, `{invoker.Name} granted you admin commands for this session.`, false)
		end
	else
		local why = if type(result) == "table" then tostring(result.err) else "ERROR"
		reply(invoker, `Admin grant failed: {why}`, true)
	end
end

local function runAdminRevoke(adminService: any, invoker: Player, query: string?)
	local target, resolveErr = resolve(query, invoker)
	if target == nil then
		reply(invoker, resolveErr or "No matching player", true)
		return
	end
	local result = adminService.Revoke(target, invoker.UserId)
	if type(result) == "table" and result.ok == true then
		reply(invoker, `Revoked session admin from {target.Name}.`, false)
	elseif type(result) == "table" and result.err == "IS_CREATOR" then
		reply(invoker, "The creator cannot be revoked.", true)
	else
		local why = if type(result) == "table" then tostring(result.err) else "ERROR"
		reply(invoker, `Revoke failed: {why}`, true)
	end
end

--------------------------------------------------------------------------------
-- handle — the single funnel for BOTH capture paths and the Studio seam.
-- Identity arrives as an engine-supplied userId, never parsed from text.
--------------------------------------------------------------------------------

local function handle(userId: number, rawText: string)
	if type(userId) ~= "number" or type(rawText) ~= "string" or rawText == "" then
		return
	end
	if isDuplicate(userId, rawText) then
		return
	end

	local adminService = getSibling("AdminService")
	local isAdmin = adminService ~= nil
		and type(adminService.IsAdmin) == "function"
		and adminService.IsAdmin(userId) == true
	local invoker = Players:GetPlayerByUserId(userId)

	if overRateLimit(userId) then
		if isAdmin and invoker ~= nil then
			reply(invoker, "Rate limit: wait a few seconds before the next command.", true)
		end
		return -- silent drop for everyone else
	end
	if not isAdmin or invoker == nil then
		return -- non-admins get ZERO feedback — no probing surface (R4-1 §2)
	end

	local parts = string.split(rawText, " ")
	local command = string.lower(parts[1])
	local query: string? = parts[2]
	if command == "/unlockall" or command == "/ua" then
		runUnlockAll(adminService, invoker, query)
	elseif command == "/admin" then
		runAdminGrant(adminService, invoker, query)
	elseif command == "/unadmin" then
		runAdminRevoke(adminService, invoker, query)
	end
end

--------------------------------------------------------------------------------
-- Capture wiring
--------------------------------------------------------------------------------

-- SERVER-created TextChatCommand (client-created commands fail to sink —
-- known engine bug). pcall'd: a Studio rig without TextChatService command
-- support degrades to the Chatted fallback instead of breaking boot.
local function createChatCommand(name: string, primaryAlias: string, secondaryAlias: string?)
	local ok, err = pcall(function()
		local command = Instance.new("TextChatCommand")
		command.Name = name
		command.PrimaryAlias = primaryAlias
		if secondaryAlias ~= nil then
			command.SecondaryAlias = secondaryAlias
		end
		command.AutocompleteVisible = false -- non-admins never see the commands
		command.Triggered:Connect(function(originTextSource: TextSource, unfilteredText: string)
			-- originTextSource.UserId is the ONLY trusted identity (engine-
			-- supplied, unspoofable); unfilteredText is parsed for args only.
			handle(originTextSource.UserId, unfilteredText)
		end)
		command.Parent = TextChatService
	end)
	if not ok then
		warn(`[AdminCommands] TextChatCommand {primaryAlias} setup failed ({err}) — Chatted fallback covers it`)
	end
end

-- Insurance path: player.Chatted still fires server-side under TextChatService.
local function wireChattedFallback(player: Player)
	if chattedWired[player] then
		return
	end
	chattedWired[player] = true
	player.Chatted:Connect(function(message: string)
		if string.sub(message, 1, 1) == "/" then
			handle(player.UserId, message)
		end
	end)
end

--------------------------------------------------------------------------------
-- Studio test seam (binding decision 8): same funnel as both chat paths.
--------------------------------------------------------------------------------

function AdminCommands.RunCommandForTest(invoker: Player, raw: string)
	if not RunService:IsStudio() then
		return
	end
	if typeof(invoker) ~= "Instance" or not invoker:IsA("Player") or type(raw) ~= "string" then
		return
	end
	handle(invoker.UserId, raw)
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function AdminCommands:Start()
	createChatCommand("CryptlingsUnlockAll", "/unlockall", "/ua")
	createChatCommand("CryptlingsAdmin", "/admin", nil)
	createChatCommand("CryptlingsUnadmin", "/unadmin", nil)

	Players.PlayerAdded:Connect(wireChattedFallback)
	for _, player in Players:GetPlayers() do
		wireChattedFallback(player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		chattedWired[player] = nil
		commandStamps[player.UserId] = nil
	end)
end

return AdminCommands
