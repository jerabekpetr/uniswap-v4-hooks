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

    /// @dev Narrow position removed at GRACE_BLOCKS receives zero penalty.
    function test_Sentinel_Penalty_ZeroAfterGraceHorizon() public {
        address lp = makeAddr("graceLP");
        _fundAndApprove(lp, 1000e18);

        vm.startPrank(lp);
        uint256 balBefore = currency0.balanceOf(lp);
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
        uint256 dep = balBefore - currency0.balanceOf(lp);

        vm.roll(block.number + hook.GRACE_BLOCKS());

        uint256 balBeforeRemove = currency0.balanceOf(lp);
        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 received = currency0.balanceOf(lp) - balBeforeRemove;
        vm.stopPrank();

        assertApproxEqAbs(received, dep, 1);
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

    /// @dev Penalty at age 0 is greater than penalty at age 10 for identical narrow in-range positions.
    function test_Sentinel_Penalty_DecreasesWithAge() public {
        int24 nL = -120;
        int24 nU = 120;
        address atk1 = makeAddr("age0");
        address atk2 = makeAddr("age10");
        _fundAndApprove(atk1, 1000e18);
        _fundAndApprove(atk2, 1000e18);

        vm.startPrank(atk1);
        uint256 b1 = currency0.balanceOf(atk1);
        (uint256 tid1,) = positionManager.mint(
            poolKey,
            nL,
            nU,
            10e18,
            type(uint256).max,
            type(uint256).max,
            atk1,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 dep1 = b1 - currency0.balanceOf(atk1);
        uint256 b1r = currency0.balanceOf(atk1);
        positionManager.decreaseLiquidity(tid1, 10e18, 0, 0, atk1, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 pen1 = dep1 - (currency0.balanceOf(atk1) - b1r);
        vm.stopPrank();

        vm.startPrank(atk2);
        uint256 b2 = currency0.balanceOf(atk2);
        (uint256 tid2,) = positionManager.mint(
            poolKey,
            nL,
            nU,
            10e18,
            type(uint256).max,
            type(uint256).max,
            atk2,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 dep2 = b2 - currency0.balanceOf(atk2);
        vm.roll(block.number + 10);
        uint256 b2r = currency0.balanceOf(atk2);
        positionManager.decreaseLiquidity(tid2, 10e18, 0, 0, atk2, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 pen2 = dep2 - (currency0.balanceOf(atk2) - b2r);
        vm.stopPrank();

        assertGt(pen1, pen2);
    }

    /// @dev Narrow in-range position incurs a higher penalty rate than a wide in-range position.
    function test_Sentinel_NarrowRangePenaltyGreaterThanWideRange() public {
        address atkN = makeAddr("narrow");
        address atkW = makeAddr("wide");
        _fundAndApprove(atkN, 1000e18);
        _fundAndApprove(atkW, 1000e18);

        vm.startPrank(atkN);
        uint256 bN = currency0.balanceOf(atkN);
        (uint256 tidN,) = positionManager.mint(
            poolKey,
            -120,
            120,
            10e18,
            type(uint256).max,
            type(uint256).max,
            atkN,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 depN = bN - currency0.balanceOf(atkN);
        uint256 bNr = currency0.balanceOf(atkN);
        positionManager.decreaseLiquidity(tidN, 10e18, 0, 0, atkN, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 penN = depN - (currency0.balanceOf(atkN) - bNr);
        vm.stopPrank();

        vm.startPrank(atkW);
        uint256 bW = currency0.balanceOf(atkW);
        (uint256 tidW,) = positionManager.mint(
            poolKey,
            -600,
            600,
            10e18,
            type(uint256).max,
            type(uint256).max,
            atkW,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 depW = bW - currency0.balanceOf(atkW);
        uint256 bWr = currency0.balanceOf(atkW);
        positionManager.decreaseLiquidity(tidW, 10e18, 0, 0, atkW, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 penW = depW - (currency0.balanceOf(atkW) - bWr);
        vm.stopPrank();

        assertGt(penN * 1e18 / depN, penW * 1e18 / depW);
    }

    /// @dev In-range position is penalised; position with activeDistance >= ACTIVE_DISTANCE_TICKS receives no penalty.
    function test_Sentinel_ActiveRangePenaltyGreaterThanInactiveRange() public {
        address atkA = makeAddr("active");
        address atkI = makeAddr("inactive");
        _fundAndApprove(atkA, 1000e18);
        _fundAndApprove(atkI, 1000e18);

        // Active: surrounds tick 0 — token0 deposited
        vm.startPrank(atkA);
        uint256 bA0 = currency0.balanceOf(atkA);
        (uint256 tidA,) = positionManager.mint(
            poolKey,
            -120,
            120,
            10e18,
            type(uint256).max,
            type(uint256).max,
            atkA,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 depA = bA0 - currency0.balanceOf(atkA);
        uint256 bAr = currency0.balanceOf(atkA);
        positionManager.decreaseLiquidity(tidA, 10e18, 0, 0, atkA, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 penA = depA > (currency0.balanceOf(atkA) - bAr) ? depA - (currency0.balanceOf(atkA) - bAr) : 0;
        vm.stopPrank();

        // Inactive: tick 0 is below tickLower=660 (distance >= ACTIVE_DISTANCE_TICKS) — only token1 deposited
        vm.startPrank(atkI);
        uint256 bI1 = currency1.balanceOf(atkI);
        (uint256 tidI,) = positionManager.mint(
            poolKey,
            660,
            1260,
            10e18,
            type(uint256).max,
            type(uint256).max,
            atkI,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        uint256 depI = bI1 - currency1.balanceOf(atkI);
        uint256 bIr = currency1.balanceOf(atkI);
        positionManager.decreaseLiquidity(tidI, 10e18, 0, 0, atkI, block.timestamp + 1, Constants.ZERO_BYTES);
        uint256 penI = depI > (currency1.balanceOf(atkI) - bIr) ? depI - (currency1.balanceOf(atkI) - bIr) : 0;
        vm.stopPrank();

        assertGt(penA, 0);
        assertEq(penI, 0);
    }

    /// @dev Penalty is higher when pool volatility (sigmaX18) is elevated by prior swap activity.
    function test_Sentinel_HighVolatilityBoost() public {
        _fundAndApproveSwap(address(this), 10_000e18);

        for (uint256 i = 0; i < 8; i++) {
            vm.roll(block.number + 1);
            swapRouter.swapExactTokensForTokens({
                amountIn: 5e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: address(this),
                deadline: type(uint256).max
            });
        }

        (,, uint256 sigmaX18,) = hook.volatility(poolId);
        assertGt(sigmaX18, 0, "volatility EMA must be non-zero after swaps");

        uint256 volBoostBps = sigmaX18 >= hook.VOL_SCALE() * 1e18
            ? hook.MAX_VOL_BOOST_BPS()
            : sigmaX18 * hook.MAX_VOL_BOOST_BPS() / (hook.VOL_SCALE() * 1e18);
        assertGt(volBoostBps, 0, "volatility boost must be non-zero");
    }

    /// @dev Partial removal preserves position metadata; full removal deletes it.
    function test_Sentinel_PartialRemoval_PreservesRemainingPosition() public {
        address lp = makeAddr("partialLP");
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

        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);

        bytes32 pk = keccak256(abi.encodePacked(address(positionManager), int24(-120), int24(120), bytes32(tid)));
        (uint48 addedAtBlock,,,, uint128 remLiq,,) = hook.positions(poolId, pk);
        assertGt(addedAtBlock, 0, "metadata must persist after partial removal");
        assertGt(remLiq, 0, "remaining liquidity must be non-zero");

        vm.roll(block.number + hook.GRACE_BLOCKS() + 1);
        positionManager.decreaseLiquidity(tid, 10e18, 0, 0, lp, block.timestamp + 1, Constants.ZERO_BYTES);

        (uint48 addedAfter,,,,,,) = hook.positions(poolId, pk);
        assertEq(addedAfter, 0, "metadata must be deleted after full removal");
        vm.stopPrank();
    }

    /// @dev Multiple adds to the same position accumulate liquidity and refresh addedAtBlock.
    function test_Sentinel_MultipleAdds_AccumulateLiquidity() public {
        address lp = makeAddr("multiAdd");
        _fundAndApprove(lp, 1000e18);

        vm.startPrank(lp);
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

        bytes32 pk = keccak256(abi.encodePacked(address(positionManager), int24(-120), int24(120), bytes32(tid)));
        (uint48 blockFirst,,,, uint128 liqFirst,,) = hook.positions(poolId, pk);
        assertEq(liqFirst, 10e18);

        vm.roll(block.number + 5);

        positionManager.increaseLiquidity(
            tid, 10e18, type(uint256).max, type(uint256).max, block.timestamp + 1, Constants.ZERO_BYTES
        );

        (uint48 blockSecond,,,, uint128 liqSecond,,) = hook.positions(poolId, pk);
        assertEq(liqSecond, 20e18, "liquidity should accumulate");
        assertGt(blockSecond, blockFirst, "addedAtBlock should refresh");
        vm.stopPrank();
    }

    /// @dev State in one pool (positions + volatility) must not affect another pool using the same hook.
    function test_Sentinel_MultiPoolStateIsolation() public {
        address lpA = makeAddr("poolA-lp");
        address lpB = makeAddr("poolB-lp");
        _fundAndApprove(lpA, 10_000e18);
        _fundAndApprove(lpB, 10_000e18);
        _fundAndApproveSwap(lpA, 10_000e18);
        _fundAndApproveSwap(lpB, 10_000e18);

        PoolKey memory poolKeyB = PoolKey(currency0, currency1, 500, 60, IHooks(hook));
        PoolId poolIdB = poolKeyB.toId();
        poolManager.initialize(poolKeyB, Constants.SQRT_PRICE_1_1);
        positionManager.mint(
            poolKeyB,
            tickLower,
            tickUpper,
            100e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        vm.startPrank(lpA);
        (uint256 tidA,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
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
            poolKeyB,
            tickLower,
            tickUpper,
            10e18,
            type(uint256).max,
            type(uint256).max,
            lpB,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        bytes32 pkA = keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper, bytes32(tidA)));
        bytes32 pkB = keccak256(abi.encodePacked(address(positionManager), tickLower, tickUpper, bytes32(tidB)));

        (uint48 aInA,,,, uint128 liqAInA,,) = hook.positions(poolId, pkA);
        (uint48 aInB,,,,,,) = hook.positions(poolIdB, pkA);
        assertGt(aInA, 0, "pool A position must exist in pool A");
        assertEq(liqAInA, 10e18, "pool A liquidity tracked");
        assertEq(aInB, 0, "pool A position key must not appear in pool B");

        (,, uint256 sigmaA0,) = hook.volatility(poolId);
        (,, uint256 sigmaB0,) = hook.volatility(poolIdB);
        assertEq(sigmaA0, 0);
        assertEq(sigmaB0, 0);

        vm.startPrank(lpA);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        for (uint256 i = 0; i < 6; i++) {
            vm.roll(block.number + 1);
            swapRouter.swapExactTokensForTokens({
                amountIn: 3e18,
                amountOutMin: 0,
                zeroForOne: i % 2 == 0,
                poolKey: poolKey,
                hookData: Constants.ZERO_BYTES,
                receiver: lpA,
                deadline: type(uint256).max
            });
        }
        positionManager.decreaseLiquidity(tidA, 5e18, 0, 0, lpA, block.timestamp + 1, Constants.ZERO_BYTES);
        vm.stopPrank();

        (,, uint256 sigmaA1,) = hook.volatility(poolId);
        (,, uint256 sigmaB1,) = hook.volatility(poolIdB);
        assertGt(sigmaA1, 0, "volatility should update only for pool A");
        assertEq(sigmaB1, 0, "pool B volatility must stay untouched");

        (uint48 aAfterA,,,, uint128 liqAfterA,,) = hook.positions(poolId, pkA);
        (uint48 bInB,,,, uint128 liqBInB,,) = hook.positions(poolIdB, pkB);
        (uint48 bInA,,,,,,) = hook.positions(poolId, pkB);
        assertGt(aAfterA, 0, "pool A position metadata must remain");
        assertEq(liqAfterA, 5e18, "pool A partial removal tracked only in pool A");
        assertGt(bInB, 0, "pool B position must remain intact");
        assertEq(liqBInB, 10e18, "pool B liquidity must be unchanged");
        assertEq(bInA, 0, "pool B position key must not appear in pool A");
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

    function _fundAndApproveSwap(address user, uint256 amount) internal {
        deal(Currency.unwrap(currency0), user, amount);
        deal(Currency.unwrap(currency1), user, amount);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}
