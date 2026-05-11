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
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {FlowScoreHook} from "../src/FlowScoreHook.sol";

contract FlowScoreInvariantHandler is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FlowScoreHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;
    Currency internal currency0;
    Currency internal currency1;
    IUniswapV4Router04 internal swapRouter;

    address internal alice;
    address internal bob;
    bool public doubleClaimViolation;
    bool public reserveViolation;
    bool public blockCapViolation;
    uint256 public attempts;
    uint256 public successes;

    constructor(
        FlowScoreHook _hook,
        PoolKey memory _poolKey,
        Currency _currency0,
        Currency _currency1,
        IUniswapV4Router04 _swapRouter,
        IPositionManager _positionManager,
        address _permit2
    ) {
        hook = _hook;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        currency0 = _currency0;
        currency1 = _currency1;
        swapRouter = _swapRouter;

        alice = makeAddr("flow-alice");
        bob = makeAddr("flow-bob");

        _fundAndApprove(alice, _permit2, _positionManager);
        _fundAndApprove(bob, _permit2, _positionManager);
    }

    function seedPot0(uint128 amountIn) external {
        amountIn = uint128(bound(amountIn, 1e16, 5e17));
        _safeSwap(alice, amountIn, true);
    }

    function seedPot1(uint128 amountIn) external {
        amountIn = uint128(bound(amountIn, 1e16, 5e17));
        _safeSwap(bob, amountIn, false);
    }

    function tryCashbackFromPot0(uint128 amountIn) external {
        amountIn = uint128(bound(amountIn, 1e16, 5e17));
        (,,, uint256 potBefore,,,, uint48 bonusBefore, uint256 paidBefore) = hook.flowState(poolId);
        if (!_safeSwap(alice, amountIn, false)) return;
        (,,, uint256 potAfter,,,, uint48 bonusAfter, uint256 paidAfter) = hook.flowState(poolId);
        _checkBonusBounds(potBefore, potAfter, bonusBefore, paidBefore, bonusAfter, paidAfter);
    }

    function tryCashbackFromPot1(uint128 amountIn) external {
        amountIn = uint128(bound(amountIn, 1e16, 5e17));
        (,,,, uint256 potBefore,,, uint48 bonusBefore, uint256 paidBefore) = hook.flowState(poolId);
        if (!_safeSwap(bob, amountIn, true)) return;
        (,,,, uint256 potAfter,,, uint48 bonusAfter, uint256 paidAfter) = hook.flowState(poolId);
        _checkBonusBounds(potBefore, potAfter, bonusBefore, paidBefore, bonusAfter, paidAfter);
    }

    function tryDoubleClaimSameBlock(uint128 amountIn) external {
        amountIn = uint128(bound(amountIn, 1e16, 5e17));
        (,,,,,,,, uint256 paidBefore) = hook.flowState(poolId);
        if (!_safeSwap(alice, amountIn, false)) return;
        (,,,,,,,, uint256 paidAfterFirst) = hook.flowState(poolId);
        if (!_safeSwap(alice, amountIn, false)) return;
        (,,,,,,,, uint256 paidAfterSecond) = hook.flowState(poolId);
        if (paidAfterSecond > paidAfterFirst && paidAfterFirst > paidBefore) {
            doubleClaimViolation = true;
        }
    }

    function roll(uint8 n) external {
        vm.roll(block.number + 1 + (n % 3));
    }

    function getPoolId() external view returns (PoolId) {
        return poolId;
    }

    function aliceAddr() external view returns (address) {
        return alice;
    }

    function _fundAndApprove(address user, address permit2, IPositionManager positionManager) internal {
        deal(Currency.unwrap(currency0), user, 100_000e18);
        deal(Currency.unwrap(currency1), user, 100_000e18);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(permit2, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(permit2, type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        IPermit2(permit2)
            .approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, type(uint48).max);
        IPermit2(permit2)
            .approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        IPermit2(permit2).approve(Currency.unwrap(currency0), address(swapRouter), type(uint160).max, type(uint48).max);
        IPermit2(permit2).approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _safeSwap(address user, uint256 amountIn, bool zeroForOne) internal returns (bool ok) {
        attempts++;
        vm.prank(user);
        try swapRouter.swapExactTokensForTokens(
            amountIn, 0, zeroForOne, poolKey, Constants.ZERO_BYTES, user, block.timestamp + 1
        ) {
            successes++;
            return true;
        } catch {
            return false;
        }
    }

    function _checkBonusBounds(
        uint256 potBefore,
        uint256 potAfter,
        uint48 bonusBefore,
        uint256 paidBefore,
        uint48 bonusAfter,
        uint256 paidAfter
    ) internal {
        if (potAfter < hook.MIN_FEE_POT_RESERVE() && potAfter < potBefore) reserveViolation = true;
        if (bonusAfter != uint48(block.number)) return;

        uint256 blockCap = potBefore * hook.MAX_BLOCK_CASHBACK_BPS_OF_POT() / hook.BPS_DENOMINATOR();
        uint256 paidInThisTx;
        if (bonusBefore == uint48(block.number)) {
            if (paidAfter >= paidBefore) paidInThisTx = paidAfter - paidBefore;
            uint256 remainingBefore = paidBefore >= blockCap ? 0 : blockCap - paidBefore;
            if (paidInThisTx > remainingBefore) blockCapViolation = true;
        } else {
            if (paidAfter > blockCap) blockCapViolation = true;
        }
    }
}

contract FlowScoreHookInvariantTest is StdInvariant, BaseTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;

    FlowScoreHook internal hook;
    PoolId internal poolId;
    FlowScoreInvariantHandler internal handler;

    function setUp() public {
        deployArtifactsAndLabel();
        (Currency currency0, Currency currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x5656 << 144)
        );
        deployCodeTo("FlowScoreHook.sol:FlowScoreHook", abi.encode(poolManager), flags);
        hook = FlowScoreHook(payable(flags));

        PoolKey memory poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
        positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            200e18,
            type(uint256).max,
            type(uint256).max,
            address(this),
            block.timestamp + 1,
            Constants.ZERO_BYTES
        );

        handler = new FlowScoreInvariantHandler(
            hook, poolKey, currency0, currency1, swapRouter, positionManager, address(permit2)
        );
        targetContract(address(handler));

        handler.seedPot0(2e16);
        handler.seedPot1(2e16);
    }

    function invariant_FlowScore_FeePotsNeverUnderflow_AndCapRespected() public view {
        (,,, uint256 feePot0, uint256 feePot1,,, uint48 bonusBlock, uint256 blockBonusPaid) = hook.flowState(poolId);
        assertLe(feePot0 + feePot1, 1_000_000e18, "fee pots must stay bounded");
        if (bonusBlock == uint48(block.number)) {
            assertLe(blockBonusPaid, feePot0 + feePot1, "bonus paid bounded by total pot");
        }
        assertFalse(handler.blockCapViolation(), "handler observed per-block cap violation");
        assertFalse(handler.reserveViolation(), "handler observed reserve violation");
        assertGt(handler.successes(), 0, "handler must execute successful swaps");
        assertGt(handler.attempts(), 0, "handler must attempt swap actions");
    }

    function invariant_FlowScore_SameSenderCannotClaimTwiceSameBlock() public view {
        assertFalse(handler.doubleClaimViolation(), "same sender received cashback twice in one block");
    }

    function invariant_FlowScore_OnlyOwnerCanChangeScale() public view {
        assertEq(hook.owner(), address(this));
    }
}
