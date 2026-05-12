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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title SentinelSimulator
/// @author Petr Jeřábek
/// @notice Testing and simulation harness for the SentinelJITGuardHook.
/// @dev Maintains two identical pools — one with the hook attached and one without —
///      so that JIT attack scenarios can be compared side-by-side. Intended for use
///      in Foundry tests and deployment scripts only — not production code.
/// @dev Non-production analysis contract used only for thesis benchmarks,
///      simulations, and tests. Not audited or hardened for production use.
contract SentinelSimulator {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using TickMath for int24;
    using LiquidityAmounts for uint160;
    using Actions for IPositionManager;
    using FullMath for uint256;

    /// @notice Outcome of a single runScenario call.
    struct ScenarioResult {
        /// @dev Net token0 gain/loss for the passive LP (fees earned, expressed as signed delta).
        int256 passiveLPDelta0;
        /// @dev Net token1 gain/loss for the passive LP.
        int256 passiveLPDelta1;
        /// @dev Net token0 gain/loss for the JIT attacker (returned minus spent).
        int256 jitDelta0;
        /// @dev Net token1 gain/loss for the JIT attacker.
        int256 jitDelta1;
        /// @dev Amount of token1 received by the swap.
        uint256 swapAmountOut;
    }

    /// @notice Fee tier used for both simulated pools (0.30%).
    uint24 public constant FEE = 3000;

    /// @notice Tick spacing used for both simulated pools.
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

    /// @notice The SentinelJITGuardHook instance being tested.
    IHooks public immutable sentinelHook;

    /// @notice Pool key for the pool that has the sentinel hook attached.
    PoolKey public poolWithHookKey;

    /// @notice Pool key for the baseline pool with no hook.
    PoolKey public poolNoHookKey;

    /// @notice Deploys the simulator and initialises both pools.
    /// @dev Attempts to initialise both pools in the constructor so they are ready
    ///      immediately when the pool manager is already deployed (useful in test envs).
    /// @param _poolManager The Uniswap v4 pool manager.
    /// @param _positionManager The position manager.
    /// @param _swapRouter The swap router.
    /// @param _permit2 The Permit2 contract.
    /// @param _token0 The lower-address token.
    /// @param _token1 The higher-address token.
    /// @param _sentinelHook The SentinelJITGuardHook to attach to the hooked pool.
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

        poolWithHookKey =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: _sentinelHook});
        poolNoHookKey =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))});

        if (address(poolManager).code.length > 0) {
            // solhint-disable-next-line no-empty-blocks
            try _poolManager.initialize(poolWithHookKey, SQRT_PRICE_1_1) {} catch {}
            // solhint-disable-next-line no-empty-blocks
            try _poolManager.initialize(poolNoHookKey, SQRT_PRICE_1_1) {} catch {}
        }

        // _token0.approve(address(_permit2), type(uint256).max);
        // _token1.approve(address(_permit2), type(uint256).max);
        _token0.approve(address(_swapRouter), type(uint256).max);
        _token1.approve(address(_swapRouter), type(uint256).max);
        // _permit2.approve(address(_token0), address(_positionManager), type(uint160).max, type(uint48).max);
        // _permit2.approve(address(_token1), address(_positionManager), type(uint160).max, type(uint48).max);
    }

    /// @notice Runs a complete JIT attack scenario and returns the outcome for all participants.
    /// @dev Mints tokens, optionally seeds passive liquidity, optionally executes a JIT add
    ///      immediately before the swap and a JIT remove immediately after, then measures
    ///      passive LP fee earnings and JIT P&L.
    /// @param passiveToken0 Token0 amount for the wide-range passive LP position.
    /// @param passiveToken1 Token1 amount for the wide-range passive LP position.
    /// @param jitToken0 Token0 amount for the narrow JIT position.
    /// @param jitToken1 Token1 amount for the narrow JIT position.
    /// @param swapAmountIn Token0 input amount for the simulated swap.
    /// @param useHook True to run the scenario against the hooked pool; false for the baseline pool.
    /// @param useJIT True to include a JIT add/remove sandwich around the swap.
    /// @return result Deltas for the passive LP and JIT attacker, plus swap output.
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
            (result.passiveLPDelta0, result.passiveLPDelta1) =
                _computePassiveFees(poolId, passiveLower, passiveUpper, passiveTokenId);
        }
    }

    /// @notice Returns the pool ID for the pool that has the sentinel hook attached.
    /// @return The PoolId of the hooked pool.
    function poolWithHookId() external view returns (PoolId) {
        return poolWithHookKey.toId();
    }

    /// @notice Returns the pool ID for the baseline pool with no hook.
    /// @return The PoolId of the hook-free pool.
    function poolNoHookId() external view returns (PoolId) {
        return poolNoHookKey.toId();
    }

    ////////////////// Helper functions /////////////////

    /// @notice Mints a position via the position manager and returns the assigned token ID.
    /// @param poolKey The pool key.
    /// @param tickLower Lower tick of the range.
    /// @param tickUpper Upper tick of the range.
    /// @param amount0Desired Desired token0 deposit.
    /// @param amount1Desired Desired token1 deposit.
    /// @return tokenId The ERC-721 token ID assigned to the new position.
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

    /// @notice Burns a position NFT and collects all tokens via TAKE_PAIR.
    /// @param tokenId The ERC-721 token ID to burn.
    function _decreaseLiquidity(uint256 tokenId) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint256(0), bytes(""));
        params[1] = abi.encode(poolWithHookKey.currency0, poolWithHookKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    /// @notice Executes an exact-input zeroForOne swap through the router and returns the output amount.
    /// @param poolKey The pool to swap in.
    /// @param amountIn Token0 input amount.
    /// @return amountOut Token1 received after the swap.
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

    /// @notice Computes the fee growth accrued to a passive LP position since it was opened.
    /// @param poolId The pool identifier.
    /// @param tickLower Lower tick of the position range.
    /// @param tickUpper Upper tick of the position range.
    /// @param tokenId The ERC-721 token ID (used as salt for the position key).
    /// @return fees0 Token0 fees accrued.
    /// @return fees1 Token1 fees accrued.
    function _computePassiveFees(PoolId poolId, int24 tickLower, int24 tickUpper, uint256 tokenId)
        internal
        view
        returns (int256 fees0, int256 fees1)
    {
        bytes32 salt = bytes32(tokenId);
        (uint128 liquidity, uint256 feeGrowthInside0Last, uint256 feeGrowthInside1Last) =
            poolManager.getPositionInfo(poolId, address(positionManager), tickLower, tickUpper, salt);
        (uint256 feeGrowthInside0Now, uint256 feeGrowthInside1Now) =
            poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);

        uint256 delta0 = feeGrowthInside0Now >= feeGrowthInside0Last ? feeGrowthInside0Now - feeGrowthInside0Last : 0;
        uint256 delta1 = feeGrowthInside1Now >= feeGrowthInside1Last ? feeGrowthInside1Now - feeGrowthInside1Last : 0;

        fees0 = int256(FullMath.mulDiv(delta0, liquidity, 1 << 128));
        fees1 = int256(FullMath.mulDiv(delta1, liquidity, 1 << 128));
    }

    /// @notice Rounds a tick down to the nearest multiple of TICK_SPACING.
    /// @param tick The raw tick value.
    /// @return The aligned tick.
    function _alignTick(int24 tick) internal pure returns (int24) {
        return (tick / TICK_SPACING) * TICK_SPACING;
    }
}
