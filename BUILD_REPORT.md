# Cryptlings: Night Shift — MVP Build Report

Final integration verification of the MVP build. Repo: `C:\Users\hudso\roblox-game` (Rojo project, local git, branch `master`).

## Gate results (all green)

| Gate | Result |
| --- | --- |
| `selene src` | 0 errors, 0 warnings, 0 parse errors |
| `stylua --check src` | clean (no formatting needed) |
| `lune run tests/run` | 35/35 tests pass (4 suites) |
| `rojo build -o Cryptlings.rbxl` | builds successfully (file is gitignored) |

Working tree was clean at verification start — all hardening-agent work was already committed; no integration commit was required beyond this report.

## Systems implemented, per stage (git log)

| Commit | Stage | Systems |
| --- | --- | --- |
| `9b04e23` | Project setup | Docs (SOP.md, concept.md, trend_brief.md, research/), Rokit toolchain, Rojo/Wally/Selene/StyLua scaffold |
| `97a6352` / `c03ac9e` | Stage 0 — Foundations | Frozen server/client loaders, Remotes registry, Types, GameConstants, RarityTable (single TIER_WEIGHTS source for rolls AND disclosure), PriceLadder (18 SKUs, SOP §4.2), ProfileService-backed PlayerDataService (session locks, re-entrant per-player mutex, daily reset, d1_return funnel), AnalyticsService (Roblox `AnalyticsService:LogCustomEvent`) |
| `70b53b9` | Stage 1 — SOP ① Run loop | ShiftService (intermission queue → seeded floor gen → active shift → complete; downed/revive; speed validation; hub return), FloorGenService + RoomKit (procedural greybox floors), CaseService (pickup/drop/carry slots, squirm, carry-speed, downed-friend looting), NoiseService (noise bus + NoiseMeter), DefectService (hearing-AI FSM: Patrol/Investigate/Chase/Attack + scripted non-aggro flyby), ExtractionService (3s dock dwell → bank cases as sealed CaseStubs + shift pay), client RunHUD/InputController/CarryController |
| `b1d85b1` | Stage 2 — SOP ② Hub + unboxing + onboarding | HubService (runtime greybox apartment: lounge, unbox stage, odds board wall, countdown wall, trade pads, shop kiosk, locker bank, shelf-room corridor, clock-in airlock), UnboxService (the ONLY roll site; server RNG; rare+ broadcast), BroadcastService, OnboardingService (no-screens scripted first shift: ClockIn → ForemanLine → FirstCase beacon → DefectFlyby → FirstExtraction → Done, 120s failsafes), client UnboxingUI (slow-peel theater) + OddsUI + OnboardingController |
| `6f8814c` | Stage 3 — SOP ③ Locker | LockerService + LockerCore (3 free opens/day, VIP 6, purchased extra-open credits, 00:00 UTC unix-day reset, clock-skew safe), CountdownUI/RotationService (toy-line rotation timer), LockerUI, LockerGlowController |
| `689e9c9` | Stage 4 — SOP ④ Swap-meet trading | TradeService + TradeFlow (confirm-twice FSM with 3s server gate, mutation resets both confirms, validate-all-then-mutate swap, no mint/burn, idempotent accept), ValueIndex (unitless scam-warning advisory only — no Robux in trade contract by construction), TradeLedger (DataStore append), TradeUI |
| `8809856` | Stage 5 — SOP ⑤ Display shelf rooms | ShelfService + ShelfRoomBuilder (per-player display rooms behind the 8 corridor doors), ShelfUI |
| `e70fb20` | Stage 6 — SOP ⑥ Monetization + compliance | MonetizationService (single ProcessReceipt owner, receiptId ring-buffer idempotency under the profile lock, pass cache, golden set cosmetic, starter-pack one-time offer triggered at 2nd extraction), ProductCatalog, ComplianceService (boot-time audit: every sellable random SKU's disclosed odds == RarityTable output element-for-element; every price == PriceLadder), ConsumableService (scent spray etc.), ShopUI/StarterPackUI/ConsumableHUD |
| `f609efb` | Monetization compliance pass | Fixed charge-for-nothing on owned Starter Pack card, server-side §4.1 no-pay-to-open-mid-run gate, truthful bundle ribbons (whale bundle = 423 cases for exact +40%) |
| `1a70a1d` / `d21ce4c` | Security hardening passes | Remote validation/rate-limit hardening; LockerCore delegation |
| `3831712` | QA: lune test suite | Headless test gate (tests/run + 4 suites); extracted pure cores TradeFlow.luau / LockerCore.luau, services delegate |

## Architecture overview

- **Loaders (frozen after Stage 0):** `src/server/init.server.luau` requires every ModuleScript under `Services/`, `Init()` alphabetical-synchronous then `Start()` spawned; client mirror for `Controllers/`. Adding a service/controller never touches the loaders.
- **Cross-service wiring:** services resolve siblings lazily via pcall-require (`getSibling`) and degrade gracefully — a missing module disables a feature, never boot.
- **Networking:** all remotes created up front by `Shared/Net/Remotes.luau` (`InitServer()` before any service Init); payloads validated server-side.
- **Persistence:** ProfileService (vendored), store `PlayerData_v1`, session-locked, kick-on-load-failure (never run on unsaved data); Studio falls back to in-memory mock profiles. Two per-player locks: serialized `Update` writes + a re-entrant `WithLock` mutex for multi-step trade/purchase sequences.
- **Single sources of truth:** RarityTable.TIER_WEIGHTS drives both `RollCryptling` and `GetOdds` (zero odds drift possible); PriceLadder drives catalog prices; ComplianceService asserts both at boot.
- **Pure-logic cores** (`src/shared/Logic/TradeFlow.luau`, `LockerCore.luau`) are Roblox-API-free so the Lune suite can test them headlessly; services delegate to them.
- **Geometry:** 100% runtime greybox Parts (hub at (-2000,0,0); shift floors seeded-procedural via FloorGen/RoomKit). No assets, no Studio edits.
- **Mobile-first:** touch-sized UI, ProximityPrompts, forgiving dock margins, no-screens onboarding.

## Critical-path traces (verified by code read)

### (a) Join → first shift → run → extraction → hub → unboxing → locker — INTACT
1. **Join:** `PlayerDataService.Start` → `loadProfile` (session lock, Reconcile, daily locker reset, d1_return funnel, TradeCollection attribute publish).
2. **Onboarding:** `OnboardingService:Start` scan detects `stats.firstShiftDone == false` + active-shift participant → scripted beats (ClockIn → ForemanLine t+3s → FirstCase t+10s with gold beacon on the guaranteed Tier-1 case nearest the dock → DefectFlyby ~t+60s after first pickup → FirstExtraction → Done sets `firstShiftDone`, points at locker with free-opens count). 120s per-beat failsafe + fast-forward on shift end; analytics `onboarding_beat` per beat.
3. **Run / case pickup (noise scales):** `CaseService.onRequestPickup` gates: shift active, alive, not downed, participant, not extracted, living holders not pickpocketable (downed-only transfer), range, carry cap. On pickup: carry-speed applied, holder loop computes `noise01 = clamp01(count × NOISE_PER_CARRIED_CASE × stateMult)` → NoiseMeter to client, and movement emits NoiseEvents (sprint ×2, scent-spray mult 0) → `NoiseService.Emit` → `DefectService` hearing FSM. Funnel step 2 `first_case_pickup`.
4. **Extraction:** `ExtractionService` 3s dock dwell → `CaseService.TakeAllCarried` → sealed CaseStubs written to `profile.locker.cases` + shift pay (5×tier + 10 bonus, ×pass multiplier) → `secondExtractionAt` stamp (starter-pack trigger) → funnel step 3 → `ShiftService.MarkExtracted` returns the player to the hub.
5. **Hub → unboxing with odds UI:** hub odds board renders `RarityTable.GetOdds(BASELINE_TIER)` at runtime; `GetOddsTable` remote returns the same function verbatim; UnboxingUI's theater sets OddsUI context per tier (odds one tap away). `UnboxService.onRequestOpenCase` gates: ownership, not in live trade offer, server-side §4.1 no-open-mid-run, busy flag → `LockerService.TryConsumeOpen` (fail-closed daily cap) → roll-before-mutate under the write lock → collection increment, rare+ broadcast, funnel step 4 `first_unboxing`; open credit REFUNDED if the uid raced away.
6. **Locker:** 3 free/day (VIP 6), purchased credits consumed only after free opens, 00:00 UTC reset — all proven by the lune `locker_opens` suite.

### (b) Purchase flow — INTACT (pending real product IDs)
`ShopUI` (odds rendered inline on every random card before any prompt; fail-closed) → `MarketplaceService` prompt → **`MonetizationService` ProcessReceipt (single owner)**: malformed/unknown receipt → NotProcessedYet; player or profile not ready → NotProcessedYet (platform retries); receiptId in ring buffer → PurchaseGranted (idempotent); §8.1 restricted player + random SKU → refused (NotProcessedYet = refund path) → `WithLock(applyReceiptLocked)`: yield-free grant (cases via `LockerService.AddCases`, extra opens, consumables, cryptlings, starter-pack flag) with the receiptId recorded in the SAME atomic Update → analytics `purchase {sku, price}` (failures fire `purchase_failed {sku, reason}`) → `ShopGrant` client toast. Game passes: `PromptGamePassPurchaseFinished` → re-verified server-side via `UserOwnsGamePassAsync` cache refresh.

## Test coverage

- **Headless (`lune run tests/run`) — 35/35 pass:** `rarity_odds` (odds sum to 1, godly 0.5%, disclosure==roll band-for-band, 200k-roll distribution, pool composition), `price_ladder` (18 SKUs verbatim vs SOP §4.2, charm endings, bundle ladder, MVP flags), `trade_fsm` (sanitize matrix, confirm-twice + 3s gate, mutation resets, idempotent accept, no mint/burn, half-failure rollback, 30-ring history, value warnings), `locker_opens` (caps, credits, UTC reset, clock skew, VIP).
- **Legacy lune checks:** `tests/rarity-sim.luau`, `tests/rotation-math.luau` (run as part of prior gates).
- **In-Studio TestEZ** (`test.project.json`, `src/server/Tests/*.spec.luau`, 7 specs): Roblox-API-bound paths — remote rate limits, ProfileService persistence, pass ownership, TradeLedger, compliance/catalog/monetization/locker/rarity/shelf/trade service integration.

## Security & compliance findings summary

- **Paid-random compliance (§8.1):** structural odds disclosure on every purchasable random flow (fail-closed: no odds payload → no prompt); `PolicyService.ArePaidRandomItemsRestricted` fetched on join, cached, FAIL-CLOSED on error, enforced at storefront, starter-pack offer, AND ProcessReceipt delivery; ComplianceService boot audit pins disclosed odds and prices to the single sources of truth.
- **No wagering vectors:** trade wire contract carries no Robux/price field by construction; ValueIndex is advisory-only.
- **Dupe prevention:** receiptId ring buffer under the profile lock; trade validate-all-then-mutate with census conservation; unbox roll-before-mutate + credit refund on race; re-entrant per-player locks prevent self-deadlock.
- **Exploit gates:** server-authoritative pickup (participant/extracted/downed/range/cap), no pay-to-open mid-run server gate, participant speed validation, hub-idler case-grief gate, downed-only case transfer.
- **Fixed during hardening:** charge-for-nothing on owned Starter Pack card; missing server-side §4.1 mid-run gate; overstated bundle ribbons (now exact).

## KNOWN GAPS / stubs

1. **All 18 product/pass assetIds are `0` placeholders** (`src/shared/Economy/ProductCatalog.luau`). Real Developer Products and Game Passes must be created in the Creator Dashboard and their IDs filled in before any purchase can complete. Until then `resolveDevProductSku`/`resolveGamePassSku` cannot match a live receipt (test seam `SetAssetIdForTest` exists). **This is the only blocker to live monetization.**
2. **SEASON_PASS / CLUB subscription / battle-pass SKUs intentionally not wired in MVP** (`grants = {}`, `wiredInMvp = false`) — per SOP §4.1 rollout roadmap (season1/week8).
3. **Greybox everything:** all geometry is runtime Parts; sounds are placeholder `rbxasset` SFX (CarryController squirm voices, unbox theater) awaiting the art/audio pass.
4. **Analytics** uses Roblox `AnalyticsService:LogCustomEvent` only — no external sink; custom-event taxonomy subject to the platform's event-type limits.
5. **DataStore-bound behavior is mock-backed in Studio without API access** (ProfileService .Mock) — nothing persists in offline Studio; TradeLedger appends and live session locks need a published place with Studio API access enabled to exercise for real.
6. **No remote git** — repo is local-only by instruction.

## How to playtest

1. **Open the build:** open `C:\Users\hudso\roblox-game\Cryptlings.rbxl` in Roblox Studio, **or** live-sync: run `rojo serve` in the repo and connect with the Rojo Studio plugin (toolchain on PATH via `$env:USERPROFILE\.rokit\bin`).
2. (Recommended) Game Settings → Security → **Enable Studio Access to API Services** so profiles persist; otherwise the in-memory mock is used (a warning prints).
3. Press **Play** (or Start a multi-client test for trading/revive/co-carry). You spawn in the greybox hub apartment at (-2000, 0, 0): lounge, unbox stage + odds board wall, countdown wall, locker bank, trade pads, shop kiosk, shelf-room corridor.
4. Walk into the **CLOCK IN** floor zone → intermission countdown → teleported onto a seeded procedural greybox factory floor. As a fresh profile, the **onboarding beats** play inside the real shift (foreman PA line, gold beacon on your first case, scripted Defect flyby, dock arrow).
5. **Grab squirming cases** (ProximityPrompt / tap). Watch the noise meter climb with carried count and sprinting — the Defect (12-stud blocky misprint, glowing eyes) investigates noise and chases on sight/repeated noise; getting downed drops your haul (a friend can revive you or carry your boxes out).
6. Stand on the **extraction dock for 3s** → cases bank to your locker + shift pay → returned to the hub.
7. At the **locker bank**, open a banked case: slow-peel unboxing theater with confetti, exact odds one tap away; rare+ pulls broadcast server-wide. 3 free opens/day (resets 00:00 UTC).
8. **Trading:** two players on the facing trade pads → confirm-twice flow with the 3s gate and lopsided-offer scam warning. **Shelf rooms:** corridor doors open per-player display rooms. **Shop/starter pack:** UI renders with full odds disclosure, but purchases cannot complete until real product IDs replace the `assetId = 0` placeholders (gap #1).

## Exact next manual steps (human)

1. Create the 15 Developer Products + 3 Game Passes in the Creator Dashboard at the SOP §4.2 prices; paste their IDs into `src/shared/Economy/ProductCatalog.luau` (replace each `assetId = 0`).
2. Publish the place from Studio; enable Studio API access; run the TestEZ specs via `test.project.json` in Studio.
3. Test a real purchase in a published test universe (ProcessReceipt only fires for real receipts).
4. Art/audio pass to replace greybox Parts and placeholder sounds.
