// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @title FlatTimelockWithdrawalFeeHook
/// @author Petr Jeřábek
/// @notice A baseline Uniswap v4 hook that applies a flat penalty to liquidity removed
///         before a fixed block timelock has elapsed.
/// @dev This hook serves as a simple comparison benchmark for the SentinelJITGuardHook.
///      Penalised tokens (principal fraction + all accrued fees) are donated back to the pool.
/// @dev Non-production analysis contract used only for thesis benchmarks,
///      simulations, and tests. Not audited or hardened for production use.
contract FlatTimelockWithdrawalFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Metadata tracked for each open liquidity position.
    struct PositionData {
        /// @dev Block number at which this position was last deposited or topped up.
        uint48 addedAtBlock;
        /// @dev Current net liquidity tracked by the hook.
        uint128 liquidity;
        /// @dev Lifetime total liquidity added to this slot.
        uint128 cumulativeAdded;
        /// @dev Lifetime total liquidity removed from this slot.
        uint128 cumulativeRemoved;
    }

    /// @notice Basis-point denominator (10 000 = 100%).
    uint256 public constant BPS = 10_000;

    /// @notice Number of blocks that must elapse after a deposit before removal is penalty-free.
    uint256 public constant TIMELOCK_BLOCKS = 20;

    /// @notice Flat penalty applied to principal when removing before the timelock (30%).
    uint256 public constant FLAT_PENALTY_BPS = 3_000;

    /// @notice Position metadata, keyed by pool ID then position key hash.
    mapping(PoolId poolId => mapping(bytes32 posKey => PositionData)) public positions;

    /// @notice Reverted when a removal is attempted for a position that has no tracked deposit.
    error PositionNotFound();

    /// @notice Deploys the hook and wires it to the given pool manager.
    /// @param _pm The Uniswap v4 pool manager.
    constructor(IPoolManager _pm) BaseHook(_pm) {}

    /// @notice Returns the hook permission flags required by this contract.
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
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @notice Records the deposit block and liquidity amount when liquidity is added.
    /// @dev Subsequent adds to the same slot refresh addedAtBlock, resetting the timelock clock.
    /// @param sender The address that called the position manager.
    /// @param key The pool key.
    /// @param params Liquidity modification parameters (ticks, delta, salt).
    /// @param hookData Optional bytes encoding the effective owner address.
    /// @return selector The afterAddLiquidity selector.
    /// @return hookDelta Zero delta (this hook does not redirect tokens on add).
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

        if (p.liquidity > 0) {
            p.liquidity += addedLiq;
            p.cumulativeAdded += addedLiq;
            p.addedAtBlock = uint48(block.number);
        } else {
            p.addedAtBlock = uint48(block.number);
            p.liquidity = addedLiq;
            p.cumulativeAdded = addedLiq;
        }

        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Applies a flat penalty when liquidity is removed before the timelock expires.
    /// @dev The penalty (FLAT_PENALTY_BPS of principal plus all accrued fees) is donated back
    ///      to the pool. No penalty is applied once TIMELOCK_BLOCKS have elapsed since the deposit.
    ///      The position slot is deleted when all tracked liquidity is removed.
    /// @param sender The address that triggered the removal.
    /// @param key The pool key.
    /// @param params Liquidity modification parameters.
    /// @param delta Actual token deltas from the core removal (principal + fees).
    /// @param feesAccrued The fees component of delta.
    /// @param hookData Optional bytes encoding the effective owner address.
    /// @return selector The afterRemoveLiquidity selector.
    /// @return hookDelta Positive amounts represent tokens redirected away from the LP (penalty).
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

        uint256 age = block.number - p.addedAtBlock;
        uint256 penaltyBps = age < TIMELOCK_BLOCKS ? FLAT_PENALTY_BPS : 0;

        p.cumulativeRemoved += removedLiq;
        p.liquidity = removedLiq >= p.liquidity ? 0 : p.liquidity - removedLiq;
        if (p.liquidity == 0) delete positions[pid][posKey];

        if (penaltyBps == 0) {
            return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        int128 fees0 = feesAccrued.amount0();
        int128 fees1 = feesAccrued.amount1();
        int128 principal0 = delta.amount0() - fees0;
        int128 principal1 = delta.amount1() - fees1;

        int128 penalty0 = principal0 > 0 ? int128(int256(uint256(uint128(principal0)) * penaltyBps / BPS)) : int128(0);
        int128 penalty1 = principal1 > 0 ? int128(int256(uint256(uint128(principal1)) * penaltyBps / BPS)) : int128(0);

        if (fees0 > 0) penalty0 += fees0;
        if (fees1 > 0) penalty1 += fees1;

        if (penalty0 > 0 || penalty1 > 0) {
            poolManager.donate(key, uint256(uint128(penalty0)), uint256(uint128(penalty1)), "");
        }

        return (BaseHook.afterRemoveLiquidity.selector, toBalanceDelta(penalty0, penalty1));
    }

    /// @notice Derives a unique position key from owner, tick range, and salt.
    /// @param owner The effective owner address of the position.
    /// @param tickLower The lower tick of the position range.
    /// @param tickUpper The upper tick of the position range.
    /// @param salt Arbitrary salt encoded in the position NFT (token ID as bytes32).
    /// @return A keccak256 hash uniquely identifying the position slot.
    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

    /// @notice Resolves the effective position owner from optional hookData.
    /// @dev Decodes a 32-byte ABI-encoded address or a raw 20-byte address; falls back to sender.
    /// @param sender The msg.sender forwarded by the pool manager.
    /// @param hookData Optional bytes that may encode the real owner address.
    /// @return The effective owner address.
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
}
