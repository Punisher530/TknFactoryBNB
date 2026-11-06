# BNB Launchpad v1.4: graduation unavailability experiment

> **SECURITY GATE FAILED: DO NOT MERGE.** A one-wei token sale can reopen a completed curve and invalidate a queued permissionless graduation transaction. The branch is retained for analysis only. The proposed split migration is **not an approved fix**.

## Additional confirmed model finding: one-wei sale griefing

For an initial 0.25 BNB virtual reserve, immediately after the finishing buy the curve has zero remaining tokens and roughly 0.75 BNB in real reserves. An existing token holder can sell **one token wei** (10^-18 token), receive **one wei of BNB credit**, and increase `curveTokensRemaining` to one. The separately submitted `graduate()` then fails `NotReadyForGraduation`. A two-wei BNB repurchase can restore exhausted status. This can be repeated, paying network gas and trivial trading amounts. The demonstrated behavior is model-based, not a measured mainnet MEV exploit. The test is `tests/test_migration_sell_race.py`.

This makes a permissionless grad transaction vulnerable to transaction-ordering and persistent griefing even if PancakeSwap V2 is functioning. It recreates an availability risk that v1.4's atomic graduation specifically avoided. Therefore the present candidate **must not be merged**. Any improved candidate must retain an effective anti-griefing mechanism while also providing exit/recovery on an unavailable DEX, and requires real EVM fork tests.


**Branch:** `fix/graduation-unavailability-prototype`  
**Base:** `main` (`6b6b9dd314f90f6e0375cc9f475b1af08b60e61a`)  
**Status:** EXPERIMENTAL. DO NOT MERGE OR DEPLOY.

## Problem
Original v1.4 calls `_graduateAtomic()` from the finishing buy. Failure in factory/pair creation, WBNB wrapping, minting, pair state validation, or gas exhaustion reverts the entire finishing purchase. No independent graduation/recovery entry point exists.

## Isolated candidate
1. `buy()`/`createTokenAndBuy()` still price, transfer, fee-account and credit exactly as before. When the curve reaches zero inventory they emit `GraduationReady(token, nativeReserve)` and return **without calling PancakeSwap**.
2. `graduate(token)` is permissionless and guarded by the existing `onlyBSC` and `nonReentrant` modifiers. It calls the same internal `_graduateAtomic()` function used in v1.4, requiring zero remaining curve supply; minted LP still goes to the immutable burn address.
3. On migration revert, **only** the `graduate()` transaction fails. Token holders can still use existing `sell()` to receive BNB credits, since the market is not graduated. A sell increases `curveTokensRemaining`, reopening ordinary buying and invalidating any pending graduation attempt.
4. An already-graduated market rejects future curve buys, sells and graduations as before.

## Key tradeoffs and failure analysis

| Scenario | Result | New tradeoff |
|---|---|---|
| PancakeSwap factory/pair reverts | Finishing buy succeeds; migration can be retried | Pool may remain uncreated indefinitely |
| Migration succeeds | Atomic wrapping, minting, verification and LP burn as v1.4 | Separate caller pays gas |
| Holders sell before migration | Curve reopens; users receive native credits | **Front-running sells can prevent graduation** |
| No keeper funds / no volunteer | Curve remains exhausted, no DEX trading | **Permissionless does not guarantee execution** |
| BNB donations into pair | Existing price effects/price preview remain | No new price-integrity protection |
| Market waiting for migration | Transfer lock remains until successful migration; holders can sell to the curve | Holding/DEX liquidity may be delayed; indexer must query current state |
| Malicious sale/micro-buy loops | Can repeatedly invalidate a pending `graduate()` | **Economic liveness griefing possible** |
| DEX inaccessible forever | Sellers can redeem through the curve, including after full sellout | Relies on holders proactively selling; not an automatic refund |

## Not implemented on purpose
No 1% dust rule, keeper bounty, platform fee diversion, 48-hour deadline, locked READY phase, unrestricted owner bypass, fallback DEX or emergency withdrawal. These could affect other security invariants and need separate reviews.

## Frontend integration requirements
- A zero `curveTokensRemaining` and `graduated == false` is an **exhausted / awaiting migration** condition, NOT a successful graduation.
- `GraduationReady` events can become stale after a sell; always read current market state.
- Show 'Graduate' to any account only when remaining is zero. A retry must check current state. No one is guaranteed an incentive to pay gas.
- Purchases while exhausted revert until a sell reopens the curve. Users can continue selling before graduation and claim BNB credits.
- Use an updated ABI containing `graduate(address)` and `GraduationReady`.
- Inform holders that **the launch might never reach PancakeSwap** even if the final purchase succeeds.

## Tests and release gates
Local source guards and an exact-integer off-chain model passed on 1000 randomized markets: 30,180 modeled buys, 18,877 sells, 5,430 failed graduation attempts, and 836 successful graduations. These are NOT on-chain or EVM tests.

Before merging, run actual Solidity 0.8.38 compilation and a BSC chain-ID-56 fork with canonical PancakeSwap contracts covering: successful grad, pair creation failure, pair with WBNB donated/synced, after-sell failure, transaction-order race, last-wei rounding, gas costs, refund solvency, and failed `graduate()` revert isolation. Simulate a low-cost adversarial sell/rebuy loop to quantify denial-of-service cost. Reevaluate design if repeated front-run sells prove cheap or keeper reward cannot be funded.

## Decision
This prototype **solves the final-buy revert coupling** at the expense of **delayed migration with a potentially cheap sell-griefing attack**. It is not an unqualified security improvement. Do not merge to `main` without a clear acceptance of this tradeoff and EVM testing.
