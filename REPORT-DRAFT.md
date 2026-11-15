# DRAFT — Metric Immunefi Report: APP synthetic quote leg escapes envelope + denominator validation — swaps drain the LP at a garbage price

**Status: DRAFT — submission-ready, NOT submitted.**
**Reason not submitted:** Immunefi Novice submission fee (100 credits, ~100 USDC).
Fah's account holds ~0 USDC; waiting for the Immunefi Studio wave, same as
the two GMX drafts and the Metric M-P1-3 draft. Do NOT submit until the
Studio "Ready" verdict, and do NOT pay any fee from another source without
Fah's explicit approval.

- **Program:** Metric — https://immunefi.com/bug-bounty/metric/information/
- **Severity: Critical** — maps exactly onto the listed Metric Critical
  impact **"Direct theft of user funds"**. Critical = 20% of funds directly
  affected, max $500,000, min $50,000.
- **Payout wallet:** `0x45859319d9a362f2146d0431dc30ab8f0ef1be73`
- **PoC repo:** https://github.com/Anyeps/metric-synthetic-quote-leg-drain-poc
  — verified from a fresh clone at commit `d6e59ffd40ed6d4be91c6f8479d14674ba243905`: `forge install`
  (pinned deps) + `forge test` → **6 passed, 0 failed**.
- **Code under test:** `pool-contracts` @ `ddf8ae0`, `oracle-contracts` @
  `7525bbd` (exact repo code, local deploy, no fork — see below).

---

# Part 1 — 7-Question Gate (run before writing the report)

## Q1: Can an attacker use this RIGHT NOW, step by step? — PASS (with the honest caveat, disclosed)

Yes — in two shapes, both measured:

**Shape A — the curator is the attacker.** Pool creation is permissionless
(`MetricOmmPoolFactory.createPool` is `external`, no access control —
`MetricOmmPoolFactory.sol:205`). Anyone can:

1. Deploy an `AnchoredPriceProvider` in synthetic mode with a garbage
   quote leg — e.g. base BTC/USD ÷ quote ETH/BTC — through the real
   `AnchoredProviderFactory.createAnchoredProvider`. The factory accepts
   it: the envelope is keyed on `baseFeedId` only and `quoteFeedId` is
   never validated (see Vulnerability details).
2. `createPool` with that provider. The pool factory's
   `_validatePriceProvider` checks only non-zero address + `token0()` /
   `token1()` match — it never checks the provider's feeds.
3. Wait for LPs to deposit (the pool looks normal: tight band, confident
   quote), then swap against it at the garbage price and drain the LP.

**Shape B — the swapper is the attacker.** Once a pool with a garbage
provider exists — created maliciously (shape A) or by an honest curator's
feed-id typo — ANY swapper can drain it with a single ordinary swap. No
privilege, no oracle manipulation, no stale/fabricated price, no timing
window. The drain is a normal `swap` at the pool's own quoted price.

The theft itself needs no privilege at all. The only privileged step is
choosing the provider, and that role is either permissionless (any pool
creator) or already held by the pool's curator. The caveat — that the
live shape needs a malicious curator or a curator typo — is real and is
stated in the report itself (see "A note on privilege" in Part 2).

## Q2: Is the impact on the program's accepted impact list? — PASS (exact)

Yes — verbatim. The Metric scope page lists under **Critical**:

> **Direct theft of user funds**

This finding is that impact, measured in both directions (Part 2,
Evidence):

- Overpriced-token0 direction: attacker pays **41 token0** and extracts
  **45,000,000 token1 — 90% of the pool's token1** — for <0.1% of its
  true value.
- Underpriced-token0 direction: attacker pays **450,201 token1** and
  extracts **45,000,000 token0**; **the LP loses 85% of the position's
  total true value**.

