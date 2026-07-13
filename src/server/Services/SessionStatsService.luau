--!strict
-- CRYPTLINGS: NIGHT SHIFT — SessionStatsService (R2 Addendum 1 Change 2, AC-2).
-- "Best Employees" data layer + board renderer: per-server-session banked-crate
-- counts feeding the BestEmployeesBoard cards HubService captures from
-- QueuePadBuilder. ExtractionService calls AddCrates(player, n) strictly on the
-- saved-bank path (saved == true, n > 0) — banked-at-extraction is the metric
-- (exploit-resistant, fits the employee fiction). Entries persist for the whole
-- server session: players who leave stay on the board (DisplayName is cached at
-- increment time because the Player object dies on leave); reset only on server
-- death. Event-driven render: dirty flag + 0.25 s debounce coalescing
-- concurrent-floor extraction bursts, signature skip for identical renders —
-- no polling, no persistence (per-server session stats only).
--
-- Portraits: rbxthumb://type=AvatarHeadShot&id=<userId>&w=150&h=150
-- (LobbyConfig.BEST_EMPLOYEES.THUMB) set directly on ImageLabel.Image — the
-- engine batches thumbnail loads and auto-retries 3 times; a blank portrait
-- after those retries is accepted degradation (name + count still render).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared:WaitForChild("Config"):WaitForChild("LobbyConfig"))

local BOARD = LobbyConfig.BEST_EMPLOYEES

--------------------------------------------------------------------------------
-- Lazy sibling resolution
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

type StatEntry = {
	count: number,
	firstAt: number, -- os.clock() when the current count was first reached (tie-break)
	displayName: string, -- cached at increment time (Player object dies on leave)
}

type TopEntry = {
	userId: number,
	entry: StatEntry,
}

local SessionStatsService = {}

-- Server-session persistent: entries are NEVER removed when a player leaves.
local stats: { [number]: StatEntry } = {}

local lastSignature = "" -- "u1:c1|u2:c2|u3:c3|u4:c4" — skip identical renders
local renderScheduled = false -- dirty flag; coalesces bursts under the debounce

-- Builder-built empty-card look (silhouette asset + tint), captured on first
-- touch so empty slots restore exactly what QueuePadBuilder shipped.
local portraitDefaults: { [ImageLabel]: { image: string, color: Color3 } } = {}

--------------------------------------------------------------------------------
-- Ranking
--------------------------------------------------------------------------------

-- Deterministic comparator (Luau table.sort is unstable): count desc ->
-- firstAt asc (earliest to reach the count wins ties) -> userId asc.
local function compare(a: TopEntry, b: TopEntry): boolean
	if a.entry.count ~= b.entry.count then
		return a.entry.count > b.entry.count
	end
	if a.entry.firstAt ~= b.entry.firstAt then
		return a.entry.firstAt < b.entry.firstAt
	end
	return a.userId < b.userId
end

local function topEmployees(): { TopEntry }
	local list: { TopEntry } = {}
	for userId, entry in stats do
		table.insert(list, { userId = userId, entry = entry })
	end
	table.sort(list, compare)
	local count = math.min(#list, BOARD.CARD_COUNT)
	return table.move(list, 1, count, 1, {})
end

local function buildSignature(top: { TopEntry }): string
	local parts = table.create(BOARD.CARD_COUNT, "")
	for index, item in top do
		parts[index] = `{item.userId}:{item.entry.count}`
	end
	return table.concat(parts, "|")
end

--------------------------------------------------------------------------------
-- Board rendering
--------------------------------------------------------------------------------

-- Cards come from HubService's captured QueuePadBuilder fixture (Wave-2
-- contract: { {portrait, nameLabel, statLabel, rankLabel, card} }). Feature-
-- detected + pcall-fenced: absent mid-construction board = silent no-op.
local function getCards(): { any }?
	local hub = getSibling("HubService")
	if hub == nil or type(hub.GetBestEmployeesBoard) ~= "function" then
		return nil
	end
	local ok, board = pcall(hub.GetBestEmployeesBoard)
	if not ok or type(board) ~= "table" then
		return nil
	end
	local cards: any = board
	if type(board.bestEmployeesCards) == "table" then
		cards = board.bestEmployeesCards
	elseif type(board.cards) == "table" then
		cards = board.cards
	end
	if type(cards) ~= "table" or #cards == 0 then
		return nil
	end
	return cards
