# Metric — APP synthetic quote leg escapes envelope + denominator validation: swaps drain the LP at a garbage price

**Finding:** the `AnchoredPriceProvider` (APP) factory envelope is keyed on
`baseFeedId` only. `quoteFeedId` is never validated — for existence, class,
or denominator — at creation or at read. A synthetic provider can therefore
quote a confident, tightly-banded, completely meaningless cross that passes
every guard, and a pool built on it executes swaps at the garbage price and
drains the LP.

**Severity: Critical** — maps exactly onto the listed Immunefi Metric
Critical impact **"Direct theft of user funds"**.

**Measured (local deploy of the exact repo code, no fork):** synthetic
provider with base BTC/USD ÷ quote ETH/BTC quotes **1,208,178 token1/token0
vs the true cross 18.57 (~65,000×)**, band width **0.042%**. A swapper pays
**41 token0 → gets 45,000,000 token1** (90% of the pool's token1, for <0.1%
of its true value). The wrong-denominator direction collapses the cross to
**0.01** and drains the other side: **450,201 token1 → 45,000,000 token0,
LP loses 85% of total true value**. Control with the correct quote leg
(ETH/USD): quote 18.56, LP loss 0%.

## Files

- `REPORT-DRAFT.md` — full Immunefi report draft (severity Critical), incl.
  the 7-question gate, the privilege caveat stated plainly, and the
  suggested fix.
- `FINDINGS.md` — verdict + measured evidence (6/6 tests).
- `test/MP11SyntheticGarbage.t.sol` — Foundry tests (6 tests).
- `test/MetricOmmPool.base.t.sol`, `test/PoolStateTestLib.sol`,
  `test/FactoryFeeCapsStub.sol`, `test/PoolInitPreprocessor.sol`,
  `test/ExtensionOrderTestLib.sol`, `test/mocks/` — the pool repo's own
  test harness, vendored verbatim.
- `contracts/` — `pool-contracts` @ `ddf8ae0`, vendored verbatim.
- `oracle-contracts/` — the AnchoredPriceProvider subset of
  `oracle-contracts` @ `7525bbd`, vendored verbatim:
  `AnchoredProviderFactory.sol`, `AnchoredPriceProvider.sol`,
  `interfaces/` (the five interfaces they use), `oracles/utils/TimeMs.sol`.
  The rest of that repo (Pyth/Chainlink/compressed oracles, MultiplierOracle)
  is unrelated to this finding and is not vendored; the full repo is pinned
  above.

## Reproduce

```
git clone https://github.com/Anyeps/metric-synthetic-quote-leg-drain-poc
cd metric-synthetic-quote-leg-drain-poc
forge install foundry-rs/forge-std@0e44f85 --no-commit
forge install OpenZeppelin/openzeppelin-contracts@dde766bd --no-commit
forge test --match-contract MP11SyntheticGarbageTest -vv
```

Expected: **6 passed, 0 failed.** No fork URL, no RPC, no mainnet state:
the bug is pure factory/provider validation logic, tested by local
deployment of the exact repo code with the repo's own harness
(`MetricOmmPoolBaseTest` + `MockPricedOracle` / `MockERC20` / `TestCaller`).
First build is slow (`via_ir` + optimizer); the suite itself runs in
<100 ms. Requires Foundry (`forge`) and solc 0.8.35 (set in `foundry.toml`).

## Mocks vs the real code

The only mock is `MockPricedOracle` (in the test file): it stands in for an
allow-listed oracle and implements exactly the two reads the APP makes
(`IPricedOracle.price(feedId, pool)` and `IOffchainOracle.priceGuard(feedId)`),
with settable mid/spread/refTime per feed. No gating — the claim under test
is validation, not oracle access control. Everything else is the real code:
real `AnchoredProviderFactory` + real `AnchoredPriceProvider` + real
`MetricOmmPoolFactory` / pool.

## Notes

- The vendored Metric code retains its original SPDX headers and
  licenses (see `licenses/`). Upstream repos:
  `pool-contracts` @ `ddf8ae0`, `oracle-contracts` @ `7525bbd`.
- Critical is 20% of funds directly affected, max $500,000, min $50,000
  (program page). The High / Medium / Low dollar tiers were not visible on
  the Metric program page at research time (rendered as SVG); the draft
  claims the listed impact, not a dollar figure beyond the Critical band.
- Metric program: https://immunefi.com/bug-bounty/metric/information/
  (KYC not required; PoC required; no mainnet testing).

## Status

Report draft prepared 2026-11-15. **NOT submitted** — submission is
blocked by the Immunefi Novice 100-credit fee; waiting for the Studio
wave verdict (same as the GMX drafts and the Metric M-P1-3 draft).
