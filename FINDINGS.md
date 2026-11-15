# M-P1-1 — APP synthetic quote leg escapes envelope + denominator validation

**Verdict: FOUND** — fork test DONE 2026-11-15 ~13:40 WIB, **6/6 tests pass**.

## Claim tested

The factory envelope for an `AnchoredPriceProvider` in synthetic mode is keyed
on `baseFeedId` only; `quoteFeedId` is never validated for existence, class, or
denominator. A synthetic provider can therefore quote a confident, tightly-banded,
meaningless cross that passes every guard — and a pool can be created on it, after
which swaps execute at the garbage price and drain the LP.

## Environment

- Local deploy (no mainnet, no fork of live state). Foundry (repo toolchain).
- `pool-contracts` @ `ddf8ae0`, `oracle-contracts` @ `7525bbd` (clones in
  `~/workspace/hunts/metric/repos/`).
- Real `MetricOmmPoolFactory` + real `AnchoredPriceProvider` (via the real
  `AnchoredProviderFactory`), real `CompressedOracle`-style mock:
  `MockPricedOracle` (settable mid/spread/refTime per feed; `priceGuard`
  returns (0, 0)) in `work/pool-contracts/test/MP11SyntheticGarbage.t.sol`.
- Envelope: DEFAULT_CLASS, minMargin 1e11–1e15, staleness 0–60 s, spreadMultMax
  2e18; provider minMargin 1e13, maxRefStaleness 60, maxSpreadMult 2e18,
  immutable, marginStep 0. LP 10M shares, bins −5..4 (50,000,000 / 50,000,000
  base units deposited).
- Feeds (8-decimal mids): BTC/USD 6.5e12, ETH/BTC 5.38e6, ETH/USD 3.5e11,
  BTC/USD-in-cents 6.5e14, spread 100 (1 bp).
- True BTC/ETH cross: 65,000 / 3,500 = **18.571428** token1 per token0.

## Results (6/6 pass)

| # | Test | Result |
|---|------|--------|
| 1 | `test_1_factoryAcceptsGarbageSynthetic` | PASS — factory creates the garbage synthetic AND a quote leg with **no data at all** (`NOPE` feed id). |
| 2 | `test_2_garbageQuoteConfidentTight` | PASS — `getQuote()` ref = 22,286,958,453,366,558,643,866,171 (Q64) = **exactly** the expected garbage mid (BTC/USD ÷ ETH/BTC = **1,208,178** token1/token0, ~65,000x the true 18.57). Band width 420,185,840,554,278 on the 1e18 scale = **0.042%** — tightly banded, fully confident. (The no-data leg from test 1 reverts `FeedStalled` at read — fail-closed at read, not at creation.) |
| 3 | `test_3_poolAcceptsGarbageProvider` | PASS — `createPool` with the garbage provider succeeds; pool registered. |
| 4 | `test_4_swapAtGarbagePrice_drainsLP` | PASS — attacker exact-outs 90% of the pool's token1: **paid 41 token0, got 45,000,000 token1**, effective rate 1,097,560,975,609 E6 ≈ **1.1e6 token1 per token0** (>1,000x the true cross). Attacker paid **<0.1%** of the extracted true value. LP exits recovering only **5,000,000 / 50,000,000 token1** (loses 90% of its token1 deposit). Total position-value loss 4% — see the metric note below. |
| 5 | `test_5_control_correctCross` | PASS — correct quote leg (ETH/USD): ref ≈ 18.57, swap effective rate 18,563,322 E6 ≈ 18.56, **LP loss 0%**. The drain is caused by the garbage leg, not the harness. |
| 6 | `test_6_wrongDenominator_drainsToken0Side` | PASS — wrong-denominator quote leg (BTC/USD expressed in **cents**, mid 100x too large): cross collapses to **0.01** token1 per token0 vs true 18.57. Attacker exact-outs 90% of the pool's token0: **got 45,000,000 token0, paid 450,201 token1**, effective rate 99,955,353 E6 ≈ **100 token0 per token1** (true 0.0538 — ~1,857x). Attacker paid <1% of extracted true value. **LP loses 85% of total true value**; recovers 5,000,000 / 50,000,000 token0. |

## Why the loss metric differs between test 4 and test 6

The harness deposit is 50M/50M raw. At the true cross the token0 side is worth
~19x the token1 side, so draining the whole token1 side (test 4) is only ~5% of
total position value — the honest impact measure there is the drainable side
itself (90% of the pool's token1 extracted for ~0.008% of its true value).
The garbage cross can be wrong in **either direction** depending on the quote
leg: overpriced token0 → token1 side is stealable (test 4); underpriced token0
→ token0 side is stealable (test 6, 85% of position value). The mispricing
direction is the curator's choice; the protocol validates neither.

## Root cause (verified in code, not just in test)

- `oracle-contracts/contracts/AnchoredProviderFactory.sol` — the envelope is
  keyed on `baseFeedId` only.
- `oracle-contracts/contracts/AnchoredPriceProvider.sol` — no semantic-match
  check between the legs; the code documents it: *"there is no on-chain
  backstop"*.
- `pool-contracts/contracts/MetricOmmPoolFactory.sol:_validatePriceProvider`
  (717–722) — checks only non-zero address + `token0()`/`token1()` match;
  never factory deployment, never feeds.

## Severity + listed-impact fit

- **Critical — honest central case.** Listed Metric Critical impact: *"direct
  theft of user funds"*. The drain direction decides which side is stolen; the
  underpriced direction steals the majority-value side (85% of position value
  measured). This is the second Metric finding that maps onto a listed impact
  exactly (after M-P1-3's "permanent freezing of funds").
- **Honest caveats (triage risks):**
  - The provider is chosen by the pool's creator/curator, so the live shape is
    a **malicious curator** or an **honest curator's opaque-feed-id mistake**
    (feed ids are raw bytes32 with no human-readable check). Triage may call
    curator choice by-design.
  - The mechanism is **documented in code** ("there is no on-chain backstop"),
    which triage may read as intended behaviour.
  - The no-data quote leg is **fail-closed at read** (`FeedStalled`) — only a
    wrong-but-live leg quotes. The exploit needs a live wrong feed, not a
    missing one.
  - Victim is the pool's LPs (and any swapper who trusts the pool price); the
    attacker is the curator or anyone who swaps against the mispriced pool.
- **Known-issue check:** no known-issue document names the synthetic quote-leg
  gap (searched the Known_issues corpus for synthetic / quoteFeed /
  AnchoredPrice — no hits). It differs from known Sept M-8 (stop-loss **false
  negative** — a check missing a drawdown) and from the known oracle-shock
  cycle drain (that one needs a real oracle shock; this one needs no shock at
  all — the quote is wrong from creation).
- **What this is NOT:** not a missing-feed bug (a missing feed halts), not a
  staleness bug (staleness binds), not an oracle-manipulation bug (the feeds
  are honest and fresh — the ratio itself is meaningless).

## Files

- `work/pool-contracts/test/MP11SyntheticGarbage.t.sol` — the 6-test suite
  (scratch copy of `pool-contracts` @ `ddf8ae0` with remapping
  `oracle-contracts/` → `~/workspace/hunts/metric/repos/oracle-contracts/contracts/`).
- `README.md` — how to run.

## Status

FOUND, verified, **not submitted, no report draft written** (per task scope).
A report draft + public PoC repo are the next step if this is chosen for the
Studio wave.
