// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {SentinelJITGuardHook} from "../src/SentinelJITGuardHook.sol";

contract SentinelInvariantHandler is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    SentinelJITGuardHook internal hook;
    IPositionManager internal positionManager;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKeyA;
    PoolKey internal poolKeyB;
    PoolId internal poolIdA;
    PoolId internal poolIdB;

    address internal alice;
    address internal bob;

    uint256[] internal idsA;
    uint256[] internal idsB;

    constructor(
        SentinelJITGuardHook _hook,
        IPositionManager _positionManager,
        Currency _currency0,
        Currency _currency1,
        PoolKey memory _poolKeyA,
        PoolKey memory _poolKeyB,
        address _permit2
    ) {
        hook = _hook;
        positionManager = _positionManager;
        currency0 = _currency0;
        currency1 = _currency1;
        poolKeyA = _poolKeyA;
        poolKeyB = _poolKeyB;
        poolIdA = _poolKeyA.toId();
        poolIdB = _poolKeyB.toId();

        alice = makeAddr("inv-alice");
        bob = makeAddr("inv-bob");

        _fundAndApprove(alice, _permit2);
        _fundAndApprove(bob, _permit2);
    }

    function addA(uint128 liq) external {
        liq = uint128(bound(liq, 1e15, 5e18));
        vm.startPrank(alice);
        (uint256 tid,) = positionManager.mint(
            poolKeyA,
            -120,
            120,
            liq,
            type(uint256).max,
            type(uint256).max,
            alice,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
        idsA.push(tid);
    }

    function addB(uint128 liq) external {
        liq = uint128(bound(liq, 1e15, 5e18));
        vm.startPrank(bob);
        (uint256 tid,) = positionManager.mint(
            poolKeyB,
            -120,
            120,
            liq,
            type(uint256).max,
            type(uint256).max,
            bob,
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
        idsB.push(tid);
    }

    function removeA(uint256 seed, uint128 liq) external {
        if (idsA.length == 0) return;
        uint256 tid = idsA[seed % idsA.length];
        bytes32 pk = _pk(alice, tid);
        (,,,, uint128 storedLiq,,) = hook.positions(poolIdA, pk);
        if (storedLiq == 0) return;

        liq = uint128(bound(liq, 1, storedLiq));
        vm.prank(alice);
        positionManager.decreaseLiquidity(tid, liq, 0, 0, alice, block.timestamp + 1, Constants.ZERO_BYTES);
    }

    function removeB(uint256 seed, uint128 liq) external {
        if (idsB.length == 0) return;
        uint256 tid = idsB[seed % idsB.length];
        bytes32 pk = _pk(bob, tid);
        (,,,, uint128 storedLiq,,) = hook.positions(poolIdB, pk);
        if (storedLiq == 0) return;

        liq = uint128(bound(liq, 1, storedLiq));
        vm.prank(bob);
        positionManager.decreaseLiquidity(tid, liq, 0, 0, bob, block.timestamp + 1, Constants.ZERO_BYTES);
    }

    function idsALength() external view returns (uint256) {
        return idsA.length;
    }

    function idsBLength() external view returns (uint256) {
        return idsB.length;
    }

    function idAAt(uint256 i) external view returns (uint256) {
        return idsA[i];
    }

    function idBAt(uint256 i) external view returns (uint256) {
        return idsB[i];
    }

    function positionKeyA(uint256 tid) external view returns (bytes32) {
        return keccak256(abi.encodePacked(alice, int24(-120), int24(120), bytes32(tid)));
    }

    function positionKeyB(uint256 tid) external view returns (bytes32) {
        return keccak256(abi.encodePacked(bob, int24(-120), int24(120), bytes32(tid)));
    }

    function getPoolIds() external view returns (PoolId, PoolId) {
        return (poolIdA, poolIdB);
    }

    function _pk(address owner, uint256 tid) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, int24(-120), int24(120), bytes32(tid)));
    }

    function _fundAndApprove(address user, address permit2) internal {
        deal(Currency.unwrap(currency0), user, 100_000e18);
        deal(Currency.unwrap(currency1), user, 100_000e18);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(permit2, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(permit2, type(uint256).max);
        IPermit2(permit2)
            .approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        IPermit2(permit2)
            .approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }
}

