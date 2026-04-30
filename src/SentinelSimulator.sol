// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

contract SentinelSimulator {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using TickMath for int24;
    using LiquidityAmounts for uint160;
    using Actions for IPositionManager;
    using FullMath for uint256;

    uint24  public constant FEE = 3000;
    int24   public constant TICK_SPACING = 60;
    uint160 public constant SQRT_PRICE_1_1 = 2**96; 

    IPoolManager      public immutable poolManager;
    IPositionManager  public immutable positionManager;
    IUniswapV4Router04 public immutable swapRouter;
    IPermit2          public immutable permit2;
    MockERC20         public immutable token0;
    MockERC20         public immutable token1;
    IHooks            public immutable sentinelHook;

    PoolKey public poolWithHookKey;
    PoolKey public poolNoHookKey;

    struct ScenarioResult {
        int256 passiveLPDelta0;
        int256 passiveLPDelta1;
        int256 jitDelta0;
        int256 jitDelta1;
        uint256 swapAmountOut;
    }

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IUniswapV4Router04 _swapRouter,
        IPermit2 _permit2,
        MockERC20 _token0,
        MockERC20 _token1,
        IHooks _sentinelHook
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        swapRouter = _swapRouter;
        permit2 = _permit2;
        token0 = _token0;
        token1 = _token1;
        sentinelHook = _sentinelHook;

        Currency c0 = Currency.wrap(address(_token0));
        Currency c1 = Currency.wrap(address(_token1));

        poolWithHookKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: _sentinelHook
        });
        poolNoHookKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        if (address(poolManager).code.length > 0) {
            try _poolManager.initialize(poolWithHookKey, SQRT_PRICE_1_1) {} catch {}
            try _poolManager.initialize(poolNoHookKey, SQRT_PRICE_1_1) {} catch {}
        }

        // _token0.approve(address(_permit2), type(uint256).max);
        // _token1.approve(address(_permit2), type(uint256).max);
        _token0.approve(address(_swapRouter), type(uint256).max);
        _token1.approve(address(_swapRouter), type(uint256).max);
        // _permit2.approve(address(_token0), address(_positionManager), type(uint160).max, type(uint48).max);
        // _permit2.approve(address(_token1), address(_positionManager), type(uint160).max, type(uint48).max);
    }

    function poolWithHookId() external view returns (PoolId) {
        return poolWithHookKey.toId();
    }

    function poolNoHookId() external view returns (PoolId) {
        return poolNoHookKey.toId();
    }

    function runScenario(
        uint256 passiveToken0,
        uint256 passiveToken1,
        uint256 jitToken0,
        uint256 jitToken1,
        uint256 swapAmountIn,
        bool useHook,
        bool useJIT
    ) external returns (ScenarioResult memory result) {
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);

        PoolKey memory poolKey = useHook ? poolWithHookKey : poolNoHookKey;
        PoolId poolId = poolKey.toId();

        // Mintne tokeny pro všechny operace, které potřebujeme
        uint256 totalMint = (passiveToken0 + passiveToken1 + jitToken0 + jitToken1 + swapAmountIn) * 2 + 1000e18;
        token0.mint(address(this), totalMint);
        token1.mint(address(this), totalMint);

        // Pasivní LP: wide range(±750x tickSpacing kolem 0)
        int24 passiveLower = _alignTick(-750 * TICK_SPACING);
        int24 passiveUpper = _alignTick(750 * TICK_SPACING);
        uint256 passiveTokenId;
        if (passiveToken0 > 0 || passiveToken1 > 0) {
            passiveTokenId = _mintPosition(poolKey, passiveLower, passiveUpper, passiveToken0, passiveToken1);
        }

        // JIT add — měříme co bylo utraceno
        uint256 jitTokenId;
        int24 jitLower;
        int24 jitUpper;
        uint256 jitSpent0;
        uint256 jitSpent1;
        if (useJIT && (jitToken0 > 0 || jitToken1 > 0)) {
            jitLower = _alignTick(-2 * TICK_SPACING);
            jitUpper = _alignTick(2 * TICK_SPACING);
            uint256 b0BeforeAdd = token0.balanceOf(address(this));
            uint256 b1BeforeAdd = token1.balanceOf(address(this));
            jitTokenId = _mintPosition(poolKey, jitLower, jitUpper, jitToken0, jitToken1);
            jitSpent0 = b0BeforeAdd - token0.balanceOf(address(this));
            jitSpent1 = b1BeforeAdd - token1.balanceOf(address(this));
        }

        // Swap 
        if (swapAmountIn > 0) {
            result.swapAmountOut = _swap(poolKey, swapAmountIn);
        }

        // JIT remove — měříme co bylo vráceno, swap z výpočtu vynecháme 
        if (useJIT && jitTokenId != 0) {
            uint256 b0BeforeRemove = token0.balanceOf(address(this));
            uint256 b1BeforeRemove = token1.balanceOf(address(this));
            _decreaseLiquidity(jitTokenId);
            uint256 jitReturned0 = token0.balanceOf(address(this)) - b0BeforeRemove;
            uint256 jitReturned1 = token1.balanceOf(address(this)) - b1BeforeRemove;
            result.jitDelta0 = int256(jitReturned0) - int256(jitSpent0);
            result.jitDelta1 = int256(jitReturned1) - int256(jitSpent1);
        }

        // Passive LP fee growth measurement
        if (passiveTokenId != 0) {
            (result.passiveLPDelta0, result.passiveLPDelta1) = _computePassiveFees(
                poolId,
                passiveLower,
                passiveUpper,
                passiveTokenId
            );
        }
    }

    ////////////////// Helper functions /////////////////

    function _alignTick(int24 tick) internal pure returns (int24) {
        return (tick / TICK_SPACING) * TICK_SPACING;
    }

    function _mintPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256 tokenId) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0Desired + 1 wei,
            amount1Desired + 1 wei,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    function _decreaseLiquidity(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint256(0), bytes(""));
        params[1] = abi.encode(poolWithHookKey.currency0, poolWithHookKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    function _swap(PoolKey memory poolKey, uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 before = token1.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: address(this),
            deadline: block.timestamp + 60
        });
        amountOut = token1.balanceOf(address(this)) - before;
    }

    function _computePassiveFees(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenId
    ) internal view returns (int256 fees0, int256 fees1) {
        bytes32 salt = bytes32(tokenId);
        (uint128 liquidity, uint256 feeGrowthInside0Last, uint256 feeGrowthInside1Last) = poolManager.getPositionInfo(poolId, address(positionManager), tickLower, tickUpper, salt);
        (uint256 feeGrowthInside0Now, uint256 feeGrowthInside1Now) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

        uint256 delta0 = feeGrowthInside0Now >= feeGrowthInside0Last ? feeGrowthInside0Now - feeGrowthInside0Last : 0;
        uint256 delta1 = feeGrowthInside1Now >= feeGrowthInside1Last ? feeGrowthInside1Now - feeGrowthInside1Last : 0;

        fees0 = int256(FullMath.mulDiv(delta0, liquidity, 1 << 128));
        fees1 = int256(FullMath.mulDiv(delta1, liquidity, 1 << 128));
    }
}