85% of position value stolen in a single swap is far above the Critical
band's 20%-of-funds threshold. This is the second of our findings that
maps onto a listed impact exactly (after M-P1-3's "permanent freezing of
funds"), and the first that maps onto a Critical impact.

## Q3: Is the root cause in an in-scope asset? — PASS

Yes, two in-scope repos:

- `oracle-contracts` — `AnchoredProviderFactory.createAnchoredProvider`
  (envelope keyed on `baseFeedId` only) and
  `AnchoredPriceProvider._getQuote` / `_readLeg` (no denominator check;
  the code documents the gap).
- `pool-contracts` — `MetricOmmPoolFactory._validatePriceProvider`
  (`:717-722`), which checks only non-zero + token match and never the
  provider's feeds — at pool creation (`:525`) and at provider rotation
  (`:544`).

Both repos are listed as bounty-eligible scope on the program page
("Oracle and Price Provider Contracts" and "Pool Contracts").

## Q4: Does it require privileged access that an attacker can't realistically get? — PASS (with the honest caveat, disclosed)

The drain (shape B) needs no privilege: any swapper. The setup (shape A)
needs pool-creator rights, which are permissionless, or a curator's
feed-id typo, which is a realistic operational mistake: feed ids are raw
`bytes32` values with no human-readable check anywhere in the creation
flow, and the factory's own documentation says the base feed "is NOT
validated against the oracle at creation". It does NOT need a compromised
admin, oracle, factory owner, or pusher. The honest primary scenarios are
a malicious pool creator (permissionless) or a typo'd feed id (opaque
bytes32). Both are disclosed in the report.

## Q5: Is this already known or accepted behavior? — PASS

No. Checked against:

- The published known-issues repo (`Metricxyz/Known_issues`) — searched
  for synthetic / quoteFeed / AnchoredPrice: no hits. No known-issue
  document names the synthetic quote-leg gap.
- The Sherlock Sept 2026 contest findings: the closest relative is M-8
  (stop-loss **false negative** — a check missing a real 10% drawdown).
  This is the opposite direction (a **false positive** — a confident
  quote for a meaningless ratio) with a different root cause.
- The known oracle-shock + two-leg cycle drain: that one needs a real
  oracle shock to rescale bin bounds; this one needs no shock at all —
  the quote is wrong from the moment of creation, on fresh, honest feeds.

One honest flag: the gap is **documented in code**. `AnchoredPriceProvider`
says the quote currencies cancelling "is an ASSUMPTION, enforced nowhere
on-chain" and "there is no on-chain backstop for getting it wrong". That
is a triage risk (see Part 2, "A note on privilege"), not a known-issue
exclusion: no audit, contest, or known-issues document lists this as an
accepted finding, and the documentation frames it as the deployer's
responsibility — while the factory, which is the only checkpoint that
could have enforced it, performs no check at all.

## Q6: Can you prove impact beyond "technically possible"? — PASS

Measured, not hypothetical (Part 2, Evidence): 6/6 tests, both drain
directions, plus a clean control (correct quote leg: quote 18.56, LP loss
0%). The drain is caused by the garbage leg, not the harness. The
attacker pays <0.1% (direction A) / <1% (direction B) of the extracted
true value — the theft is nearly free.

## Q7: Is this a known-invalid bug class? — PASS

No. It is not a duplicate of a known issue, not a griefing-only finding
(85% of position value is stolen, not delayed or haircut), not a
front-running/MEV observation, and not a finding that requires
out-of-scope behaviour. It is a validation gap in in-scope code with a
listed Critical impact.

## Gate result: PASS (7/7)

---

# Part 2 — Report (Immunefi submission draft)

## Title

APP synthetic quote leg escapes envelope + denominator validation: swaps
execute at a garbage price and drain the LP (direct theft of user funds)

## Severity: Critical

Maps exactly onto the listed Metric Critical impact **"Direct theft of
user funds"**. Critical = 20% of funds directly affected, max $500,000,
min $50,000. Measured theft: 85% of the LP position's total true value in
a single swap (underpriced direction); 90% of one side's tokens
(overpriced direction).

**A note on the dollar tier:** the High / Medium / Low dollar tiers were
NOT visible in the program-page text fetch (rendered as SVG images), so
this draft claims only the Critical band as written on the program page
(20% / max $500,000 / min $50,000). Re-check the live program page for
the full tier table before submitting.

## Summary

The `AnchoredPriceProvider` (APP) factory envelope is keyed on
`baseFeedId` only. `quoteFeedId` — the denominator of a synthetic ratio
quote — is never validated for existence, class, or denominator, at
creation or at read. A synthetic provider can therefore quote a
confident, tightly-banded, completely meaningless cross that passes every
guard, and a pool built on it executes swaps at the garbage price.

