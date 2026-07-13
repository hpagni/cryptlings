--!strict
-- CRYPTLINGS: NIGHT SHIFT — TradeLedger (Stage 4 "Swap-meet trading"; SOP §3.1 ④, §3.3, §8.1).
-- Full trade records of record, keyed by tradeId, in DataStore "TradeLedger_v1" —
-- the rollback capability §3.3/§8.2 require ("full trade logging for rollback";
-- Adopt Me's decay vector was scam fatigue). profile.tradeHistory keeps only a
-- 30-entry summary ring per player; THIS store keeps the complete item lists
-- (full CaseStubs) for both sides so a moderator can manually reverse a scam.
--
-- Public API (TradeService + future rollback tooling only):
--   TradeLedger.Append(record) -> boolean -- SetAsync(tradeId, record), pcall + retry once.
--                                            Never raises; false = not durably stored
--                                            (still kept in the in-memory cache).
--   TradeLedger.Get(tradeId) -> LedgerRecord? -- manual rollback tooling lookup.
--
-- Failure posture: the ledger write happens AFTER the swap is committed to both
-- profiles, so a failed Append never blocks or reverses a trade — it is warned
-- loudly and the record stays in the per-server memory cache as a last resort.
-- Studio/no-DataStore: SetAsync fails inside the pcall, memory cache still works.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared:WaitForChild("Util"))

local STORE_NAME = "TradeLedger_v1"
local APPEND_ATTEMPTS = 2 -- pcall + retry once (spec)
local RETRY_DELAY_SECONDS = 1
local MEMORY_CACHE_MAX = 200 -- recent trades kept per server as the last-resort copy

--------------------------------------------------------------------------------
-- Record shape (written by TradeService.buildLedgerRecord)
--------------------------------------------------------------------------------

export type LedgerSide = {
	userId: number,
	playerName: string,
	gaveCases: { any }, -- full Types.CaseStub list (uid, tier, lineId, acquiredAt, source)
	gaveCryptlings: { [string]: number }, -- cryptlingId -> count
}

export type LedgerRecord = {
	tradeId: string,
	ts: number, -- unix time the swap committed
	jobId: string, -- game.JobId ("" in Studio)
	sides: { [string]: LedgerSide }, -- key = tostring(userId), both parties
	valueWarning: boolean, -- ValueIndex.IsLopsided at execute (§5.4 scam review)
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local TradeLedger = {}

local storeResolved = false
local store: any = nil

-- FIFO-bounded in-memory copy of every record this server appended. Get() falls
-- back to it when the DataStore is unavailable (Studio) or a read fails.
local memory: { [string]: LedgerRecord } = {}
local memoryOrder: { string } = {}

local function getStore(): any
	if storeResolved then
		return store
	end
	storeResolved = true
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn(`[TradeLedger] GetDataStore("{STORE_NAME}") failed: {result}`)
	end
	return store
end

local function cacheInMemory(record: LedgerRecord)
	if memory[record.tradeId] == nil then
		table.insert(memoryOrder, record.tradeId)
		while #memoryOrder > MEMORY_CACHE_MAX do
			local evicted = table.remove(memoryOrder, 1)
			if evicted ~= nil then
				memory[evicted] = nil
			end
		end
	end
	memory[record.tradeId] = record
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Durably stores one completed trade under its tradeId. Yields (SetAsync).
-- Returns true only when the DataStore write succeeded; the in-memory cache is
-- updated either way. Bad records are rejected with false (never raises).
function TradeLedger.Append(record: LedgerRecord): boolean
	if type(record) ~= "table" or type(record.tradeId) ~= "string" or record.tradeId == "" then
		warn("[TradeLedger] Append rejected: record.tradeId missing")
		return false
	end

	-- Deep copy so later mutation by the caller can't corrupt the stored record.
	local frozen = Util.DeepCopy(record)
	cacheInMemory(frozen)

	local dataStore = getStore()
	if dataStore == nil then
		return false
	end

	for attempt = 1, APPEND_ATTEMPTS do
		local ok, err = pcall(function()
			dataStore:SetAsync(record.tradeId, frozen)
		end)
		if ok then
			return true
		end
		warn(`[TradeLedger] SetAsync({record.tradeId}) attempt {attempt}/{APPEND_ATTEMPTS} failed: {err}`)
		if attempt < APPEND_ATTEMPTS then
			task.wait(RETRY_DELAY_SECONDS)
		end
	end
	warn(`[TradeLedger] trade {record.tradeId} NOT durably stored — record retained in memory only`)
	return false
end

-- Lookup for manual rollback tooling (§3.3). Yields (GetAsync). Falls back to
-- the in-memory cache when the DataStore is unavailable or the read fails.
function TradeLedger.Get(tradeId: string): LedgerRecord?
	if type(tradeId) ~= "string" or tradeId == "" then
		return nil
	end

	local dataStore = getStore()
	if dataStore ~= nil then
		local ok, value = pcall(function()
			return dataStore:GetAsync(tradeId)
		end)
		if ok and value ~= nil then
			return value :: LedgerRecord
		end
		if not ok then
			warn(`[TradeLedger] GetAsync({tradeId}) failed: {value}`)
		end
	end
	return memory[tradeId]
end

return TradeLedger
