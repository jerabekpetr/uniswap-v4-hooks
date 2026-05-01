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
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface IFlowScoreHookLike {
    function flowState(PoolId)
        external
        view
        returns (uint256 emaPrice, int256 inventoryImbalance, uint256 feePot, uint256 lastUpdated, uint256 imbalanceScale);
    function setImbalanceScale(PoolKey calldata key, uint256 scale) external;
}

contract FlowScoreSimulator {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TickMath for int24;
    using LiquidityAmounts for uint160;
    using Actions for IPositionManager;

    error PoolAlreadyInitialized();
    error ZeroLiquidity();
    error PoolNotInitialized();
    error ZeroSwapAmount();

    uint24 public constant MAX_FEE = 10000;
    uint24 public constant MIN_FEE = 500;
    uint24 public constant BASE_FEE = 3000;
    uint256 public constant FEE_DENOMINATOR = 1_000_000;
    uint256 public constant MAX_CASHBACK_BPS = 35;
    uint256 public constant BPS_DENOMINATOR = 10000;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant SQRT_PRICE_1_1 = 2 ** 96;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IUniswapV4Router04 public immutable swapRouter;
    IPermit2 public immutable permit2;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    IFlowScoreHookLike public immutable flowHook;

    PoolKey public poolKey;
    bool public poolInitialized;
    uint256 public passiveTokenId;

    struct LastSwapInfo {
        bool exists;
        bool zeroForOne;
        bool toxic;
        uint256 amountIn;
        uint256 feePaid;
        uint256 feePotAdded;
        uint256 feePotUsed;
        uint256 amountOut;
    }

    LastSwapInfo public lastSwap;

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IUniswapV4Router04 _swapRouter,
        IPermit2 _permit2,
        MockERC20 _token0,
        MockERC20 _token1,
        IHooks _flowHook
    ) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        swapRouter = _swapRouter;
        permit2 = _permit2;
        token0 = _token0;
        token1 = _token1;
        flowHook = IFlowScoreHookLike(address(_flowHook));

        Currency c0 = Currency.wrap(address(_token0));
        Currency c1 = Currency.wrap(address(_token1));

        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: _flowHook
        });

        if (address(poolManager).code.length > 0) {
            try _poolManager.initialize(poolKey, SQRT_PRICE_1_1) {} catch {}
        }

        _token0.approve(address(_swapRouter), type(uint256).max);
        _token1.approve(address(_swapRouter), type(uint256).max);
    }

    function initializePool(uint256 initialLiquidityPerToken) external {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (initialLiquidityPerToken == 0) revert ZeroLiquidity();

        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(positionManager), type(uint160).max, type(uint48).max);

        uint256 totalMint = initialLiquidityPerToken * 4 + 1000e18;
        token0.mint(address(this), totalMint);
        token1.mint(address(this), totalMint);

        int24 lower = _alignTick(-750 * TICK_SPACING);
        int24 upper = _alignTick(750 * TICK_SPACING);
        passiveTokenId = _mintPosition(poolKey, lower, upper, initialLiquidityPerToken, initialLiquidityPerToken);
        // MAX_FEE at 8 % imbalance of total pool (= 16 % of one side)
        flowHook.setImbalanceScale(poolKey, initialLiquidityPerToken * 16 / 100);
        poolInitialized = true;
    }

    function executeSwap(bool zeroForOne, uint256 amountIn) external returns (LastSwapInfo memory info) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (amountIn == 0) revert ZeroSwapAmount();

        token0.mint(address(this), amountIn + 1e18);
        token1.mint(address(this), amountIn + 1e18);

        PoolId pid = poolKey.toId();
        (, int256 imbalance, uint256 feePotBefore, , uint256 imbalanceScale) = flowHook.flowState(pid);

        uint24 feeBps = _quoteFeeBps(imbalance, zeroForOne, amountIn, imbalanceScale);
        bool toxic = feeBps > BASE_FEE;
        uint256 feePaid = (amountIn * feeBps) / FEE_DENOMINATOR;

        uint256 amountOut = _swap(zeroForOne, amountIn);
        (, , uint256 feePotAfter, ,) = flowHook.flowState(pid);
        uint256 feePotAdded = feePotAfter > feePotBefore ? feePotAfter - feePotBefore : 0;
        uint256 feePotUsed = feePotBefore > feePotAfter ? feePotBefore - feePotAfter : 0;

        info = LastSwapInfo({
            exists: true,
            zeroForOne: zeroForOne,
            toxic: toxic,
            amountIn: amountIn,
            feePaid: feePaid,
            feePotAdded: feePotAdded,
            feePotUsed: feePotUsed,
            amountOut: amountOut
        });
        lastSwap = info;
    }

    function getPoolSnapshot()
        external
        view
        returns (
            uint256 reserve0,
            uint256 reserve1,
            uint256 share0Bps,
            uint256 share1Bps,
            uint256 feePotBalance,
            LastSwapInfo memory info
        )
    {
        reserve0 = token0.balanceOf(address(poolManager));
        reserve1 = token1.balanceOf(address(poolManager));
        uint256 total = reserve0 + reserve1;
        if (total > 0) {
            share0Bps = (reserve0 * BPS_DENOMINATOR) / total;
            share1Bps = BPS_DENOMINATOR - share0Bps;
        }
        (,, feePotBalance, ,) = flowHook.flowState(poolKey.toId());
        info = lastSwap;
    }

    function _quoteFeeBps(int256 imbalance, bool zeroForOne, uint256 swapSize, uint256 scale)
        internal
        pure
        returns (uint24)
    {
        int256 signedFlow = zeroForOne ? int256(swapSize) : -int256(swapSize);
        int256 imbalanceAfter = imbalance + signedFlow;
        uint256 absBefore = imbalance >= 0 ? uint256(imbalance) : uint256(-imbalance);
        uint256 absAfter = imbalanceAfter >= 0 ? uint256(imbalanceAfter) : uint256(-imbalanceAfter);

        if (absAfter <= absBefore) return MIN_FEE;

        uint256 toxicity = absAfter >= scale ? 100 : (absAfter * 100) / scale;
        return uint24(BASE_FEE + (toxicity * (MAX_FEE - BASE_FEE)) / 100);
    }

    function _alignTick(int24 tick) internal pure returns (int24) {
        return (tick / TICK_SPACING) * TICK_SPACING;
    }

    function _mintPosition(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256 tokenId) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
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
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            amount0Desired + 1 wei,
            amount1Desired + 1 wei,
            address(this),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        tokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    function _swap(bool zeroForOne, uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 beforeOut = zeroForOne ? token1.balanceOf(address(this)) : token0.balanceOf(address(this));
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: bytes(""),
            receiver: address(this),
            deadline: block.timestamp + 60
        });
        uint256 afterOut = zeroForOne ? token1.balanceOf(address(this)) : token0.balanceOf(address(this));
        amountOut = afterOut - beforeOut;
    }
}