Concretely: an APP with base BTC/USD ÷ quote ETH/BTC quotes **1,208,178
token1 per token0** against the true BTC/ETH cross of **18.57 (~65,000×
wrong)**, with a band width of **0.042%** — fully confident, fully wrong.
A swapper pays **41 token0** and extracts **45,000,000 token1 (90% of
the pool's token1)**. In the other mispricing direction the cross
collapses to **0.01** and the swapper pays **450,201 token1** for
**45,000,000 token0 — the LP loses 85% of its position's total true
value**. The pool factory's provider check (`_validatePriceProvider`)
looks only at non-zero address + token match, so it accepts the garbage
provider at creation and again at provider rotation.

Pool creation is permissionless, so a malicious creator can deploy such a
pool alone; an honest curator can create one by mistyping a feed id
(feed ids are raw `bytes32`, with no human-readable check). Once the pool
exists, any swapper can drain it with an ordinary swap — no privilege, no
oracle manipulation, no shock required.

## Impact

- **Direct theft of user funds (listed Critical impact).** Measured in
  both directions on a real factory-deployed pool with the real APP:
  - Direction A (token0 overpriced): attacker exact-outs 90% of the
    pool's token1 — paid 41 token0, got 45,000,000 token1, effective
    rate ~1.1e6 token1 per token0 (>1,000× the true cross). Attacker
    paid **<0.1%** of the extracted true value. LP exits recovering
    only 5,000,000 / 50,000,000 token1.
  - Direction B (token0 underpriced, wrong denominator): attacker
    exact-outs 90% of the pool's token0 — got 45,000,000 token0, paid
    450,201 token1, effective rate ~100 token0 per token1 (true
    0.0538, ~1,857×). Attacker paid **<1%** of the extracted true
    value. **LP loses 85% of total true value** (position true value
    978,571,400 → 143,307,341 in token1 terms); recovers only
    5,000,000 / 50,000,000 token0.
- **The theft is nearly free and repeatable.** The attacker pays a
  fraction of a percent of what they extract, and the mispricing is
  structural — it persists until someone fixes the provider, so the
  pool can be drained side by side, direction by direction.
- **Victims are the pool's LPs** (and any swapper who trusts the pool
  price). The mispricing direction is the curator's choice; the
  protocol validates neither direction, so whichever side holds the
  majority of the position's true value can be the one stolen.
- **Blast radius is one pool per bad provider, but the loss inside it
  is up to 85%+.** Any pool created on a garbage synthetic provider is
  affected; correctly-configured pools are unaffected. The loss scales
  with whatever LPs deposit before anyone notices the price is
  meaningless — and nothing at creation signals that it is: the quote
  is tight, confident, and passes every guard.

### A note on the loss metric (for triage — please read)

The two directions report different total-value losses (4% vs 85%)
because the harness deposit is 50M/50M raw units, so at the true cross
the token0 side is worth ~19× the token1 side. Draining the whole
token1 side (direction A) is therefore only ~5% of total position value
— the honest impact measure there is the drainable side itself (90% of
the pool's token1 extracted for <0.1% of its true value — asserted by
the test; the measured payment was 41 token0 for 45,000,000 token1).
Direction B proves the majority-value side is equally drainable (85%). The garbage
cross can be wrong in either direction depending on the quote leg; the
protocol validates neither.

### A note on privilege (for triage — please read)

The trigger needs a pool creator who deploys a garbage synthetic provider
— maliciously, or by mistyping a feed id. The pool curator is
semi-trusted, and we disclose this plainly rather than hiding it. Three
points in favour of Critical despite that:

1. **Pool creation is permissionless.** No allowlist, no role, no review
   stands between a malicious creator and a pool whose price is garbage
   from birth. The resulting pool is indistinguishable from a legitimate
   one until someone checks the cross by hand.
2. **The typo case is realistic.** Feed ids are opaque raw `bytes32`
   values; the factory performs no existence, class, or denominator
   check on the quote leg, and nothing at creation warns the creator.
   The factory is the natural and only checkpoint that could have
   caught this — and it explicitly documents that it does not.
3. **Once the pool exists, the theft needs nothing at all.** Any
   swapper, with no privilege and no oracle interaction, drains it with
   an ordinary swap at the pool's own quoted price. The privileged step
   is only the setup; the theft itself is permissionless.

## Vulnerability details

### The validation gap — three checkpoints, none of them check

