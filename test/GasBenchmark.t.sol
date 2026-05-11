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
import {FlatTimelockWithdrawalFeeHook} from "../src/baselines/FlatTimelockWithdrawalFeeHook.sol";
import {SimpleVolatilityFeeHook} from "../src/baselines/SimpleVolatilityFeeHook.sol";

contract GasBenchmark is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Pools
    PoolKey vanillaKey;
    PoolKey sentinelKey;
    PoolKey flatTimelockKey;
    PoolKey flowScoreKey;
    PoolKey simpleVolKey;

    // Hooks
    SentinelJITGuardHook sentinel;
    FlatTimelockWithdrawalFeeHook flatTimelock;
    FlowScoreHook flowScore;
    SimpleVolatilityFeeHook simpleVol;

    Currency currency0;
    Currency currency1;

    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        _fundAndApprove(address(this), 100_000e18);

        // --- Vanilla pool (no hook) ---
        vanillaKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        poolManager.initialize(vanillaKey, Constants.SQRT_PRICE_1_1);

        // --- Sentinel pool ---
        address sentinelFlags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("SentinelJITGuardHook.sol:SentinelJITGuardHook", abi.encode(poolManager), sentinelFlags);
        sentinel = SentinelJITGuardHook(sentinelFlags);
        sentinelKey = PoolKey(currency0, currency1, 3000, 60, IHooks(sentinel));
        poolManager.initialize(sentinelKey, Constants.SQRT_PRICE_1_1);

        // --- Flat timelock baseline pool ---
        address flatFlags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x7777 << 144)
        );
        deployCodeTo(
            "FlatTimelockWithdrawalFeeHook.sol:FlatTimelockWithdrawalFeeHook", abi.encode(poolManager), flatFlags
        );
        flatTimelock = FlatTimelockWithdrawalFeeHook(flatFlags);
        flatTimelockKey = PoolKey(currency0, currency1, 3000, 60, IHooks(flatTimelock));
        poolManager.initialize(flatTimelockKey, Constants.SQRT_PRICE_1_1);

        // --- FlowScore pool ---
        address flowFlags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );
        deployCodeTo("FlowScoreHook.sol:FlowScoreHook", abi.encode(poolManager), flowFlags);
        flowScore = FlowScoreHook(payable(flowFlags));
        flowScoreKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(flowScore));
        poolManager.initialize(flowScoreKey, Constants.SQRT_PRICE_1_1);

        // --- Simple volatility baseline pool ---
        address simpleVolFlags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x8888 << 144));
        deployCodeTo("SimpleVolatilityFeeHook.sol:SimpleVolatilityFeeHook", abi.encode(poolManager), simpleVolFlags);
        simpleVol = SimpleVolatilityFeeHook(payable(simpleVolFlags));
        simpleVolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(simpleVol));
        poolManager.initialize(simpleVolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(60);
        tickUpper = TickMath.maxUsableTick(60);

        // Seed liquidity into all pools
        _addLiquidity(vanillaKey, 100e18);
        _addLiquidity(sentinelKey, 100e18);
        _addLiquidity(flatTimelockKey, 100e18);
        _addLiquidity(flowScoreKey, 100e18);
        _addLiquidity(simpleVolKey, 100e18);
    }

    // ─────────────────────────────────────────────
    // BENCHMARKS
    // ─────────────────────────────────────────────

    function test_Gas_AddLiquidity_SentinelVsFlatTimelock() public {
        _addLiquidity(vanillaKey, 1e15);
        _addLiquidity(sentinelKey, 1e15);
        _addLiquidity(flatTimelockKey, 1e15);

        uint256 g;

        g = gasleft();
        _addLiquidity(vanillaKey, 10e18);
        console.log("addLiquidity vanilla:      ", g - gasleft());

        g = gasleft();
        _addLiquidity(sentinelKey, 10e18);
        console.log("addLiquidity sentinel:     ", g - gasleft());

        g = gasleft();
        _addLiquidity(flatTimelockKey, 10e18);
        console.log("addLiquidity flatTimelock: ", g - gasleft());
    }

    function test_Gas_RemoveLiquidity_SentinelVsFlatTimelock() public {
        uint256 tokenVanilla = _addLiquidity(vanillaKey, 10e18);
        uint256 tokenSentinel = _addLiquidity(sentinelKey, 10e18);
        uint256 tokenFlat = _addLiquidity(flatTimelockKey, 10e18);

        vm.roll(block.number + 1);

        uint256 g;

        g = gasleft();
        positionManager.decreaseLiquidity(
            tokenVanilla, 10e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        console.log("removeLiquidity vanilla:      ", g - gasleft());

        g = gasleft();
        positionManager.decreaseLiquidity(
            tokenSentinel, 10e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        console.log("removeLiquidity sentinel:     ", g - gasleft());

        g = gasleft();
        positionManager.decreaseLiquidity(
            tokenFlat, 10e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );
        console.log("removeLiquidity flatTimelock: ", g - gasleft());
    }

    function test_Gas_Swap_SentinelVsFlatTimelock() public {
        _swap(vanillaKey, 0.1e18, true);
        _swap(sentinelKey, 0.1e18, true);
        _swap(flatTimelockKey, 0.1e18, true);

        uint256 g;

        g = gasleft();
        _swap(vanillaKey, 1e18, true);
        console.log("swap vanilla:       ", g - gasleft());

        g = gasleft();
        _swap(sentinelKey, 1e18, true);
        console.log("swap sentinel:     ", g - gasleft());

        g = gasleft();
        _swap(flatTimelockKey, 1e18, true);
        console.log("swap flatTimelock: ", g - gasleft());
    }

    function test_Gas_Swap_FlowScoreVsSimpleVolatility() public {
        // Warm up and build deterministic volatility state for both dynamic fee hooks.
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            bool direction = i % 2 == 0;
            _swap(vanillaKey, 0.3e18, direction);
            _swap(flowScoreKey, 0.3e18, direction);
            _swap(simpleVolKey, 0.3e18, direction);
        }

        uint256 g;

        g = gasleft();
        _swap(vanillaKey, 1e18, true);
        console.log("swap vanilla:         ", g - gasleft());

        g = gasleft();
        _swap(flowScoreKey, 1e18, true);
        console.log("swap flowScore:        ", g - gasleft());

        g = gasleft();
        _swap(simpleVolKey, 1e18, true);
        console.log("swap simpleVolatility: ", g - gasleft());
    }

    function test_Gas_AddLiquidity() public {
        // Legacy aggregate benchmark retained for continuity.
        _addLiquidity(vanillaKey, 1e15);
        _addLiquidity(flatTimelockKey, 1e15);
        _addLiquidity(sentinelKey, 1e15);
        _addLiquidity(simpleVolKey, 1e15);
        _addLiquidity(flowScoreKey, 1e15);

        uint256 g;

        g = gasleft();
        _addLiquidity(vanillaKey, 10e18);
        console.log("addLiquidity vanilla:       ", g - gasleft());

        g = gasleft();
        _addLiquidity(flatTimelockKey, 10e18);
        console.log("addLiquidity flatTimelock: ", g - gasleft());

        g = gasleft();
        _addLiquidity(sentinelKey, 10e18);
        console.log("addLiquidity sentinel:     ", g - gasleft());

        g = gasleft();
        _addLiquidity(simpleVolKey, 10e18);
        console.log("addLiquidity simpleVol:    ", g - gasleft());

        g = gasleft();
        _addLiquidity(flowScoreKey, 10e18);
        console.log("addLiquidity flowScore:    ", g - gasleft());
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

    function _swap(PoolKey memory key, uint256 amountIn, bool zeroForOne) internal {
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
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
