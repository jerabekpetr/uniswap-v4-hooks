// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SimpleVolatilityFeeHook} from "../src/baselines/SimpleVolatilityFeeHook.sol";

contract SimpleVolatilityBaselineHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    SimpleVolatilityFeeHook hook;
    PoolKey poolKey;
    PoolId poolId;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x8888 << 144));

        deployCodeTo("SimpleVolatilityFeeHook.sol:SimpleVolatilityFeeHook", abi.encode(poolManager), flags);
        hook = SimpleVolatilityFeeHook(payable(flags));

        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

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

    function test_BaselineVolatility_StateUpdatesAfterSwaps() public {
        _fundAndApprove(address(this), 10_000e18);

        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            swapRouter.swapExactTokensForTokens({
                amountIn: 3e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        (bool initialized,, uint256 sigmaX18,) = hook.volatility(poolId);
        assertTrue(initialized);
        assertGt(sigmaX18, 0, "volatility EMA should update after swaps");
    }

    function test_BaselineVolatility_HigherVolatilityHigherFee() public {
        _fundAndApprove(address(this), 20_000e18);

        uint24 calmFee = hook.currentFee(poolId);
        assertEq(calmFee, hook.BASE_FEE());

        for (uint256 i = 0; i < 8; i++) {
            vm.roll(block.number + 1);
            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        uint24 volatileFee = hook.currentFee(poolId);
        assertGt(volatileFee, calmFee, "volatile pool should quote higher fee than calm pool");
    }

    function test_BaselineVolatility_FeeCappedByMaxFee() public {
        _fundAndApprove(address(this), 50_000e18);

        for (uint256 i = 0; i < 20; i++) {
            vm.roll(block.number + 1);
            swapRouter.swapExactTokensForTokens({
                amountIn: 10e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        uint24 fee = hook.currentFee(poolId);
        assertLe(fee, hook.MAX_FEE(), "fee must be capped by MAX_FEE");
        assertEq(fee, hook.MAX_FEE(), "large volatility should saturate at MAX_FEE");
    }

    function test_BaselineVolatility_MultiPoolStateIsolation() public {
        _fundAndApprove(address(this), 20_000e18);

        PoolKey memory keyB = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 120, IHooks(hook));
        PoolId poolIdB = keyB.toId();
        poolManager.initialize(keyB, Constants.SQRT_PRICE_1_1);

        int24 tickLowerB = TickMath.minUsableTick(keyB.tickSpacing);
        int24 tickUpperB = TickMath.maxUsableTick(keyB.tickSpacing);
        positionManager.mint(
            keyB,
            tickLowerB,
            tickUpperB,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint24 feeA0 = hook.currentFee(poolId);
        uint24 feeB0 = hook.currentFee(poolIdB);
        assertEq(feeA0, hook.BASE_FEE());
        assertEq(feeB0, hook.BASE_FEE());

        for (uint256 i = 0; i < 6; i++) {
            vm.roll(block.number + 1);
            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: block.timestamp + 1
            });
        }

        uint24 feeA1 = hook.currentFee(poolId);
        uint24 feeB1 = hook.currentFee(poolIdB);
        (,, uint256 sigmaA,) = hook.volatility(poolId);
        (,, uint256 sigmaB,) = hook.volatility(poolIdB);

        assertGt(feeA1, feeA0, "pool A fee should increase with local volatility");
        assertEq(feeB1, feeB0, "pool B fee must remain unchanged");
        assertGt(sigmaA, 0, "pool A volatility should update");
        assertEq(sigmaB, 0, "pool B volatility should remain zero");
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        deal(Currency.unwrap(currency0), user, amount);
        deal(Currency.unwrap(currency1), user, amount);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}
