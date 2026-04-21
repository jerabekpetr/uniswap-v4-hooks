// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook}              from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks}                 from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager}          from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}               from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta}
                               from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract SentinelJITGuardHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint16 public constant DEPOSITED_LIQUIDITY_PENALTY = 3000;  // 30% now, can be adjusted based on how harsh we want the penalty to be 
    uint16 public constant FEES_PENALTY = 10_000; // 100% of fees accrued as penalty, can be adjusted
    uint16 public constant PENALTY_DIVISOR       = 10_000; // 100% = 10_000

    event LiquidityTracked(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        uint48  depositBlock,
        uint128 liquidity
    );

    event JITPenaltyApplied(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address indexed sender,
        int128 penalty0,
        int128 penalty1
    );

    error PositionNotFound();

    struct PositionData {
        uint48  depositBlock;
        uint128 liquidity;
    }

    mapping(PoolId => mapping(bytes32 => PositionData)) public positions;

    function _positionKey(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            sender, tickLower, tickUpper, salt
        ));
    }

    constructor(IPoolManager _pm) BaseHook(_pm) {}

    function getHookPermissions() public pure override 
        returns (Hooks.Permissions memory) 
    {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 false,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               true,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            true,
            beforeSwap:                      false,
            afterSwap:                       false,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /////////////////////////
    // CALLBACKS
    /////////////////////////
    

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta, // delta - not interested for this callback
        BalanceDelta, // feesAccrued - not interested for this callback
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = _positionKey(
            sender,
            params.tickLower,
            params.tickUpper,
            params.salt
        );

        PositionData storage p = positions[key.toId()][positionKey];
        p.depositBlock = uint48(block.number);
        if (params.liquidityDelta > 0) {
            p.liquidity = uint128(uint256(params.liquidityDelta));
        }   else {
            p.liquidity = 0;
        }

        emit LiquidityTracked(
            key.toId(),
            positionKey,
            sender,
            p.depositBlock,
            p.liquidity
        );

        return (
            BaseHook.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }



    
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta, // amount of liquidity removed in this call, including fees and hook deltas
        BalanceDelta feesAccrued, // fees accrued since last time fees were collected from this position
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        bytes32 positionKey = _positionKey(
            sender,
            params.tickLower,
            params.tickUpper,
            params.salt
        );

        PoolId pid = key.toId();
        PositionData storage p = positions[pid][positionKey];

        if (p.depositBlock == 0) revert PositionNotFound(); // Detection if hook knows caller`s position

        // JIT detection
        if (block.number == p.depositBlock) {
            // PENALIZATION METHOD
            // Penalize the user by donating FEES_PENALTY% fees accrued + DEPOSITED_LIQUIDITY_PENALTY% of the withdrawn liquidity
            int128 fees0 = feesAccrued.amount0();
            int128 fees1 = feesAccrued.amount1();

            // All their deposited liquidity they are withdrawing, without the fees
            int128 depositedLiq0 = delta.amount0() - fees0;
            int128 depositedLiq1 = delta.amount1() - fees1;

            int128 feesPenalty0 = fees0 * int16(FEES_PENALTY) / int16(PENALTY_DIVISOR);
            int128 feesPenalty1 = fees1 * int16(FEES_PENALTY) / int16(PENALTY_DIVISOR);

            int128 depositedLiqPenalty0 = depositedLiq0 * int16(DEPOSITED_LIQUIDITY_PENALTY) / int16(PENALTY_DIVISOR);
            int128 depositedLiqPenalty1 = depositedLiq1 * int16(DEPOSITED_LIQUIDITY_PENALTY) / int16(PENALTY_DIVISOR);

            int128 penalty0 = feesPenalty0 + depositedLiqPenalty0;
            int128 penalty1 = feesPenalty1 + depositedLiqPenalty1;

            poolManager.donate(
                key,
                uint256(uint128(penalty0)),
                uint256(uint128(penalty1)),
                ""
            );
            delete positions[pid][positionKey];

            emit JITPenaltyApplied(
                pid,
                positionKey,
                sender,
                penalty0,
                penalty1
            );

            return (
                BaseHook.afterRemoveLiquidity.selector,
                toBalanceDelta(penalty0, penalty1) // Debt of the attacker to the PoolManager
            );
        }
        delete positions[pid][positionKey];

        return (
            BaseHook.afterRemoveLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA // Not an attack, no delta from the hook
        );
    }
}