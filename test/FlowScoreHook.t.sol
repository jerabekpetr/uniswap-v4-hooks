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

        // Deploy hooku na adresu se správnými flagy
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("FlowScoreHook.sol:FlowScoreHook", constructorArgs, flags);
        hook = FlowScoreHook(payable(flags));

        // Pool musí mít DYNAMIC_FEE_FLAG
        poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(hook)
        );
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // Přidej základní likviditu do poolu
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

    function test_InitialState() public view {
        (
            uint256 emaPrice,
            int256 inventoryImbalance,
            uint256 feePot,
            uint256 lastUpdated,
        ) = hook.flowState(poolId);

        assertGt(emaPrice, 0);           
        assertEq(inventoryImbalance, 0); 
        assertEq(feePot, 0);             
        assertGt(lastUpdated, 0);        
    }


    function test_ToxicSwap_HigherFee() public {
        _fundAndApprove(address(this), 1000e18);

        uint256 balance0Before = currency0.balanceOfSelf();

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

        uint256 balance0AfterFirst = currency0.balanceOfSelf();
        uint256 spent0First = balance0Before - balance0AfterFirst;

        uint256 balance0BeforeSecond = currency0.balanceOfSelf();

        // 2nd Toxic swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 balance0AfterSecond = currency0.balanceOfSelf();
        uint256 spent0Second = balance0BeforeSecond - balance0AfterSecond;

        assertGe(spent0Second, spent0First);
    }

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

        (,, uint256 feePot, ,) = hook.flowState(poolId);
        assertGt(feePot, 0);
    }

    
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
        // Toxic swao
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        (,, uint256 feePotBefore, ,) = hook.flowState(poolId);
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
        (,, uint256 feePotAfter, ,) = hook.flowState(poolId);

        assertLt(feePotAfter, feePotBefore);

        uint256 cashback = feePotBefore - feePotAfter;
        assertGt(cashback, 0);

        uint256 received0 = balance0After - balance0Before;
        uint256 spent1 = balance1Before - balance1After;
        assertGt(received0, spent1 * 99 / 100);
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
