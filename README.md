# Cryptlings

A co-op extraction-horror and blind-box trading game for Roblox, built through a multi-agent development pipeline over a Roblox Studio toolchain. This repository is the source and the test harness; the place files, art, and operational tooling are kept out (see below).

How it was built is as much the point as the game itself. I defined the architecture, the specification of record, the interface contracts between modules, the task boundaries, and the acceptance criteria; coding agents implemented scoped components against those constraints. Every economy-critical path is guarded by a headless test gate, and changes that failed it were not integrated.

## What is in here

About 57,000 lines of Luau across 109 modules, split into three trust zones:

- `src/server/` (server-authoritative services): procedural floor generation, a monster hearing-and-search state machine, the trading system, the locker economy, unboxing, and monetization with compliance checks at boot.
- `src/client/` (controllers): input, camera, HUD, the onboarding flow, and the trade UI.
- `src/shared/` (`Economy/`, `Config/`, `Logic/`, `Net/`): the single sources of truth both sides agree on, including the rarity tables, price ladder, and the remote-event schema.

## The test gate

`tests/` is a headless Lune suite that runs without Roblox, so generated changes could be run through the gate before integration. It covers the parts where a bug costs real money or breaks trust:

- `suites/rarity_odds.luau` plus `rarity-sim.luau`: the gacha odds tables, checked against a 200,000-roll Monte Carlo distribution.
- `suites/price_ladder.luau`: the full product price ladder.
- `suites/trade_fsm.luau`: a confirm-twice trade state machine with atomic, no-dupe swaps.
- `suites/locker_opens.luau`, `respawn_timer.luau`, `rotation-math.luau`, and more.

Run them with `lune run tests/run.luau`. Roblox-API-bound paths have TestEZ specs under `tests/roblox/`.

## Anti-exploit and compliance

The economy is written to survive hostile clients: single-owner receipt processing with idempotency, validate-all-then-mutate trade swaps with conservation checks, roll-before-mutate unboxing that refunds on a race, and fail-closed under-18 gating for paid-random items through Roblox `PolicyService`.

## Toolchain

Managed by [Rokit](https://github.com/rojo-rbx/rokit): Rojo (filesystem to Studio sync), Wally (packages), Selene (lint), StyLua (format), Lune (headless tests). Run `rojo serve` to sync `src/` into Studio.

## What is not in here, by design

- Roblox place files (`.rbxl`), backups, and rendered art.
- The account and place management scripts, which read local auth tokens and have no general value.
- Live product IDs and any operational or marketing material.

## License

MIT. See [LICENSE](LICENSE).
