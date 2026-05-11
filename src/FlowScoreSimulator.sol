// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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

/// @title IFlowScoreHookLike
/// @author Petr Jeřábek
/// @notice Minimal interface exposing the FlowScoreHook state needed by the simulator.
interface IFlowScoreHookLike {
    /// @notice Sets the imbalance scale for a pool (owner-only on the real hook).
    /// @param key The pool key.
    /// @param scale The new imbalance scale.
    function setImbalanceScale(PoolKey calldata key, uint256 scale) external;

    /// @notice Returns the full flow state for a given pool.
    /// @param pid The pool identifier.
    /// @return emaTick EMA of the pool tick.
    /// @return signedFlowEma EMA of signed swap flow.
    /// @return inventoryImbalance Current signed inventory imbalance.
    /// @return feePot0 Accumulated surcharge in token0.
    /// @return feePot1 Accumulated surcharge in token1.
    /// @return lastUpdated Timestamp of the most recent update.
    /// @return imbalanceScale The imbalance scale configured for this pool.
    /// @return bonusBlock Last block in which cashback was distributed.
    /// @return blockBonusPaid Total cashback paid in bonusBlock.
    function flowState(PoolId pid)
        external
        view
        returns (
            int24 emaTick,
            int256 signedFlowEma,
            int256 inventoryImbalance,
            uint256 feePot0,
            uint256 feePot1,
            uint256 lastUpdated,
            uint256 imbalanceScale,
            uint48 bonusBlock,
            uint256 blockBonusPaid
        );
}

