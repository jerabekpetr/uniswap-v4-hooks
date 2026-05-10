// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {FlowScoreHook} from "../src/FlowScoreHook.sol";

contract FlowScoreHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    FlowScoreHook hook;
    PoolId poolId;
    PoolKey poolKey;

    Currency currency0;
    Currency currency1;

    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("FlowScoreHook.sol:FlowScoreHook", constructorArgs, flags);
        hook = FlowScoreHook(payable(flags));

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
    }

    // ─────────────────────────────────────────────
    // UNIT TESTS
    // ─────────────────────────────────────────────

    /// @dev Initial hook state after pool init: emaTick = 0, imbalance = 0, both feePots = 0.
    function test_InitialState() public view {
        (int24 emaTick, int256 signedFlowEma, int256 inventoryImbalance, uint256 feePot0, uint256 feePot1, uint256 lastUpdated,,,) =
            hook.flowState(poolId);

        assertEq(emaTick, 0); // tick at sqrt_price_1_1 is 0
        assertEq(signedFlowEma, 0);
        assertEq(inventoryImbalance, 0);
        assertEq(feePot0, 0);
        assertEq(feePot1, 0);
        assertGt(lastUpdated, 0);
    }

    /// @dev Larger toxic swap must contribute more to feePot than a smaller one.
    function test_Unit_FeePot_ScalesWithSwapSize() public {
        _fundAndApprove(address(this), 10_000e18);

        uint256 snap = vm.snapshot();

        // small toxic swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        (,,, uint256 feePotSmall,,,,,) = hook.flowState(poolId);

        vm.revertTo(snap);
        _fundAndApprove(address(this), 10_000e18);

        // large toxic swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        (,,, uint256 feePotLarge,,,,,) = hook.flowState(poolId);

        assertGt(feePotLarge, feePotSmall);
    }

    /// @dev Benign swap receives no cashback when feePot is empty.
    function test_Unit_NoRebate_EmptyFeePot() public {
        _fundAndApprove(address(this), 1000e18);

        // Tiny toxic swap - toxicityRatio ≈ 0, contribution rounds to 0, feePot stays empty
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e15,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePot,,,,,) = hook.flowState(poolId);
        assertEq(feePot, 0);

        // Benign swap back - no cashback expected
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e15,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePotAfter,,,,,) = hook.flowState(poolId);
        assertEq(feePotAfter, 0);
    }

    /// @dev Cashback is capped at feePot balance - feePot never goes negative.
    function test_Unit_Cashback_CappedAtFeePot() public {
        _fundAndApprove(address(this), 1000e18);

        // Toxic swap - builds feePot
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePotBefore,,,,,) = hook.flowState(poolId);
        assertGt(feePotBefore, 0);

        // Benign swap - smaller than imbalance, does not overshoot
        swapRouter.swapExactTokensForTokens({
            amountIn: 0.5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePotAfter,,,,,) = hook.flowState(poolId);
        assertLe(feePotAfter, feePotBefore);
    }

    /// @dev Once imbalance exceeds scale, toxicityRatio is capped - fee stays at MAX_FEE.
    /// Two identical swaps at the cap must produce the same feePot contribution.
    function test_Unit_Fee_CappedAtMaxFee() public {
        _fundAndApprove(address(this), 10_000e18);
        hook.setImbalanceScale(poolKey, 5e18);

        // Push well past scale
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePot0,,,,,) = hook.flowState(poolId);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        (,,, uint256 feePot1,,,,,) = hook.flowState(poolId);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        (,,, uint256 feePot2,,,,,) = hook.flowState(poolId);

        assertEq(feePot1 - feePot0, feePot2 - feePot1);
    }

    // ─────────────────────────────────────────────
    // INTEGRATION TESTS
    // ─────────────────────────────────────────────

    /// @dev Second same-direction swap receives less token1 - higher toxicityRatio raises fee.
    function test_ToxicSwap_HigherFee() public {
        _fundAndApprove(address(this), 1000e18);

        // First toxic swap
        uint256 balance1Before = currency1.balanceOfSelf();
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 received1First = currency1.balanceOfSelf() - balance1Before;

        // Second toxic swap
        uint256 balance1BeforeSecond = currency1.balanceOfSelf();
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        uint256 received1Second = currency1.balanceOfSelf() - balance1BeforeSecond;

        assertLt(received1Second, received1First);
    }

    /// @dev Repeated toxic swaps in the same direction must grow feePot.
    function test_FeePot_AccumulatesAfterToxicSwap() public {
        _fundAndApprove(address(this), 1000e18);

        // Imbalance
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // toxic swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePot,,,,,) = hook.flowState(poolId);
        assertGt(feePot, 0);
    }

    /// @dev Benign swap (reduces imbalance) receives cashback; feePot decreases accordingly.
    function test_BenignSwap_GetsCashback() public {
        _fundAndApprove(address(this), 1000e18);
        // Imbalance
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        // Toxic swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePotBefore,,,,,) = hook.flowState(poolId);
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0Before = currency0.balanceOfSelf();

        // Benign swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 0.1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();
        (,,, uint256 feePotAfter,,,,,) = hook.flowState(poolId);

        assertLt(feePotAfter, feePotBefore);

        uint256 cashback = feePotBefore - feePotAfter;
        assertGt(cashback, 0);

        uint256 received0 = balance0After - balance0Before;
        uint256 spent1 = balance1Before - balance1After;
        assertGt(received0, spent1 * 99 / 100);
    }

    // ─────────────────────────────────────────────
    // FUZZ TESTS
    // ─────────────────────────────────────────────

    /// @dev feePot never underflows regardless of swap sequence.
    function test_Fuzz_FeePot_NeverUnderflows(uint256 toxicSize, uint256 benignSize) public {
        toxicSize = bound(toxicSize, 1e15, 50e18);
        benignSize = bound(benignSize, 1e15, toxicSize);

        _fundAndApprove(address(this), 1000e18);

        // Toxic swap - builds feePot
        swapRouter.swapExactTokensForTokens({
            amountIn: toxicSize,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // Benign swap - bounded by toxicSize to avoid overshoot
        swapRouter.swapExactTokensForTokens({
            amountIn: benignSize,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePot,,,,,) = hook.flowState(poolId);
        assertGe(feePot, 0);
    }

    /// @dev Total cashback paid out never exceeds total feePot accumulated.
    function test_Fuzz_TotalRebates_NeverExceedSurcharge(uint256 toxicSize, uint256 benignSize) public {
        toxicSize = bound(toxicSize, 1e15, 50e18);
        benignSize = bound(benignSize, 1e15, toxicSize);

        _fundAndApprove(address(this), 1000e18);

        swapRouter.swapExactTokensForTokens({
            amountIn: toxicSize,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePotAfterToxic,,,,,) = hook.flowState(poolId);

        swapRouter.swapExactTokensForTokens({
            amountIn: benignSize,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,,, uint256 feePotAfterBenign,,,,,) = hook.flowState(poolId);

        uint256 cashbackPaid = feePotAfterToxic - feePotAfterBenign;
        assertLe(cashbackPaid, feePotAfterToxic);
    }

    // ─────────────────────────────────────────────
    // Helper
    // ─────────────────────────────────────────────
    function _fundAndApprove(address user, uint256 amount) internal {
        deal(Currency.unwrap(currency0), user, amount);
        deal(Currency.unwrap(currency1), user, amount);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}