**1. `AnchoredProviderFactory.createAnchoredProvider`
(`contracts/AnchoredProviderFactory.sol:187`) — envelope keyed on
`baseFeedId` only.**

The function checks the oracle against the allow-list, then selects the
envelope from the base feed's class (`:203` —
`bytes32 classId = feedClass[baseFeedId]`, falling back to
`DEFAULT_CLASS`) and validates `minMargin` / `maxRefStaleness` /
`maxSpreadMult` against that envelope (`:207-211`). `quoteFeedId` is
never used for the envelope, the class, or any existence check. The
NatSpec says so outright:

- `:149-155` — "baseFeedId is NOT validated against the oracle at
  creation (the constructor never reads it): a feed with no data halts
  provider reads until its first update lands".
- `:171` — "The envelope is keyed on `baseFeedId` (the provider's
  class); the quote feed contributes its mid, as the ratio's
  denominator, and its uncertainty, and is **not validated for
  existence at construction** (reads halt until it has data)."

So a quote leg with no data at all (a never-published feed id) is
accepted at creation — and a quote leg with live but wrong data is
accepted identically.

**2. `AnchoredPriceProvider` — the denominator is an assumption, not a
check (`contracts/AnchoredPriceProvider.sol:431-442`).**

When `quoteFeedId` is set, the quote is computed as a ratio:
`midNum = mid` (base leg), `midDen = mid2` (quote leg, `:442`), after
`_readLeg(_quote, quoteMaxStaleness)` (`:431`). The code comment at
`:435-441` states the gap in plain language:

> The quote currencies cancelling is an ASSUMPTION, enforced nowhere
> on-chain. Nothing here, in the factory (whose envelope is keyed on
> baseFeedId alone), or in the pool checks that the two legs share a
> denominator — so a misconfigured pair such as BTC/USD ÷ ETH/BTC
> produces a confident, tightly-banded, completely meaningless cross
> that passes every guard in this contract. Choosing two legs that
> actually share a quote currency is the deployer's responsibility and
> part of the LP's diligence before depositing; there is no on-chain
> backstop for getting it wrong.

