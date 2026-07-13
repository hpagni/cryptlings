--!strict
-- CRYPTLINGS: NIGHT SHIFT — AdminReplyUI (R4-1, Addendum 3 / WP1.2).
-- Renders Admin.Reply lines from AdminCommands as colored [Cryptlings] system
-- chat messages. This controller exists because TextChannel:DisplaySystemMessage
-- is CLIENT-ONLY (server-side support was declined and has not shipped as of
-- mid-2026) — the server fires the invoker-only Admin.Reply RemoteEvent and this
-- module does the local render.
--
-- SECURITY (R4 plan §5): S->C only — this module NEVER fires anything back to
-- the server. Payload is validated fail-closed (text must be a string, isError
-- must be a boolean — anything else is dropped silently), clamped to
-- MAX_REPLY_CHARS, and rich-text escaped (&, <, >) BEFORE interpolation into
-- the <font> wrapper, so server copy can never inject markup into chat.
--
-- Colors: #66ff99 normal, #ff6666 error (spec of record, Addendum 3 R4-1 §8).
-- No Init, no other remotes, no UI instances — chat channel render only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"):WaitForChild("Remotes"))

local MAX_REPLY_CHARS = 200
local COLOR_NORMAL = "#66ff99"
local COLOR_ERROR = "#ff6666"
local PREFIX = "[Cryptlings]"

local AdminReplyUI = {}

-- Escapes rich-text metacharacters so reply text renders literally inside the
-- <font> tag. "&" must be escaped FIRST or it would re-escape the entities.
local function escapeRichText(text: string): string
	local escaped = string.gsub(text, "&", "&amp;")
	escaped = string.gsub(escaped, "<", "&lt;")
	escaped = string.gsub(escaped, ">", "&gt;")
	return escaped
end

-- Start is spawned by the client loader, so the bounded waits here are safe:
-- replies fired before the chat channel resolves are dropped (admin feedback
-- is interactive-only; nothing load-bearing arrives at boot). Waits are
-- TIMEOUT-BOUNDED so a place with chat disabled (or an offline-built rbxl
-- where TextChannels never materializes) degrades to a one-line warn instead
-- of an infinite-yield warning (R4 smoke finding P2).
local CHANNEL_WAIT_SECONDS = 15

function AdminReplyUI:Start()
	local channelsFolder = TextChatService:WaitForChild("TextChannels", CHANNEL_WAIT_SECONDS)
	local generalInstance = channelsFolder and channelsFolder:WaitForChild("RBXGeneral", CHANNEL_WAIT_SECONDS)
	if generalInstance == nil or not generalInstance:IsA("TextChannel") then
		warn("[AdminReplyUI] chat channel unavailable — admin replies disabled")
		return
	end
	local general = generalInstance :: TextChannel

	Remotes.GetEvent("Admin.Reply").OnClientEvent:Connect(function(text: unknown, isError: unknown)
		if type(text) ~= "string" or type(isError) ~= "boolean" then
			return -- fail closed: malformed payloads render nothing
		end
		local escaped = escapeRichText(string.sub(text, 1, MAX_REPLY_CHARS))
		local color = if isError then COLOR_ERROR else COLOR_NORMAL
		general:DisplaySystemMessage(`<font color="{color}">{PREFIX} {escaped}</font>`)
	end)
end

return AdminReplyUI