end

local function setText(label: any, text: string)
	if typeof(label) == "Instance" and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function setPortrait(portrait: any, userId: number?)
	if typeof(portrait) ~= "Instance" or not portrait:IsA("ImageLabel") then
		return
	end
	local defaults = portraitDefaults[portrait]
	if defaults == nil then
		defaults = { image = portrait.Image, color = portrait.ImageColor3 }
		portraitDefaults[portrait] = defaults
	end
	if userId ~= nil then
		portrait.Image = string.format(BOARD.THUMB, userId)
		portrait.ImageColor3 = Color3.new(1, 1, 1)
	else
		portrait.Image = defaults.image -- builder silhouette
		portrait.ImageColor3 = defaults.color -- silhouette tint
	end
end

local function render()
	local top = topEmployees()
	local signature = buildSignature(top)
	if signature == lastSignature then
		return -- identical render — skip (lastRosterSignature pattern)
	end
	local cards = getCards()
	if cards == nil then
		return -- board not available; lastSignature stays stale so the next bank retries
	end

	for index = 1, BOARD.CARD_COUNT do
		local card = cards[index]
		if type(card) ~= "table" then
			continue
		end
		local item = top[index]
		setText(card.rankLabel, `#{index}`)
		if item ~= nil then
			setText(card.nameLabel, item.entry.displayName)
			setText(card.statLabel, `{item.entry.count} CRATES`)
			setPortrait(card.portrait, item.userId)
		elseif index == 1 then
			-- Slot 1 empty means the whole board is empty (top is contiguous):
			-- CTA pointing at the queue pad.
			setText(card.nameLabel, "BE THE FIRST!")
			setText(card.statLabel, "CLOCK IN →")
			setPortrait(card.portrait, nil)
		else
			setText(card.nameLabel, "POSITION OPEN")
			setText(card.statLabel, "—")
			setPortrait(card.portrait, nil)
		end
	end

	lastSignature = signature
end

-- Whole render pcall-fenced — a board failure never touches sibling services.
local function safeRender()
	local ok, err = pcall(render)
	if not ok then
		warn(`[SessionStatsService] board render failed: {err}`)
	end
end

local function scheduleRender()
	if renderScheduled then
		return
	end
	renderScheduled = true
	task.delay(BOARD.DEBOUNCE_SECONDS, function()
		renderScheduled = false
		safeRender()
	end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Called by ExtractionService only, on the saved-bank path (#stubs > 0 and
-- saved == true). Increments the player's session total, stamps firstAt the
-- moment the new count is first reached, and re-caches DisplayName.
function SessionStatsService.AddCrates(player: Player, n: number)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if type(n) ~= "number" then
		return
	end
	local amount = math.floor(n)
	if amount < 1 then
		return
	end

	local userId = player.UserId
	local entry = stats[userId]
	if entry == nil then
		entry = { count = 0, firstAt = 0, displayName = player.DisplayName }
		stats[userId] = entry
	end
	entry.count += amount
	entry.firstAt = os.clock() -- first moment this new count was reached
	entry.displayName = player.DisplayName

	scheduleRender()
end

--------------------------------------------------------------------------------
-- Loader lifecycle
--------------------------------------------------------------------------------

function SessionStatsService:Init()
	-- HubService (H < Se alphabetically) already built the board in its Init,
	-- so the fully-empty "BE THE FIRST!" CTA renders at boot. Non-yielding and
	-- pcall-fenced; if the board fixture is absent the render no-ops and the
	-- first bank event retries.
	safeRender()
end

return SessionStatsService
