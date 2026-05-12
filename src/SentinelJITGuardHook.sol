// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";

/// @title SentinelJITGuardHook
/// @author Petr Jeřábek
/// @notice A Uniswap v4 hook that deters just-in-time (JIT) liquidity attacks by applying
///         an adaptive penalty when liquidity is removed shortly after being deposited.
/// @dev The penalty is a function of position age (blocks held), tick range width,
///      out-of-range distance, and a rolling per-pool volatility estimate.
///      Penalised tokens are donated back to the pool, benefiting passive LPs.
contract SentinelJITGuardHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────

    /// @notice Metadata tracked for each open liquidity position.
    struct PositionData {
        /// @dev Block number at which this position slot was last opened or topped up.
        uint48 addedAtBlock;
        /// @dev Lower tick of the position range.
        int24 tickLower;
        /// @dev Upper tick of the position range.
        int24 tickUpper;
        /// @dev Pool tick at the time of the most recent deposit.
        int24 entryTick;
        /// @dev Current net liquidity tracked by the hook.
        uint128 liquidity;
        /// @dev Lifetime total liquidity added to this slot.
        uint128 cumulativeAdded;
        /// @dev Lifetime total liquidity removed from this slot.
        uint128 cumulativeRemoved;
    }

    /// @notice Rolling volatility state maintained per pool.
    struct PoolVolatilityState {
        /// @dev True once the first swap has been observed.
        bool initialized;
        /// @dev Tick recorded after the most recent swap, used to compute the next absolute move.
        int24 lastTick;
        /// @dev EMA of absolute tick-move per swap, scaled by 1e18 (80/20 decay).
        uint256 sigmaX18;
        /// @dev Block number of the last volatility update.
        uint256 lastUpdatedBlock;
    }

    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    /// @notice Basis-point denominator (10 000 = 100%).
    uint256 public constant BPS = 10_000;

    /// @notice Base penalty applied to principal at block 0 before other factors (30%).
    uint256 public constant BASE_PENALTY_BPS = 3_000;

    /// @notice Hard global cap on the total penalty, including the volatility boost (30%).
    ///         No removal can be penalised beyond this fraction of principal, regardless of market conditions.
    uint256 public constant MAX_PENALTY_BPS = 3_000;

    /// @notice Number of blocks after which no penalty is applied.
    uint256 public constant GRACE_BLOCKS = 20;

    /// @notice Tick-range width at or below which the width factor is at its maximum.
    uint256 public constant REFERENCE_WIDTH_TICKS = 600;

    /// @notice Out-of-range distance in ticks beyond which the active-distance factor is zero.
    uint256 public constant ACTIVE_DISTANCE_TICKS = 600;

    /// @notice Maximum additional penalty from the volatility boost (50%).
    uint256 public constant MAX_VOL_BOOST_BPS = 5_000;

    /// @notice Rolling-sigma value (in ticks, scaled by 1e18) at which the vol boost is maximised.
    uint256 public constant VOL_SCALE = 100;

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    /// @notice Position metadata, keyed by pool ID then position key hash.
    mapping(PoolId poolId => mapping(bytes32 posKey => PositionData)) public positions;

    /// @notice Per-pool rolling volatility state.
    mapping(PoolId poolId => PoolVolatilityState state) public volatility;

    /// @notice Emitted when liquidity is added and a position slot is created or updated.
    /// @param poolId The pool in which liquidity was added.
    /// @param positionKey Hash identifying the position (owner, ticks, salt).
    /// @param sender The address that triggered the add.
    /// @param addedAtBlock Block number recorded as the deposit timestamp.
    /// @param liquidity Current tracked liquidity for this position slot.
    event LiquidityTracked(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        uint48 addedAtBlock,
        uint128 liquidity
    );

    /// @notice Emitted when a JIT penalty is applied to a removal.
    /// @param poolId The pool in which the removal occurred.
    /// @param positionKey Hash identifying the position.
    /// @param sender The effective owner of the position.
    /// @param penalty0 Token0 amount penalised.
    /// @param penalty1 Token1 amount penalised.
    event JITPenaltyApplied(
        PoolId indexed poolId, bytes32 indexed positionKey, address indexed sender, int128 penalty0, int128 penalty1
    );

    /// @notice Emitted whenever a penalty is computed, providing audit context for the decision.
    /// @param poolId The pool in which the removal occurred.
    /// @param positionKey Hash identifying the position.
    /// @param penaltyBps The total penalty in basis points.
    /// @param positionAgeBlocks Number of blocks the position was held.
    /// @param rangeWidth Tick range width of the position.
    /// @param activeTickDistance Distance from the current tick to the nearest range boundary (zero if in-range).
    event PenaltyDecision(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        uint256 penaltyBps,
        uint256 positionAgeBlocks,
        int24 rangeWidth,
        int24 activeTickDistance
    );

    /// @notice Emitted after each swap when the per-pool volatility state is updated.
    /// @param poolId The pool whose volatility was updated.
    /// @param sigmaX18 The updated EMA sigma value, scaled by 1e18.
    /// @param lastTick The current tick recorded for the next sigma calculation.
    event VolatilityUpdated(PoolId indexed poolId, uint256 sigmaX18, int24 lastTick);

    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────

    /// @notice Reverted when a removal is attempted for a position that has no tracked deposit.
    error PositionNotFound();

    // ─────────────────────────────────────────────
    // Constructor / permissions
    // ─────────────────────────────────────────────

    /// @notice Deploys the hook and wires it to the given pool manager.
    /// @param _pm The Uniswap v4 pool manager.
    constructor(IPoolManager _pm) BaseHook(_pm) {}

    /// @notice Returns the set of hook callbacks this hook uses.
    /// @return permissions Struct indicating which hook callbacks are active.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true, // volatility estimator
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // ─────────────────────────────────────────────
    // Callbacks
    // ─────────────────────────────────────────────

    /// @notice Records the deposit block, tick range, and liquidity for a position.
    /// @dev Refreshes addedAtBlock and entryTick on subsequent adds to the same slot,
    ///      effectively resetting the JIT clock. Position identity uses the v4-canonical key
    ///      derived from (sender, tickLower, tickUpper, salt); hookData is ignored for accounting.
    /// @param sender The address that called the position manager.
    /// @param key The pool key.
    /// @param params Liquidity modification parameters (ticks, delta, salt).
    /// @return selector The afterAddLiquidity selector.
    /// @return hookDelta Zero delta (this hook does not redirect tokens on add).
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 posKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId pid = key.toId();
        PositionData storage p = positions[pid][posKey];

        uint128 addedLiq = params.liquidityDelta > 0 ? uint128(uint256(params.liquidityDelta)) : 0;
        (, int24 currentTick,,) = poolManager.getSlot0(pid);

        if (p.liquidity > 0) {
            // Existing slot: accumulate and refresh the age clock.
            p.liquidity += addedLiq;
            p.cumulativeAdded += addedLiq;
            p.addedAtBlock = uint48(block.number);
            p.entryTick = currentTick;
        } else {
            // Fresh slot: initialise all fields.
            p.addedAtBlock = uint48(block.number);
            p.tickLower = params.tickLower;
            p.tickUpper = params.tickUpper;
            p.entryTick = currentTick;
            p.liquidity = addedLiq;
            p.cumulativeAdded = addedLiq;
            p.cumulativeRemoved = 0;
        }

        emit LiquidityTracked(pid, posKey, sender, p.addedAtBlock, p.liquidity);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Applies an adaptive penalty when liquidity is removed within the grace period.
    /// @dev Penalty factors: age (linear decay over GRACE_BLOCKS), width (narrow = higher penalty),
    ///      active-distance (in-range = higher penalty), and a volatility multiplier.
    ///      The three base factors are combined first, then scaled up by the volatility boost
    ///      (implemented as a multiplicative factor rather than an additive term), and finally
    ///      hard-capped at MAX_PENALTY_BPS. MAX_PENALTY_BPS is a global ceiling that includes
    ///      the volatility contribution — no single removal can exceed this fraction of principal.
    ///      The penalty is applied to the principal only; accrued fees are also fully penalised
    ///      when a penalty is active. All penalised tokens are donated back to the pool.
    ///      Position identity uses the v4-canonical key derived from (sender, tickLower, tickUpper, salt);
    ///      hookData is ignored for accounting, preventing forged-owner attacks.
    /// @param sender The address that triggered the removal.
    /// @param key The pool key.
    /// @param params Liquidity modification parameters.
    /// @param delta Actual token deltas from the core removal (principal + fees).
    /// @param feesAccrued The fees component of delta.
    /// @return selector The afterRemoveLiquidity selector.
    /// @return hookDelta Positive amounts represent tokens redirected away from the LP (penalty).
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 posKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        PoolId pid = key.toId();
        PositionData storage p = positions[pid][posKey];

        if (p.addedAtBlock == 0) revert PositionNotFound();

        uint128 removedLiq = params.liquidityDelta < 0 ? uint128(uint256(-params.liquidityDelta)) : 0;

        // Gather metadata for the PenaltyDecision event and adaptive formula.
        (, int24 currentTick,,) = poolManager.getSlot0(pid);
        int24 rangeWidth = params.tickUpper - params.tickLower;
        int24 activeTickDistance;
        if (currentTick >= params.tickLower && currentTick <= params.tickUpper) {
            activeTickDistance = 0;
        } else if (currentTick < params.tickLower) {
            activeTickDistance = params.tickLower - currentTick;
        } else {
            activeTickDistance = currentTick - params.tickUpper;
        }

        // multi-factor adaptive penalty.
        uint256 ageBlocks = block.number - p.addedAtBlock;
        uint256 penaltyBps = 0;

        if (ageBlocks < GRACE_BLOCKS) {
            // Age factor: 100% at block 0, linearly to 0% at GRACE_BLOCKS.
            uint256 ageFactorBps = (GRACE_BLOCKS - ageBlocks) * BPS / GRACE_BLOCKS;

            // Width factor: narrow positions (≤ REFERENCE_WIDTH_TICKS) receive full penalty;
            // wider positions have a proportionally reduced penalty.
            uint256 rangeWidthU = uint256(uint24(rangeWidth));
            uint256 widthFactorBps =
                rangeWidthU <= REFERENCE_WIDTH_TICKS ? BPS : (REFERENCE_WIDTH_TICKS * BPS / rangeWidthU);

            // Active distance factor: in-range positions receive full penalty;
            // positions more than ACTIVE_DISTANCE_TICKS out-of-range receive no penalty.
            uint256 activeDistU = uint256(uint24(activeTickDistance));
            uint256 activeFactorBps = activeDistU >= ACTIVE_DISTANCE_TICKS
                ? 0
                : ((ACTIVE_DISTANCE_TICKS - activeDistU) * BPS / ACTIVE_DISTANCE_TICKS);

            // Volatility boost: higher market volatility → higher penalty.
            PoolVolatilityState storage vol = volatility[pid];
            uint256 volBoostBps = vol.sigmaX18 >= VOL_SCALE * 1e18
                ? MAX_VOL_BOOST_BPS
                : (vol.sigmaX18 * MAX_VOL_BOOST_BPS / (VOL_SCALE * 1e18));

            // Combine: base penalty modulated by all three factors, then scaled up by the volatility
            // boost (multiplicative), and capped at MAX_PENALTY_BPS.
            penaltyBps = BASE_PENALTY_BPS * ageFactorBps / BPS;
            penaltyBps = penaltyBps * widthFactorBps / BPS;
            penaltyBps = penaltyBps * activeFactorBps / BPS;
            penaltyBps = penaltyBps * (BPS + volBoostBps) / BPS;
            if (penaltyBps > MAX_PENALTY_BPS) penaltyBps = MAX_PENALTY_BPS;
        }

        emit PenaltyDecision(pid, posKey, penaltyBps, ageBlocks, rangeWidth, activeTickDistance);

        // Update tracking; clean up metadata when position is fully withdrawn.
        p.cumulativeRemoved += removedLiq;
        p.liquidity = removedLiq >= p.liquidity ? 0 : p.liquidity - removedLiq;
        if (p.liquidity == 0) delete positions[pid][posKey];

        if (penaltyBps == 0) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Penalty is applied to principal (excluding accrued fees); fees are taken in full.
        int128 fees0 = feesAccrued.amount0();
        int128 fees1 = feesAccrued.amount1();
        int128 principal0 = delta.amount0() - fees0;
        int128 principal1 = delta.amount1() - fees1;

        int128 penalty0 = principal0 > 0 ? int128(int256(uint256(uint128(principal0)) * penaltyBps / BPS)) : int128(0);
        int128 penalty1 = principal1 > 0 ? int128(int256(uint256(uint128(principal1)) * penaltyBps / BPS)) : int128(0);

        // 100% of accrued fees are also penalised.
        if (fees0 > 0) penalty0 += fees0;
        if (fees1 > 0) penalty1 += fees1;

        if (penalty0 > 0 || penalty1 > 0) {
            poolManager.donate(key, uint256(uint128(penalty0)), uint256(uint128(penalty1)), "");
        }

        emit JITPenaltyApplied(pid, posKey, sender, penalty0, penalty1);

        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(penalty0, penalty1));
    }

    /// @notice Updates the per-pool rolling volatility estimate after each swap.
    /// @dev sigma is an EMA of absolute tick-moves with an 80/20 decay, scaled by 1e18.
    ///      The first swap initialises the state without contributing a move sample.
    /// @param key The pool key.
    /// @return selector The afterSwap selector.
    /// @return hookDelta Zero (this hook does not redirect tokens on swaps).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId pid = key.toId();
        PoolVolatilityState storage vol = volatility[pid];
        (, int24 currentTick,,) = poolManager.getSlot0(pid);

        if (!vol.initialized) {
            vol.initialized = true;
            vol.lastTick = currentTick;
            vol.sigmaX18 = 0;
            vol.lastUpdatedBlock = block.number;
        } else {
            int256 tickDiff = int256(currentTick) - int256(vol.lastTick);
            uint256 absMove = tickDiff < 0 ? uint256(-tickDiff) : uint256(tickDiff);
            vol.sigmaX18 = (80 * vol.sigmaX18 + 20 * absMove * 1e18) / 100;
            vol.lastTick = currentTick;
            vol.lastUpdatedBlock = block.number;
        }

        emit VolatilityUpdated(pid, vol.sigmaX18, currentTick);
        return (BaseHook.afterSwap.selector, 0);
    }

}
