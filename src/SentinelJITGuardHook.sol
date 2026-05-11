// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract SentinelJITGuardHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    uint256 public constant BPS = 10_000;
    uint256 public constant BASE_PENALTY_BPS = 3_000; // 30% base penalty on deposited liquidity
    uint256 public constant MAX_PENALTY_BPS = 3_000; // max from the age/width/distance factors
    uint256 public constant GRACE_BLOCKS = 20; // no penalty after this many blocks
    uint256 public constant REFERENCE_WIDTH_TICKS = 600; // tight-range threshold
    uint256 public constant ACTIVE_DISTANCE_TICKS = 600; // out-of-range penalty decay threshold
    uint256 public constant MAX_VOL_BOOST_BPS = 5_000; // up to +50% additional penalty from volatility
    uint256 public constant VOL_SCALE = 100; // sigma (in ticks) at which vol boost reaches MAX_VOL_BOOST_BPS

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event LiquidityTracked(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        uint48 addedAtBlock,
        uint128 liquidity
    );

    event JITPenaltyApplied(
        PoolId indexed poolId, bytes32 indexed positionKey, address indexed sender, int128 penalty0, int128 penalty1
    );

    // Emitted whenever a penalty is computed, with context to audit the decision.
    event PenaltyDecision(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        uint256 penaltyBps,
        uint256 positionAgeBlocks,
        int24 rangeWidth,
        int24 activeTickDistance
    );

    // Emitted after each swap when volatility state is updated.
    event VolatilityUpdated(PoolId indexed poolId, uint256 sigmaX18, int24 lastTick);

    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────

    error PositionNotFound();

    // ─────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────

    // extended PositionData with tick range stored on add.
    struct PositionData {
        uint48 addedAtBlock;
        int24 tickLower;
        int24 tickUpper;
        int24 entryTick;
        uint128 liquidity;
        uint128 cumulativeAdded;
        uint128 cumulativeRemoved;
    }

    // per-pool rolling volatility estimate.
    struct PoolVolatilityState {
        bool initialized;
        int24 lastTick;
        uint256 sigmaX18; // EMA of absolute tick-move per swap, scaled by 1e18
        uint256 lastUpdatedBlock;
    }

    mapping(PoolId => mapping(bytes32 => PositionData)) public positions;
    mapping(PoolId => PoolVolatilityState) public volatility;

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    /// @notice Derives a unique position key from owner, tick range, and salt.
    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    /// @notice resolves the effective position owner from hookData.
    /// Decodes a 32-byte ABI-encoded address or a raw 20-byte address; falls back to sender.
    function _effectiveOwner(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length >= 32) return abi.decode(hookData, (address));
        if (hookData.length >= 20) {
            address a;
            assembly {
                a := shr(96, calldataload(hookData.offset))
            }
            return a;
        }
        return sender;
    }

    // ─────────────────────────────────────────────
    // Constructor / permissions
    // ─────────────────────────────────────────────

    constructor(IPoolManager _pm) BaseHook(_pm) {}

    /// @notice Returns the set of hook callbacks this hook uses.
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

    /// @notice Records deposit block, tick range, and liquidity for a position.
    /// Refreshes addedAtBlock and entryTick on subsequent adds to the same slot.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        address owner = _effectiveOwner(sender, hookData);
        bytes32 posKey = _positionKey(owner, params.tickLower, params.tickUpper, params.salt);

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

        emit LiquidityTracked(pid, posKey, owner, p.addedAtBlock, p.liquidity);
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Applies an adaptive penalty when liquidity is removed shortly after deposit.
    /// Penalty decays with age, range width, out-of-range distance, and a volatility boost.
    /// Penalty tokens are donated back to the pool.
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        address owner = _effectiveOwner(sender, hookData);
        bytes32 posKey = _positionKey(owner, params.tickLower, params.tickUpper, params.salt);

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

            // Combine: base penalty modulated by all three factors, plus uncapped volatility boost.
            penaltyBps = BASE_PENALTY_BPS * ageFactorBps / BPS;
            penaltyBps = penaltyBps * widthFactorBps / BPS;
            penaltyBps = penaltyBps * activeFactorBps / BPS;
            penaltyBps += volBoostBps;
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

        emit JITPenaltyApplied(pid, posKey, owner, penalty0, penalty1);

        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(penalty0, penalty1));
    }

    /// @notice updates the per-pool rolling volatility estimate after each swap.
    /// sigma is an EMA of absolute tick-moves (80/20 decay), scaled by 1e18.
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
