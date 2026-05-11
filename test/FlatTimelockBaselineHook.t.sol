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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {FlatTimelockWithdrawalFeeHook} from "../src/baselines/FlatTimelockWithdrawalFeeHook.sol";

contract FlatTimelockBaselineHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FlatTimelockWithdrawalFeeHook hook;
    PoolKey poolKey;
    PoolId poolId;
    Currency currency0;
    Currency currency1;

    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x7777 << 144)
        );

        deployCodeTo("FlatTimelockWithdrawalFeeHook.sol:FlatTimelockWithdrawalFeeHook", abi.encode(poolManager), flags);
        hook = FlatTimelockWithdrawalFeeHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
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

    function test_BaselineTimelock_RemoveBeforeTimelock_AppliesFlatPenalty() public {
        address lp = makeAddr("tl-before");
        _fundAndApprove(lp, 1000e18);

        vm.startPrank(lp);
        uint256 b0 = currency0.balanceOf(lp);
        (uint256 tid,) = positionManager.mint(
            poolKey,
            -120,
            120,
            10e18,
            type(uint256).max,
            type(uint256).max,
            lp,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 deposited = b0 - currency0.balanceOf(lp);

        uint256 b0r = currency0.balanceOf(lp);
        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 received = currency0.balanceOf(lp) - b0r;
        vm.stopPrank();

        assertLt(received, deposited, "early removal should apply flat penalty");
    }

    function test_BaselineTimelock_RemoveAfterTimelock_ZeroPenalty() public {
        address lp = makeAddr("tl-after");
        _fundAndApprove(lp, 1000e18);

        vm.startPrank(lp);
        uint256 b0 = currency0.balanceOf(lp);
        (uint256 tid,) = positionManager.mint(
            poolKey,
            -120,
            120,
            10e18,
            type(uint256).max,
            type(uint256).max,
            lp,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 deposited = b0 - currency0.balanceOf(lp);

        vm.roll(block.number + hook.TIMELOCK_BLOCKS());

        uint256 b0r = currency0.balanceOf(lp);
        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 received = currency0.balanceOf(lp) - b0r;
        vm.stopPrank();

        assertApproxEqAbs(received, deposited, 1, "post-timelock removal should not penalize principal");
    }

    function test_BaselineTimelock_PartialRemoval_PreservesRemainingLiquidity() public {
        address lp = makeAddr("tl-partial");
        _fundAndApprove(lp, 1000e18);

        vm.startPrank(lp);
        (uint256 tid,) = positionManager.mint(
            poolKey,
            -120,
            120,
            20e18,
            type(uint256).max,
            type(uint256).max,
            lp,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        bytes32 pk = keccak256(abi.encodePacked(address(positionManager), int24(-120), int24(120), bytes32(tid)));

        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);
        (uint48 addedAt, uint128 liq,,) = hook.positions(poolId, pk);
        assertGt(addedAt, 0);
        assertEq(liq, 10e18);

        vm.roll(block.number + hook.TIMELOCK_BLOCKS());
        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);
        (uint48 addedAfter, uint128 liqAfter,,) = hook.positions(poolId, pk);
        assertEq(addedAfter, 0, "metadata deleted after full removal");
        assertEq(liqAfter, 0, "remaining liquidity zero after full removal");
        vm.stopPrank();
    }

    function test_BaselineTimelock_MultiPoolStateIsolation() public {
        address lpA = makeAddr("tl-A");
        address lpB = makeAddr("tl-B");
        _fundAndApprove(lpA, 1000e18);
        _fundAndApprove(lpB, 1000e18);

        PoolKey memory keyB = PoolKey(currency0, currency1, 500, 60, IHooks(hook));
        PoolId poolIdB = keyB.toId();
        poolManager.initialize(keyB, Constants.SQRT_PRICE_1_1);
        vm.startPrank(lpB);
        positionManager.mint(
            keyB,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            lpB,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        vm.startPrank(lpA);
        (uint256 tidA,) = positionManager.mint(
            poolKey,
            -120,
            120,
            10e18,
            type(uint256).max,
            type(uint256).max,
            lpA,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        vm.startPrank(lpB);
        (uint256 tidB,) = positionManager.mint(
            keyB, -120, 120, 10e18, type(uint256).max, type(uint256).max, lpB, block.timestamp + 1, Constants.ZERO_BYTES
        );
        vm.stopPrank();

        bytes32 pkA = keccak256(abi.encodePacked(address(positionManager), int24(-120), int24(120), bytes32(tidA)));
        bytes32 pkB = keccak256(abi.encodePacked(address(positionManager), int24(-120), int24(120), bytes32(tidB)));

        (uint48 aInA,,,) = hook.positions(poolId, pkA);
        (uint48 aInB,,,) = hook.positions(poolIdB, pkA);
        assertGt(aInA, 0);
        assertEq(aInB, 0);

        vm.startPrank(lpA);
        positionManager.decreaseLiquidity(tidA, 5e18, 0, 0, lpA, block.timestamp + 1, Constants.ZERO_BYTES);
        vm.stopPrank();

        (, uint128 liqA,,) = hook.positions(poolId, pkA);
        (, uint128 liqB,,) = hook.positions(poolIdB, pkB);
        assertEq(liqA, 5e18);
        assertEq(liqB, 10e18, "pool B position must be unaffected");
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