contract SentinelJITGuardHookInvariantTest is StdInvariant, BaseTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;

    SentinelJITGuardHook internal hook;
    PoolKey internal poolKeyA;
    PoolKey internal poolKeyB;
    PoolId internal poolIdA;
    PoolId internal poolIdB;

    SentinelInvariantHandler internal handler;

    function setUp() public {
        deployArtifactsAndLabel();
        (Currency currency0, Currency currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4545 << 144)
        );
        deployCodeTo("SentinelJITGuardHook.sol:SentinelJITGuardHook", abi.encode(poolManager), flags);
        hook = SentinelJITGuardHook(flags);

        poolKeyA = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolKeyB = PoolKey(currency0, currency1, 500, 60, IHooks(hook));
        poolIdA = poolKeyA.toId();
        poolIdB = poolKeyB.toId();

        poolManager.initialize(poolKeyA, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(poolKeyB, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKeyA.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKeyA.tickSpacing);

        positionManager.mint(
            poolKeyA,
            tickLower,
            tickUpper,
            200e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );
        positionManager.mint(
            poolKeyB,
            tickLower,
            tickUpper,
            200e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        handler = new SentinelInvariantHandler(
            hook, positionManager, currency0, currency1, poolKeyA, poolKeyB, address(permit2)
        );
        targetContract(address(handler));
    }

    function invariant_Sentinel_StateSafety() public view {
        uint256 lenA = handler.idsALength();
        for (uint256 i = 0; i < lenA; i++) {
            uint256 tid = handler.idAAt(i);
            bytes32 pk = handler.positionKeyA(tid);
            (uint48 addedAtBlock,,,, uint128 liquidity, uint128 cumulativeAdded, uint128 cumulativeRemoved) =
                hook.positions(poolIdA, pk);

            assertLe(cumulativeRemoved, cumulativeAdded, "removed cannot exceed added");
            if (addedAtBlock == 0) {
                assertEq(liquidity, 0, "deleted metadata must have zero liquidity");
            } else {
                assertLe(liquidity, cumulativeAdded, "remaining liquidity must be bounded by total added");
            }
        }

        uint256 lenB = handler.idsBLength();
        for (uint256 i = 0; i < lenB; i++) {
            uint256 tid = handler.idBAt(i);
            bytes32 pk = handler.positionKeyB(tid);
            (uint48 addedAtBlock,,,, uint128 liquidity, uint128 cumulativeAdded, uint128 cumulativeRemoved) =
                hook.positions(poolIdB, pk);

            assertLe(cumulativeRemoved, cumulativeAdded, "removed cannot exceed added");
            if (addedAtBlock == 0) {
                assertEq(liquidity, 0, "deleted metadata must have zero liquidity");
            } else {
                assertLe(liquidity, cumulativeAdded, "remaining liquidity must be bounded by total added");
            }
        }
    }

    function invariant_Sentinel_PoolIsolation() public view {
        uint256 lenA = handler.idsALength();
        for (uint256 i = 0; i < lenA; i++) {
            bytes32 pk = handler.positionKeyA(handler.idAAt(i));
            (uint48 inB,,,,,,) = hook.positions(poolIdB, pk);
            assertEq(inB, 0, "pool A key must not exist in pool B");
        }

        uint256 lenB = handler.idsBLength();
        for (uint256 i = 0; i < lenB; i++) {
            bytes32 pk = handler.positionKeyB(handler.idBAt(i));
            (uint48 inA,,,,,,) = hook.positions(poolIdA, pk);
            assertEq(inA, 0, "pool B key must not exist in pool A");
        }
    }

    function invariant_Sentinel_MaxPenaltyBound() public view {
        assertEq(hook.MAX_PENALTY_BPS(), 3000);
        assertLe(hook.BASE_PENALTY_BPS(), hook.MAX_PENALTY_BPS());
    }
}
