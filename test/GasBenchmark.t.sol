// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {SentinelJITGuardHook} from "../src/SentinelJITGuardHook.sol";
import {FlowScoreHook} from "../src/FlowScoreHook.sol";

contract GasBenchmark is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Pools
    PoolKey vanillaKey;
    PoolKey sentinelKey;
    PoolKey flowScoreKey;

    // Hooks
    SentinelJITGuardHook sentinel;
    FlowScoreHook flowScore;

    Currency currency0;
    Currency currency1;

    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        _fundAndApprove(address(this), 100_000e18);

        // --- Vanilla pool ---
        vanillaKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);

        // --- Sentinel pool ---
        address sentinelFlags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("SentinelJITGuardHook.sol:SentinelJITGuardHook", abi.encode(poolManager), sentinelFlags);
        sentinel = SentinelJITGuardHook(sentinelFlags);
        sentinelKey = PoolKey(currency0, currency1, 3000, 60, IHooks(sentinel));
        poolManager.initialize(sentinelKey, Constants.SQRT_PRICE_1_1);

        // --- FlowScore pool ---
        address flowFlags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG
                    | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );
        deployCodeTo("FlowScoreHook.sol:FlowScoreHook", abi.encode(poolManager), flowFlags);
        flowScore = FlowScoreHook(payable(flowFlags));
        flowScoreKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flowScore));
        poolManager.initialize(flowScoreKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(60);
        tickUpper = TickMath.maxUsableTick(60);

        // Seed liquidity into all three pools
        _addLiquidity(vanillaKey, 100e18);
        _addLiquidity(sentinelKey, 100e18);
        _addLiquidity(flowScoreKey, 100e18);
    }

    // ─────────────────────────────────────────────
    // BENCHMARKS
    // ─────────────────────────────────────────────

    function test_Gas_AddLiquidity() public {
        // Warm up storage slots for all three pools
        _addLiquidity(vanillaKey, 1e15);
        _addLiquidity(sentinelKey, 1e15);
        _addLiquidity(flowScoreKey, 1e15);

        uint256 g;

        g = gasleft();
        _addLiquidity(vanillaKey, 10e18);
        console.log("addLiquidity vanilla:   ", g - gasleft());

        g = gasleft();
        _addLiquidity(sentinelKey, 10e18);
        console.log("addLiquidity sentinel:  ", g - gasleft());

        g = gasleft();
        _addLiquidity(flowScoreKey, 10e18);
        console.log("addLiquidity flowScore: ", g - gasleft());
    }

    function test_Gas_RemoveLiquidity() public {
        uint256 tokenVanilla  = _addLiquidity(vanillaKey,    10e18);
        uint256 tokenSentinel = _addLiquidity(sentinelKey,   10e18);
        uint256 tokenFlow     = _addLiquidity(flowScoreKey,  10e18);

        vm.roll(block.number + 1);

        uint256 g;

        g = gasleft();
        positionManager.decreaseLiquidity(tokenVanilla, 10e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES);
        console.log("removeLiquidity vanilla:   ", g - gasleft());

        g = gasleft();
        positionManager.decreaseLiquidity(tokenSentinel, 10e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES);
        console.log("removeLiquidity sentinel:  ", g - gasleft());

        g = gasleft();
        positionManager.decreaseLiquidity(tokenFlow, 10e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES);
        console.log("removeLiquidity flowScore: ", g - gasleft());
    }

    function test_Gas_Swap() public {
        // Warm up
        _swap(vanillaKey, 0.1e18);
        _swap(sentinelKey, 0.1e18);
        _swap(flowScoreKey, 0.1e18);
        
        uint256 g;

        g = gasleft();
        _swap(vanillaKey, 1e18);
        console.log("swap vanilla:   ", g - gasleft());

        g = gasleft();
        _swap(sentinelKey, 1e18);
        console.log("swap sentinel:  ", g - gasleft());

        g = gasleft();
        _swap(flowScoreKey, 1e18);
        console.log("swap flowScore: ", g - gasleft());
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _addLiquidity(PoolKey memory key, uint256 amount) internal returns (uint256 tokenId) {
        (tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            amount,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
    }

    function _swap(PoolKey memory key, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });
    }

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