The band is then built from the two legs' spreads (`spreadBps +=
spreadBps2`), so a garbage ratio still gets a tight, confident band —
in the PoC, 0.042% wide around a price that is 65,000× wrong.

**3. `MetricOmmPoolFactory._validatePriceProvider`
(`pool-contracts/contracts/MetricOmmPoolFactory.sol:717-722`) — token
match only.**

```solidity
function _validatePriceProvider(address token0, address token1, address priceProvider) internal view {
    if (priceProvider == address(0)) revert InvalidPriceProvider();
    if (IPriceProvider(priceProvider).token0() != token0 || IPriceProvider(priceProvider).token1() != token1) {
      revert PriceProviderTokenMismatch();
    }
}
```

That is the whole check — called at pool creation (`:525`) and at
provider rotation (`:544`). It never asks whether the provider is
factory-deployed, never asks which oracle or feeds it uses, and never
asks whether a synthetic provider's legs share a denominator. A garbage
provider passes it exactly as a correct one does.

### What is NOT the bug (checked, not assumed)

- **Not a missing-feed bug.** A quote leg with no data halts reads
  (`FeedStalled`) — tested (test 1). The exploit needs a wrong-but-live
  leg, not a missing one.
- **Not a staleness bug.** Staleness bounds bind; the feeds in the PoC
  are fresh, with 1 bp spreads.
- **Not an oracle-manipulation bug.** The feeds are honest and fresh —
  BTC/USD, ETH/BTC, ETH/USD are all real, correctly-published values.
  The ratio itself is meaningless; no feed is wrong.
- **Not the known oracle-shock drain.** That needs a real oracle shock
  to rescale bin bounds; this needs no shock — the quote is wrong from
  creation.
- **Not Sept M-8.** M-8 is a stop-loss **false negative** (a check
  missing a real drawdown). This is the opposite: a **false positive** —
  a confident quote for a meaningless ratio — with a different root
  cause in a different contract.

### Code paths (repo `oracle-contracts` @ `7525bbd`, `pool-contracts` @ `ddf8ae0`)

- `oracle-contracts/contracts/AnchoredProviderFactory.sol:187` —
  `createAnchoredProvider`; `:149-155, :171` NatSpec documenting the
  gap; `:203` class from `baseFeedId` only; `:207-211` envelope checks.
- `oracle-contracts/contracts/AnchoredPriceProvider.sol:431-442` —
  `_readLeg` of the quote leg, the assumption comment, `midDen = mid2`.
- `pool-contracts/contracts/MetricOmmPoolFactory.sol:717-722` —
  `_validatePriceProvider`; `:525` creation call; `:544` rotation call.
- `pool-contracts/contracts/MetricOmmPoolFactory.sol:205` —
  `createPool`, permissionless.

### Why this is not a known issue

Checked against the published known-issues repo and the Zellic (Jun +
Oct 2026) and Sherlock (Jul / Sep / Oct 2026) audit findings: no
finding covers synthetic quote-leg validation, denominator matching, or
quote-feed envelope checks. The Known_issues corpus was searched for
synthetic / quoteFeed / AnchoredPrice — no hits. The factory's own
documentation frames leg-matching as the deployer's responsibility, but
no document lists a garbage synthetic provider draining an LP as accepted
behaviour — and the factory is the only on-chain checkpoint that could
have enforced it.

## Steps to reproduce

### 1. Clone the PoC and run the tests

```bash
git clone https://github.com/Anyeps/metric-synthetic-quote-leg-drain-poc
cd metric-synthetic-quote-leg-drain-poc
forge install foundry-rs/forge-std@0e44f85 --no-commit
forge install OpenZeppelin/openzeppelin-contracts@dde766bd --no-commit
forge test --match-contract MP11SyntheticGarbageTest -vv
```

Expected: **6 passed, 0 failed.** No fork URL, no RPC, no mainnet state:
the bug is pure factory/provider validation logic, tested by local
deployment of the exact repo code with the repo's own harness
(`MetricOmmPoolBaseTest` + `MockPricedOracle` / `MockERC20` /
`TestCaller`). First build is slow (`via_ir` + optimizer); the suite
itself runs in <100 ms.

### 2. What the tests show

`test/MP11SyntheticGarbage.t.sol` (`MP11SyntheticGarbageTest`), all on a
real factory-deployed pool (10M shares, bins −5..4, 50,000,000 /
50,000,000 base units deposited) with the real `AnchoredProviderFactory`
+ real `AnchoredPriceProvider`, feeds at 8-decimal mids (BTC/USD 6.5e12,
ETH/BTC 5.38e6, ETH/USD 3.5e11, BTC/USD-in-cents 6.5e14, spread 100 =
1 bp). True BTC/ETH cross: 65,000 / 3,500 = **18.571428** token1 per
token0.

1. `test_1_factoryAcceptsGarbageSynthetic` — factory creates the garbage
   synthetic (base BTC/USD ÷ quote ETH/BTC) AND a quote leg with **no
   data at all** (`NOPE` feed id). No error at creation.
2. `test_2_garbageQuoteConfidentTight` — `getQuote()` ref =
   22,286,958,453,366,558,643,866,171 (Q64) = **exactly** the expected
   garbage mid (BTC/USD ÷ ETH/BTC = **1,208,178** token1/token0,
   ~65,000× the true 18.57). Band width 420,185,840,554,278 on the 1e18
   scale = **0.042%** — tightly banded, fully confident. (The no-data
   leg from test 1 reverts `FeedStalled` at read — fail-closed at read,
   not at creation.)
3. `test_3_poolAcceptsGarbageProvider` — `createPool` with the garbage
   provider succeeds; the pool is registered.
4. `test_4_swapAtGarbagePrice_drainsLP` — attacker exact-outs 90% of
   the pool's token1: **paid 41 token0, got 45,000,000 token1**,
   effective rate 1,097,560,975,609 E6 ≈ **1.1e6 token1 per token0**
   (>1,000× the true cross). Attacker paid **<0.1%** of the extracted
   true value. LP exits recovering only **5,000,000 / 50,000,000
   token1** (loses 90% of its token1 deposit). Total position-value
   loss 4% — see the metric note in Impact.
5. `test_5_control_correctCross` — correct quote leg (ETH/USD): ref ≈
   18.57, swap effective rate 18,563,322 E6 ≈ 18.56, **LP loss 0%**.
   The drain is caused by the garbage leg, not the harness.
6. `test_6_wrongDenominator_drainsToken0Side` — wrong-denominator quote
   leg (BTC/USD expressed in **cents**, mid 100× too large): cross
   collapses to **0.01** token1 per token0 vs true 18.57. Attacker
   exact-outs 90% of the pool's token0: **got 45,000,000 token0, paid
   450,201 token1**, effective rate 99,955,353 E6 ≈ **100 token0 per
   token1** (true 0.0538 — ~1,857×). Attacker paid <1% of extracted
   true value. **LP loses 85% of total true value**; recovers
   5,000,000 / 50,000,000 token0.

The only mock is `MockPricedOracle` (in the test file): it stands in for
an allow-listed oracle and implements exactly the two reads the APP
makes (`IPricedOracle.price(feedId, pool)` and
`IOffchainOracle.priceGuard(feedId)`), with settable mid/spread/refTime
per feed. No gating — the claim under test is validation, not oracle
access control.

### 3. Minimal manual repro (no test file needed)

1. Deploy `AnchoredProviderFactory` with an allow-listed oracle (or use
   the repo harness with `MockPricedOracle`).
2. `createAnchoredProvider(oracle, baseFeedId=BTC/USD, quoteFeedId=ETH/BTC,
   ...)` — succeeds; `isProvider()` is true.
3. `getQuote()` — returns a tight band around ~1,208,178 token1/token0.
4. `createPool` with that provider — succeeds.
5. Deposit as LP, then `swap` token0 → token1 — the swap executes at the
   garbage price and the pool's token1 is drained.

## Suggested fix

Validate the quote leg at creation in `AnchoredProviderFactory` — at
minimum existence (the feed must have data or be explicitly classed),
and ideally semantic match: the two legs of a synthetic ratio must share
a quote currency / denominator. Practical options, in increasing
strength:

1. **Pair allow-list:** the factory only accepts `(baseFeedId,
   quoteFeedId)` pairs the admin has registered as a meaningful cross
   (or pairs whose quote currencies are recorded as equal in a feed
   registry). A typo'd or mismatched pair then reverts at creation.
2. **Denominator check at read:** in `AnchoredPriceProvider`, require
   the two legs' quote currencies to match before computing the ratio —
   this needs the oracle to expose each feed's quote currency, which
   the current `IPricedOracle` surface does not carry; it is the
   deeper fix.
3. **Pool-factory defence in depth:** in `_validatePriceProvider`,
   require the provider to be factory-deployed (it currently accepts
   any address with matching `token0()`/`token1()`), so a provider can
   only reach a pool through the validated factory path. This alone
   does not fix a garbage provider created through the factory — fix
   (1) is the one that closes the hole — but it removes the
   accept-anything escape hatch.

A cheaper alternative is a view helper / off-chain linter that creators
must run before creation, but a factory-side check is the only one that
cannot be skipped by accident — and the factory is where the envelope
already lives, keyed on the base feed alone.

## PoC repository

https://github.com/Anyeps/metric-synthetic-quote-leg-drain-poc

Contents: this report draft (`REPORT-DRAFT.md`), findings
(`FINDINGS.md`), the Foundry test suite, and the exact repo code under
test vendored verbatim — `contracts/` is `pool-contracts` @ `ddf8ae0`,
`oracle-contracts/` is the AnchoredPriceProvider subset of
`oracle-contracts` @ `7525bbd` (factory, provider, the five interfaces
they use, `TimeMs.sol`; the rest of that repo — Pyth/Chainlink/compressed
oracles, MultiplierOracle — is unrelated to this finding). No fork, no
mainnet interaction, no secrets.

## Payout

- **Wallet:** `0x45859319d9a362f2146d0431dc30ab8f0ef1be73`
- **Program:** Metric (Immunefi) — KYC not required.
- **Severity claimed:** Critical — listed impact "Direct theft of user
  funds" (20% of funds directly affected, max $500,000, min $50,000).
  High / Medium / Low dollar tiers were not visible on the program page
  at research time (SVG); triage to confirm against the live tier table.

---

*Draft prepared 2026-11-15. NOT submitted. Submission blocked by the
Immunefi Novice 100-credit fee; waiting for the Studio wave verdict,
same as the GMX G-P1-2(a) and G-P0-7 drafts and the Metric M-P1-3 draft.
Sensible wave order: M-P1-3 (High, permanent freezing) → M-P1-1
(Critical, theft) → G-P1-2(a) (High) → G-P0-7 (Medium).*
