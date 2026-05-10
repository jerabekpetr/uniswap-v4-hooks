// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract FlatTimelockWithdrawalFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint256 public constant BPS = 10_000;
    uint256 public constant TIMELOCK_BLOCKS = 20;
    uint256 public constant FLAT_PENALTY_BPS = 3_000;

    struct PositionData {
        uint48 addedAtBlock;
        uint128 liquidity;
        uint128 cumulativeAdded;
        uint128 cumulativeRemoved;
    }

    mapping(PoolId => mapping(bytes32 => PositionData)) public positions;

    error PositionNotFound();

    constructor(IPoolManager _pm) BaseHook(_pm) {}

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

    function _positionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
    }

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
}