/// @title FlowScoreSimulator
/// @author Petr Jeřábek
/// @notice Testing and simulation harness for the FlowScoreHook.
/// @dev Deploys a single pool with the FlowScoreHook attached, provides liquidity,
///      and exposes helpers to execute swaps and inspect hook state. Intended for
///      use in Foundry tests and deployment scripts only — not production code.
contract FlowScoreSimulator {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TickMath for int24;
    using LiquidityAmounts for uint160;
    using Actions for IPositionManager;

    /// @notice Snapshot of data from the most recently executed swap.
    struct LastSwapInfo {
        /// @dev True once at least one swap has been executed.
        bool exists;
        /// @dev True when token0 was swapped for token1.
        bool zeroForOne;
        /// @dev True when the swap was classified as toxic.
        bool toxic;
        /// @dev Amount of input token consumed.
        uint256 amountIn;
        /// @dev Estimated fee paid (including toxic surcharge if applicable).
        uint256 feePaid;
        /// @dev Net amount added to the fee pot by this swap.
        uint256 feePotAdded;
        /// @dev Net amount drawn from the fee pot by this swap (cashback).
        uint256 feePotUsed;
        /// @dev Amount of output token received.
        uint256 amountOut;
    }

    /// @notice Maximum dynamic fee (1.00%).
    uint24 public constant MAX_FEE = 10000;

    /// @notice Minimum dynamic fee (0.05%).
    uint24 public constant MIN_FEE = 500;

    /// @notice Baseline fee (0.30%).
    uint24 public constant BASE_FEE = 3000;

    /// @notice Denominator for fee-unit calculations (parts per million).
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Maximum cashback in basis points of the swap size (0.35%).
    uint256 public constant MAX_CASHBACK_BPS = 35;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Tick spacing used for the simulated pool.
    int24 public constant TICK_SPACING = 60;

    /// @notice Starting sqrt price corresponding to a 1:1 token ratio.
    uint160 public constant SQRT_PRICE_1_1 = 2 ** 96;

    /// @notice The Uniswap v4 pool manager.
    IPoolManager public immutable poolManager;

    /// @notice The Uniswap v4 position manager (ERC-721 NFT positions).
    IPositionManager public immutable positionManager;

    /// @notice The swap router used to execute test swaps.
    IUniswapV4Router04 public immutable swapRouter;

    /// @notice The Permit2 contract used to approve token transfers.
    IPermit2 public immutable permit2;

    /// @notice The lower-address token in the pool pair.
    MockERC20 public immutable token0;

    /// @notice The higher-address token in the pool pair.
    MockERC20 public immutable token1;

    /// @notice The FlowScoreHook instance attached to the simulated pool.
    IFlowScoreHookLike public immutable flowHook;

    /// @notice The pool key for the simulated FlowScoreHook pool.
    PoolKey public poolKey;

    /// @notice True once initializePool has been called successfully.
    bool public poolInitialized;

    /// @notice Token ID of the passive liquidity position minted during initialisation.
    uint256 public passiveTokenId;

    /// @notice Data from the most recently executed swap.
    LastSwapInfo public lastSwap;

    /// @notice Reverted when initializePool is called on an already-initialised simulator.
    error PoolAlreadyInitialized();

    /// @notice Reverted when initializePool is called with zero initial liquidity.
    error ZeroLiquidity();

    /// @notice Reverted when executeSwap is called before initializePool.
    error PoolNotInitialized();

    /// @notice Reverted when executeSwap is called with a zero amount.
    error ZeroSwapAmount();

    /// @notice Deploys the simulator and wires all dependencies.
    /// @dev Approves the swap router for both tokens. Attempts to initialise the pool
    ///      in the constructor so that the hook's afterInitialize runs immediately if
    ///      the pool manager is already deployed (useful in test environments).
    /// @param _poolManager The Uniswap v4 pool manager.
    /// @param _positionManager The position manager.
    /// @param _swapRouter The swap router.
    /// @param _permit2 The Permit2 contract.
    /// @param _token0 The lower-address token.
    /// @param _token1 The higher-address token.
    /// @param _flowHook The FlowScoreHook to attach.
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
            // solhint-disable-next-line no-empty-blocks
            try _poolManager.initialize(poolKey, SQRT_PRICE_1_1) {} catch {}
        }

        _token0.approve(address(_swapRouter), type(uint256).max);
        _token1.approve(address(_swapRouter), type(uint256).max);
    }

    /// @notice Mints passive liquidity and configures the imbalance scale for the pool.
    /// @dev Must be called once before any swaps. Sets up a wide-range passive LP position
    ///      (±750 tick spacings) and attempts to configure the hook's imbalance scale so
    ///      that MAX_FEE is reached at roughly 8% pool imbalance.
    /// @param initialLiquidityPerToken Token amount to provide as passive liquidity per side.
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
        // Owner-only on the hook in production; simulator setup should not fail if deployer keeps ownership.
        // solhint-disable-next-line no-empty-blocks
        try flowHook.setImbalanceScale(poolKey, initialLiquidityPerToken * 16 / 100) {} catch {}
        poolInitialized = true;
    }

    /// @notice Executes a swap and records diagnostics in lastSwap.
    /// @dev Mints fresh tokens to cover the swap plus a buffer, then executes the swap
    ///      through the router. Toxicity is inferred from observed fee-pot movement.
    /// @param zeroForOne True to swap token0 for token1; false for the reverse direction.
    /// @param amountIn Exact input amount (in the input token's units).
    /// @return info A snapshot of swap diagnostics including fee, pot delta, and output amount.
    function executeSwap(bool zeroForOne, uint256 amountIn) external returns (LastSwapInfo memory info) {
        if (!poolInitialized) revert PoolNotInitialized();
        if (amountIn == 0) revert ZeroSwapAmount();

        token0.mint(address(this), amountIn + 1e18);
        token1.mint(address(this), amountIn + 1e18);

        PoolId pid = poolKey.toId();
        (
            ,
            int256 signedFlowEmaBefore,
            int256 imbalance,
            uint256 feePot0Before,
            uint256 feePot1Before,,
            uint256 imbalanceScale,,
        ) = flowHook.flowState(pid);

        uint24 feeBps = _quoteFeeBps(imbalance, zeroForOne, amountIn, imbalanceScale);
        bool toxic = feeBps > BASE_FEE;
        uint256 feePaid = (amountIn * feeBps) / FEE_DENOMINATOR;

        uint256 amountOut = _swap(zeroForOne, amountIn);
        (, int256 signedFlowEmaAfter,,,,,,,) = flowHook.flowState(pid);
        (,,, uint256 feePot0After, uint256 feePot1After,,,,) = flowHook.flowState(pid);

        uint256 totalBefore = feePot0Before + feePot1Before;
        uint256 totalAfter = feePot0After + feePot1After;

        uint256 feePotAdded = totalAfter > totalBefore ? totalAfter - totalBefore : 0;
        uint256 feePotUsed = totalBefore > totalAfter ? totalBefore - totalAfter : 0;

        // Prefer observed pot movement as source of truth for toxicity in simulator reporting.
        if (feePotAdded > 0) {
            toxic = true;
            uint256 baseFeeAmount = (amountIn * BASE_FEE) / FEE_DENOMINATOR;
            // toxic surcharge contribution is 50% of the extra fee => extra = 2 * contribution
            feePaid = baseFeeAmount + (2 * feePotAdded);
        } else if (!toxic) {
            int256 flowAbsAfter = signedFlowEmaAfter >= 0 ? signedFlowEmaAfter : -signedFlowEmaAfter;
            int256 flowAbsBefore = signedFlowEmaBefore >= 0 ? signedFlowEmaBefore : -signedFlowEmaBefore;
            if (flowAbsAfter > flowAbsBefore && feePotAdded > 0) toxic = true;
        }

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

    /// @notice Returns a snapshot of current pool state and the last swap diagnostics.
    /// @return reserve0 Total token0 held by the pool manager.
    /// @return reserve1 Total token1 held by the pool manager.
    /// @return share0Bps token0's share of total reserves in basis points.
    /// @return share1Bps token1's share of total reserves in basis points.
    /// @return feePotBalance Combined token0 and token1 fee pot balance.
    /// @return info Diagnostics from the most recently executed swap.
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
        (,,, uint256 feePot0, uint256 feePot1,,,,) = flowHook.flowState(poolKey.toId());
        feePotBalance = feePot0 + feePot1;
        info = lastSwap;
    }

    /// @notice Mints a position via the position manager and returns the assigned token ID.
    /// @param key The pool key.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param amount0Desired Desired token0 deposit.
    /// @param amount1Desired Desired token1 deposit.
    /// @return tokenId The ERC-721 token ID assigned to the new position.
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

    /// @notice Executes an exact-input swap through the router and returns the output amount.
    /// @param zeroForOne True to swap token0 for token1.
    /// @param amountIn Input amount.
    /// @return amountOut Tokens received after the swap.
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

    /// @notice Estimates the fee in basis points for a prospective swap using only on-chain state.
    /// @param imbalance Current signed inventory imbalance of the pool.
    /// @param zeroForOne Swap direction.
    /// @param swapSize Input amount of the swap.
    /// @param scale Imbalance scale configured for the pool.
    /// @return Estimated fee in parts per million.
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

    /// @notice Rounds a tick down to the nearest multiple of TICK_SPACING.
    /// @param tick The raw tick value.
    /// @return The aligned tick.
    function _alignTick(int24 tick) internal pure returns (int24) {
        return (tick / TICK_SPACING) * TICK_SPACING;
    }
}
