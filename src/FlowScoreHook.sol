// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook}              from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks}                 from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager}          from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}               from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams}            from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary}          from "v4-core/src/libraries/LPFeeLibrary.sol";

contract FlowScoreHook is BaseHook {
    constructor(IPoolManager _pm) BaseHook(_pm) {}

    uint24 public constant DYNAMIC_FEE_FLAG  = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 public constant BASE_FEE          = 3000; // 0.30%
    uint24 public constant MAX_FEE           = 10000; // 1.00%
    uint24 public constant MIN_FEE           = 500; // 0.05%
    uint256 public constant EMA_ALPHA        = 20; // 20%
    uint256 public constant EMA_DENOMINATOR  = 100; // 100%
    uint24 public constant FEE_POT_CONTRIBUTION_BPS = 7000; // 70% z příplatku jde do feePot
    uint24 public constant MAX_CASHBACK_BPS          = 1000; // max 0.10% cashback
    uint24 public constant BPS_DENOMINATOR           = 10000;

    struct PoolFlowState {
        uint256 emaPrice; // klouzavý průměr ceny
        int256  inventoryImbalance; // kladné = přebytek token0
        uint256 feePot; // nasbírané příplatky
        uint256 lastUpdated; // timestamp posledního swapu
    }

    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    mapping(PoolId => PoolFlowState) public flowState;
    mapping(PoolId => uint256) public pendingContribution;




    function getHookPermissions() public pure override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 true,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               false,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            false,
            beforeSwap:                      true,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            true,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }


    /////////////////////////
    // CALLBACKS
    /////////////////////////

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24
    ) internal override returns (bytes4) {
        PoolId pid = key.toId();
        
        uint256 price = _sqrtPriceToPrice(sqrtPriceX96);
        
        flowState[pid] = PoolFlowState({
            emaPrice: price,
            inventoryImbalance: 0,
            feePot: 0,
            lastUpdated: block.timestamp
        });

        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = key.toId();
        PoolFlowState storage state = flowState[pid];

        uint256 toxicity = _computeToxicity(state, params);

        // Interpoluj fee mezi MIN_FEE a MAX_FEE podle toxicity
        uint24 fee = uint24(MIN_FEE+(toxicity*(MAX_FEE - MIN_FEE)) /100);

        if (fee > BASE_FEE) {
            uint256 swapSize;
            if (params.amountSpecified < 0) {
                swapSize = uint256(-params.amountSpecified);
            } else {
                swapSize = uint256(params.amountSpecified);
            }
            uint256 extraFee = fee - BASE_FEE;
            uint256 contribution = (swapSize * extraFee * FEE_POT_CONTRIBUTION_BPS) / (BPS_DENOMINATOR * BPS_DENOMINATOR);
            pendingContribution[pid] = contribution;
        } else {
            pendingContribution[pid] = 0;
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId pid = key.toId();
        PoolFlowState storage state = flowState[pid];

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        uint256 newPrice;
        if (amount0 != 0) {
            uint256 abs0 = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
            uint256 abs1 = amount1 < 0 ? uint256(uint128(-amount1)) : uint256(uint128(amount1));
            newPrice = (abs1 * 1e18) / (abs0 + 1);
        } else {
            newPrice = state.emaPrice;
        }

        state.emaPrice = (EMA_ALPHA * newPrice + (EMA_DENOMINATOR - EMA_ALPHA) * state.emaPrice) / EMA_DENOMINATOR;

        if (params.zeroForOne) {
            state.inventoryImbalance += int256(uint256(uint128(amount0 < 0 ? -amount0 : amount0)));
        } else {
            state.inventoryImbalance -= int256(uint256(uint128(amount1 < 0 ? -amount1 : amount1)));
        }

        state.lastUpdated = block.timestamp;

        // Toxic swap
        uint256 contribution = pendingContribution[pid];
        if (contribution > 0) {
            state.feePot += contribution;
            pendingContribution[pid] = 0;
            return (BaseHook.afterSwap.selector, 0);
        }

        // Benign swap
        if (state.feePot > 0) {
            uint256 swapSize;
            if (params.amountSpecified < 0) {
                swapSize = uint256(-params.amountSpecified);
            } else {
                swapSize = uint256(params.amountSpecified);
            }
            uint256 cashback = (swapSize * MAX_CASHBACK_BPS) / BPS_DENOMINATOR;

            if (cashback > state.feePot) {
                cashback = state.feePot;
            }
            state.feePot -= cashback;

            return (BaseHook.afterSwap.selector, int128(uint128(cashback)));
        }
        return (BaseHook.afterSwap.selector, 0);
    }




    /////////////////////////
    // HELPER Functions
    /////////////////////////

    function _sqrtPriceToPrice(uint160 sqrtPriceX96) 
        internal pure returns (uint256) 
    {
        uint256 sq = uint256(sqrtPriceX96);
        return (sq * sq) >> 192;
    }

    function _computeToxicity(
        PoolFlowState storage state,
        SwapParams calldata params
    ) internal view returns (uint256) {
        int256 imbalance = state.inventoryImbalance;
        uint256 imbalanceScore;
        
        if ((params.zeroForOne && imbalance > 0) || (!params.zeroForOne && imbalance < 0))  {
            imbalanceScore = 50;
        } else {
            imbalanceScore = 0;
        }

        uint256 swapSize;
        if (params.amountSpecified < 0) {
            swapSize = uint256(-params.amountSpecified);
        } else {
            swapSize = uint256(params.amountSpecified);
        }

        uint256 sizeScore;
        if (swapSize > state.emaPrice) {
            sizeScore = 50;
        } else {
            sizeScore = (swapSize * 50) / (state.emaPrice + 1);
        }

        return imbalanceScore + sizeScore;
    }

}