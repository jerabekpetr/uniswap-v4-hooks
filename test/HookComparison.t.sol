// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SentinelJITGuardHook} from "../src/SentinelJITGuardHook.sol";
import {FlatTimelockWithdrawalFeeHook} from "../src/baselines/FlatTimelockWithdrawalFeeHook.sol";
import {FlowScoreHook} from "../src/FlowScoreHook.sol";
import {SimpleVolatilityFeeHook} from "../src/baselines/SimpleVolatilityFeeHook.sol";

contract HookComparisonTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    int24 constant TICK_SPACING = 60;

    Currency currency0;
    Currency currency1;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        tickLower = TickMath.minUsableTick(TICK_SPACING);
        tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        // permit2 → swapRouter approval (deployCurrencyPair only sets permit2 → positionManager)
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Deployment helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _deploySentinel() internal returns (SentinelJITGuardHook) {
        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("SentinelJITGuardHook.sol:SentinelJITGuardHook", abi.encode(poolManager), flags);
        return SentinelJITGuardHook(flags);
    }

    function _deployFlatTimelock() internal returns (FlatTimelockWithdrawalFeeHook) {
        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "FlatTimelockWithdrawalFeeHook.sol:FlatTimelockWithdrawalFeeHook", abi.encode(poolManager), flags
        );
        return FlatTimelockWithdrawalFeeHook(flags);
    }

    function _deployFlowScore() internal returns (FlowScoreHook) {
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("FlowScoreHook.sol:FlowScoreHook", abi.encode(poolManager), flags);
        return FlowScoreHook(payable(flags));
    }

    function _deploySimpleVol() internal returns (SimpleVolatilityFeeHook) {
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        deployCodeTo("SimpleVolatilityFeeHook.sol:SimpleVolatilityFeeHook", abi.encode(poolManager), flags);
        return SimpleVolatilityFeeHook(flags);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Sentinel vs FlatTimelock
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev Wide (full-range) passive LPs removed inside the grace/timelock window incur zero
    ///      penalty from Sentinel (width factor rounds to 0 in integer arithmetic) but a flat
    ///      30% penalty from FlatTimelock. Demonstrates Sentinel avoids false positives for
    ///      legitimate passive LPs that happen to rebalance early.
    function test_Sentinel_LowerFalsePositiveThanFlatTimelock_WidePassiveLP() public {
        SentinelJITGuardHook sentinel = _deploySentinel();
        FlatTimelockWithdrawalFeeHook flat = _deployFlatTimelock();

        PoolKey memory sentinelKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(sentinel));
        PoolKey memory flatKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(flat));
        poolManager.initialize(sentinelKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(flatKey, Constants.SQRT_PRICE_1_1);

        // Background positions remain in both pools so that FlatTimelock's donate() never
        // hits a zero-liquidity pool when the test LP is removed.
        positionManager.mint(
            sentinelKey, tickLower, tickUpper, 10e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        positionManager.mint(
            flatKey, tickLower, tickUpper, 10e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );

        uint128 liquidity = 50e18;

        // Add full-range liquidity to Sentinel pool and measure token0 cost
        uint256 b0BeforeSentinel = currency0.balanceOfSelf();
        (uint256 tidS,) = positionManager.mint(
            sentinelKey, tickLower, tickUpper, liquidity,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 dep0S = b0BeforeSentinel - currency0.balanceOfSelf();

        // Add full-range liquidity to FlatTimelock pool and measure token0 cost
        uint256 b0BeforeFlat = currency0.balanceOfSelf();
        (uint256 tidF,) = positionManager.mint(
            flatKey, tickLower, tickUpper, liquidity,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 dep0F = b0BeforeFlat - currency0.balanceOfSelf();

        // Advance 10 blocks — inside both GRACE_BLOCKS=20 and TIMELOCK_BLOCKS=20
        vm.roll(block.number + 10);

        // Remove from Sentinel pool — width factor (600/1774440 ≈ 0) rounds penalty to 0
        uint256 mid0 = currency0.balanceOfSelf();
        positionManager.decreaseLiquidity(
            tidS, liquidity, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 rec0S = currency0.balanceOfSelf() - mid0;
        uint256 sentinelPenalty = dep0S > rec0S ? dep0S - rec0S : 0;

        // Remove from FlatTimelock pool — flat 30% penalty always applies inside TIMELOCK_BLOCKS
        mid0 = currency0.balanceOfSelf();
        positionManager.decreaseLiquidity(
            tidF, liquidity, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 rec0F = currency0.balanceOfSelf() - mid0;
        uint256 flatPenalty = dep0F > rec0F ? dep0F - rec0F : 0;

        assertGt(flatPenalty, 0, "FlatTimelock must apply a non-zero penalty inside the timelock window");
        assertLt(sentinelPenalty, flatPenalty, "Sentinel must penalise wide passive LP less than FlatTimelock");
    }

    /// @dev Narrow same-block JIT positions must be penalised by both hooks with a non-zero amount.
    ///      Sentinel's penalty is bounded by MAX_PENALTY_BPS regardless of conditions.
    function test_Sentinel_PenalizesNarrowJITComparably() public {
        SentinelJITGuardHook sentinel = _deploySentinel();
        FlatTimelockWithdrawalFeeHook flat = _deployFlatTimelock();

        PoolKey memory sentinelKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(sentinel));
        PoolKey memory flatKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(flat));
        poolManager.initialize(sentinelKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(flatKey, Constants.SQRT_PRICE_1_1);

        // Passive full-range liquidity so the narrow JIT positions are in-range
        positionManager.mint(
            sentinelKey, tickLower, tickUpper, 50e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        positionManager.mint(
            flatKey, tickLower, tickUpper, 50e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );

        int24 jitLower = -120;
        int24 jitUpper = 120;
        uint128 jitLiq = 10e18;

        // Sentinel: add narrow liquidity and remove in the same block (age = 0)
        uint256 b0 = currency0.balanceOfSelf();
        (uint256 tidS,) = positionManager.mint(
            sentinelKey, jitLower, jitUpper, jitLiq,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 dep0S = b0 - currency0.balanceOfSelf();
        uint256 mid0 = currency0.balanceOfSelf();
        positionManager.decreaseLiquidity(
            tidS, jitLiq, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 rec0S = currency0.balanceOfSelf() - mid0;
        uint256 sentinelPenalty = dep0S > rec0S ? dep0S - rec0S : 0;

        // FlatTimelock: add narrow liquidity and remove in the same block (age = 0)
        b0 = currency0.balanceOfSelf();
        (uint256 tidF,) = positionManager.mint(
            flatKey, jitLower, jitUpper, jitLiq,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 dep0F = b0 - currency0.balanceOfSelf();
        mid0 = currency0.balanceOfSelf();
        positionManager.decreaseLiquidity(
            tidF, jitLiq, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        uint256 rec0F = currency0.balanceOfSelf() - mid0;
        uint256 flatPenalty = dep0F > rec0F ? dep0F - rec0F : 0;

        assertGt(sentinelPenalty, 0, "Sentinel must penalise narrow same-block JIT position");
        assertGt(flatPenalty, 0, "FlatTimelock must penalise narrow same-block JIT position");
        // Sentinel penalty bounded by MAX_PENALTY_BPS of principal (+ 1 for integer rounding)
        assertLe(
            sentinelPenalty,
            dep0S * sentinel.MAX_PENALTY_BPS() / sentinel.BPS() + 1,
            "Sentinel penalty must not exceed MAX_PENALTY_BPS of deposit"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // FlowScore vs SimpleVolatility
    // ─────────────────────────────────────────────────────────────────────────────

    /// @dev FlowScore rewards benign (inventory-restoring) swappers with cashback from the fee pot.
    ///      SimpleVolatility has no redistribution mechanism — no CashbackPaid event is ever emitted.
    function test_FlowScore_RewardsInventoryRestoringFlow_BaselineDoesNot() public {
        FlowScoreHook flowHook = _deployFlowScore();
        SimpleVolatilityFeeHook simpleVol = _deploySimpleVol();

        PoolKey memory flowKey =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(flowHook));
        PoolKey memory volKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(simpleVol));
        poolManager.initialize(flowKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(volKey, Constants.SQRT_PRICE_1_1);

        PoolId flowPid = flowKey.toId();

        // Seed wide liquidity on both pools
        positionManager.mint(
            flowKey, tickLower, tickUpper, 100e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        positionManager.mint(
            volKey, tickLower, tickUpper, 100e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );

        // Toxic swap on FlowScore (zeroForOne worsens token0-heavy imbalance, builds feePot0)
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: flowKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePot0Before,,,,,) = flowHook.flowState(flowPid);
        assertGt(feePot0Before, 0, "feePot must be non-zero after a toxic swap");

        // Roll one block to clear the per-caller cooldown on the swapRouter address
        vm.roll(block.number + 1);

        // Benign swap on FlowScore: oneForZero reduces token0 imbalance, cashback paid from feePot0
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: flowKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        Vm.Log[] memory flowLogs = vm.getRecordedLogs();

        bytes32 cashbackSig = keccak256("CashbackPaid(bytes32,uint256)");
        bool cashbackFound = false;
        for (uint256 i = 0; i < flowLogs.length; i++) {
            if (flowLogs[i].topics[0] == cashbackSig) {
                cashbackFound = true;
                break;
            }
        }
        assertTrue(cashbackFound, "FlowScore must emit CashbackPaid for a benign inventory-restoring swap");

        (,,, uint256 feePot0After,,,,,) = flowHook.flowState(flowPid);
        assertLt(feePot0After, feePot0Before, "feePot must decrease after cashback payout");

        // Same benign swap on SimpleVolatility — no redistribution, no CashbackPaid event
        vm.recordLogs();
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: volKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        Vm.Log[] memory volLogs = vm.getRecordedLogs();

        for (uint256 i = 0; i < volLogs.length; i++) {
            assertNotEq(volLogs[i].topics[0], cashbackSig, "SimpleVolatility must never emit CashbackPaid");
        }
    }

    /// @dev A toxic swap accumulates a fee pot in FlowScore (half the surcharge is captured for
    ///      redistribution). SimpleVolatility responds only by updating its rolling volatility EMA —
    ///      no fee pot mechanism exists in the baseline.
    function test_FlowScore_ToxicFlowBuildsPot_SimpleVolatilityOnlyRaisesFee() public {
        FlowScoreHook flowHook = _deployFlowScore();
        SimpleVolatilityFeeHook simpleVol = _deploySimpleVol();

        PoolKey memory flowKey =
            PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks(flowHook));
        PoolKey memory volKey = PoolKey(currency0, currency1, 3000, TICK_SPACING, IHooks(simpleVol));
        poolManager.initialize(flowKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(volKey, Constants.SQRT_PRICE_1_1);

        PoolId flowPid = flowKey.toId();
        PoolId volPid = volKey.toId();

        // Seed wide liquidity on both pools
        positionManager.mint(
            flowKey, tickLower, tickUpper, 100e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        positionManager.mint(
            volKey, tickLower, tickUpper, 100e18,
            type(uint256).max, type(uint256).max,
            address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );

        // Toxic swap on FlowScore — surcharge contribution flows into feePot0
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: flowKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePot0,,,,,) = flowHook.flowState(flowPid);
        assertGt(feePot0, 0, "FlowScore must accumulate a fee pot after a toxic swap");

        // Two swaps on SimpleVol: first initialises state, second feeds a non-zero sigma sample
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: volKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        vm.roll(block.number + 1);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: volKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (, , uint256 sigmaX18,) = simpleVol.volatility(volPid);
        assertGt(sigmaX18, 0, "SimpleVolatility must update its volatility EMA after a tick-moving swap");
        // SimpleVolatility has no fee pot — it can only raise fees, never redistribute surcharges
    }
}
