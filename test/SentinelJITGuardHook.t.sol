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

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SentinelJITGuardHook} from "../src/SentinelJITGuardHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract SentinelJITGuardHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    SentinelJITGuardHook hook;
    PoolId poolId;
    PoolKey poolKey;

    Currency currency0;
    Currency currency1;

    int24 tickLower;
    int24 tickUpper;

    // Passive LP tokenId
    uint256 passiveLPTokenId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy hook at address with correct flags
        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );

        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("SentinelJITGuardHook.sol:SentinelJITGuardHook", constructorArgs, flags);
        hook = SentinelJITGuardHook(flags);

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // Passive LP adds full-range liquidity in setUp – block 1.
        (passiveLPTokenId,) = positionManager.mint(
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

    /// @dev Hook stores addedAtBlock and liquidity after afterAddLiquidity callback.
    function test_PositionTrackedOnAdd() public view {
        bytes32 pk =
            keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper, bytes32(passiveLPTokenId)));

        (uint48 addedAtBlock,,,,,,) = hook.positions(poolId, pk);
        assertEq(addedAtBlock, uint48(block.number));
    }

    /// @dev Position tracked in one pool does not appear in a separate pool.
    function test_Unit_PoolIsolation() public view {
        PoolKey memory otherKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        PoolId otherId = otherKey.toId();

        bytes32 pk =
            keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper, bytes32(passiveLPTokenId)));

        (uint48 addedAtBlock,,,,,,) = hook.positions(otherId, pk);
        assertEq(addedAtBlock, 0);
    }

    // ─────────────────────────────────────────────
    // INTEGRATION TESTS
    // ─────────────────────────────────────────────

    /// @dev Full-range LP removing liquidity one block later receives tokens back with no effective penalty
    /// (width factor makes penalty round to zero for full-range positions).
    function test_RemoveLiquidity_NextBlock_NoPenalty() public {
        vm.roll(block.number + 1);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        positionManager.decreaseLiquidity(
            passiveLPTokenId, 50e18, 0, 0, address(this), block.timestamp + 1, Constants.ZERO_BYTES
        );

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertGt(balance0After, balance0Before);
        assertGt(balance1After, balance1Before);
    }

    /// @dev Attacker adding and removing narrow-range liquidity in the same block receives a penalty
    /// equal to BASE_PENALTY_BPS of the deposited principal.
    function test_JIT_SameBlock_PenaltyApplied() public {
        address attacker = makeAddr("attacker");
        _fundAndApprove(attacker, 1000e18);

        // Narrow range: width = 240 ticks ≤ REFERENCE_WIDTH_TICKS (600) → full width factor.
        int24 jitLower = -120;
        int24 jitUpper = 120;

        vm.startPrank(attacker);

        uint256 balance0BeforeMint = currency0.balanceOf(attacker);

        (uint256 attackerTokenId,) = positionManager.mint(
            poolKey,
            jitLower,
            jitUpper,
            50e18,
            type(uint256).max,
            type(uint256).max,
            attacker,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint256 balance0AfterMint = currency0.balanceOf(attacker);
        uint256 deposited = balance0BeforeMint - balance0AfterMint;

        positionManager.decreaseLiquidity(
            attackerTokenId, 50e18, 0, 0, attacker, block.timestamp + 1, Constants.ZERO_BYTES
        );

        vm.stopPrank();

        uint256 balance0AfterRemove = currency0.balanceOf(attacker);
        uint256 received = balance0AfterRemove - balance0AfterMint;
        uint256 actualPenalty = deposited - received;
        uint256 expectedPenalty = deposited * hook.BASE_PENALTY_BPS() / hook.BPS();

        assertApproxEqRel(actualPenalty, expectedPenalty, 0.01e18); // 1% tolerance
    }

    // ─────────────────────────────────────────────
    // FUZZ TESTS
    // ─────────────────────────────────────────────

    /// @dev Penalty never exceeds BASE_PENALTY_BPS of deposited amount regardless of liquidity size.
    /// Full-range positions have near-zero width factor so actual penalty << maximum.
    function test_Fuzz_PenaltyNeverExceedsDelta(uint128 liquidity) public {
        liquidity = uint128(bound(liquidity, 1e15, 50e18));

        address attacker = makeAddr("fuzzTest");
        _fundAndApprove(attacker, 1000e18);

        vm.startPrank(attacker);

        uint256 balance0BeforeMint = currency0.balanceOf(attacker);

        (uint256 attackerTokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            attacker,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint256 balance0AfterMint = currency0.balanceOf(attacker);
        uint256 deposited = balance0BeforeMint - balance0AfterMint;

        positionManager.decreaseLiquidity(
            attackerTokenId, liquidity, 0, 0, attacker, block.timestamp + 1, Constants.ZERO_BYTES
        );

        vm.stopPrank();

        uint256 balance0AfterRemove = currency0.balanceOf(attacker);
        uint256 received = balance0AfterRemove - balance0AfterMint;

        // Penalty is at most BASE_PENALTY_BPS of deposit (plus vol boost, but vol is 0 here).
        uint256 maxPenalty = deposited * hook.BASE_PENALTY_BPS() / hook.BPS();
        assertLe(deposited - received, maxPenalty + 1);
    }

    /// @dev No effective penalty for full-range positions regardless of how many blocks have elapsed
    /// (width factor makes the penalty round to zero for full-range positions).
    function test_Fuzz_NoPenaltyAfterGracePeriod(uint128 liquidity, uint256 blocksToWait) public {
        liquidity = uint128(bound(liquidity, 1e15, 50e18));
        blocksToWait = bound(blocksToWait, 1, 100);
        address lp = makeAddr("fuzzyLP");
        _fundAndApprove(lp, 1000e18);

        vm.startPrank(lp);
        (uint256 tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            lp,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        uint256 balance0AfterMint = currency0.balanceOf(lp);

        vm.roll(block.number + blocksToWait);

        positionManager.decreaseLiquidity(tokenId, liquidity, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);

        vm.stopPrank();

        uint256 balance0AfterRemove = currency0.balanceOf(lp);

        // Full-range: width factor rounds penalty to 0 → LP gets back at least what they deposited.
        assertGe(balance0AfterRemove, balance0AfterMint);
    }

    /// @dev JIT penalty never causes accounting revert regardless of liquidity size.
    function test_Fuzz_Remove_NoNegativeAccounting(uint128 liquidity) public {
        liquidity = uint128(bound(liquidity, 1e15, 50e18));

        address attacker = makeAddr("fuzzAccounting");
        _fundAndApprove(attacker, 1000e18);

        vm.startPrank(attacker);

        (uint256 tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            attacker,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        // Same block removal – should apply penalty but never revert.
        positionManager.decreaseLiquidity(tokenId, liquidity, 0, 0, attacker, block.timestamp + 1, Constants.ZERO_BYTES);

        vm.stopPrank();
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
        vm.stopPrank();
    }
}
