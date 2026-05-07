// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook}              from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks}                 from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager}          from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}               from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams}            from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary}          from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";


contract FlowScoreHook is BaseHook {
    using CurrencyLibrary for Currency;

    constructor(IPoolManager _pm) BaseHook(_pm) {}

    receive() external payable {}

    uint24 public constant DYNAMIC_FEE_FLAG  = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 public constant BASE_FEE          = 3000;  // 0.30 %  – standard LP fee
    uint24 public constant MAX_FEE           = 10000; // 1.00 %  – max penalty
    uint24 public constant MIN_FEE           = 500;   // 0.05 %  – reward for benign swaps
    uint256 public constant FEE_UNITS_DENOMINATOR    = 1_000_000;
    uint256 public constant EMA_ALPHA        = 20;
    uint256 public constant EMA_DENOMINATOR  = 100;
    uint256 public constant FEE_POT_CONTRIBUTION_BPS = 5000; // 50 % of extra fee → feePot
    uint256 public constant MAX_CASHBACK_BPS         = 35;   // 0.35 % max cashback
    uint256 public constant BPS_DENOMINATOR          = 10000;
    // Default per-pool scale: inventoryImbalance at which fee reaches MAX_FEE / cashback reaches MAX_CASHBACK_BPS.
    uint256 public constant DEFAULT_IMBALANCE_SCALE  = 80e18;

    struct PoolFlowState {
        uint256 emaPrice; // klouzavý průměr ceny
        int256  inventoryImbalance; // kladné = přebytek token0
        uint256 feePot; // nasbírané příplatky
        uint256 lastUpdated; // timestamp posledního swapu
        uint256 imbalanceScale; // imbalance při které fee dosáhne maxima (per-pool)
    }

    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    mapping(PoolId => PoolFlowState) public flowState;
    mapping(PoolId => uint256) public pendingContribution;
    mapping(PoolId => bool) public toxicSwapInProgress;

    function setImbalanceScale(PoolKey calldata key, uint256 scale) external {
        require(scale > 0, "scale must be > 0");
        flowState[key.toId()].imbalanceScale = scale;
    }



    /// @notice Returns the set of hook callbacks this hook uses.
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
            beforeSwapReturnDelta:           true,
            afterSwapReturnDelta:            true,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }


    /////////////////////////
    // CALLBACKS
    /////////////////////////

    /// @notice Initializes per-pool flow state after pool creation.
    /// @param key The pool being initialized.
    /// @param sqrtPriceX96 Initial sqrt price used to seed the EMA.
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
            lastUpdated: block.timestamp,
            imbalanceScale: DEFAULT_IMBALANCE_SCALE
        });

        return BaseHook.afterInitialize.selector;
    }

    /// @notice Computes toxicity of the incoming swap and sets the dynamic fee.
    /// Toxic swaps pay up to MAX_FEE; benign swaps pay MIN_FEE.
    /// For exactInput toxic swaps, the feePot contribution is collected immediately.
    /// @param key The pool being swapped in.
    /// @param params Swap parameters (direction, amount).
    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = key.toId();
        PoolFlowState storage state = flowState[pid];

        (uint256 toxicityRatio, bool isToxic) = _computeToxicity(state, params);

        // Toxic swap: fee rises linearly from BASE_FEE (ratio=0) to MAX_FEE (ratio=100).
        // Benign swap: discounted MIN_FEE as reward for improving pool balance.
        uint24 fee = isToxic
            ? uint24(BASE_FEE + (uint256(MAX_FEE - BASE_FEE) * toxicityRatio) / 100)
            : MIN_FEE;

        if (isToxic) {
            uint256 swapSize = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);

            // Extra fee above BASE_FEE; a fixed share goes into feePot.
            uint256 extraFee = fee - BASE_FEE;
            uint256 contribution =
                (swapSize * extraFee * FEE_POT_CONTRIBUTION_BPS) / (FEE_UNITS_DENOMINATOR * BPS_DENOMINATOR);

            toxicSwapInProgress[pid] = contribution > 0;

            if (contribution > 0 && params.amountSpecified < 0) {
                // exactInput: take the contribution from the input token right now.
                state.feePot += contribution;
                pendingContribution[pid] = 0;

                Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
                poolManager.take(inputCurrency, address(this), contribution);

                return (
                    BaseHook.beforeSwap.selector,
                    toBeforeSwapDelta(int128(uint128(contribution)), 0),
                    fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
            }

            // exactOutput: defer collection to afterSwap once we know actual amounts.
            pendingContribution[pid] = contribution;
        } else {
            pendingContribution[pid] = 0;
            toxicSwapInProgress[pid] = false;
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @notice Updates pool flow state after swap and handles cashback for benign swaps.
    /// Collects deferred contributions for exactOutput toxic swaps.
    /// @param key The pool being swapped in.
    /// @param params Swap parameters.
    /// @param delta Actual token amounts exchanged.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId pid = key.toId();
        PoolFlowState storage state = flowState[pid];
        int256 imbalanceBefore = state.inventoryImbalance;

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
            state.inventoryImbalance -= int256(uint256(uint128(amount0 < 0 ? -amount0 : amount0)));
        }
        int256 imbalanceAfter = state.inventoryImbalance;

        state.lastUpdated = block.timestamp;

        // Toxic swap
        uint256 contribution = pendingContribution[pid];
        if (contribution > 0) {
            state.feePot += contribution;
            pendingContribution[pid] = 0;
            toxicSwapInProgress[pid] = false;

            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            poolManager.take(inputCurrency, address(this), contribution);

            return (BaseHook.afterSwap.selector, int128(uint128(contribution)));
        }

        if (toxicSwapInProgress[pid]) {
            toxicSwapInProgress[pid] = false;
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

            uint256 cashbackBps = _computeCashbackBps(imbalanceBefore, imbalanceAfter, state.imbalanceScale);
            uint256 cashback = (swapSize * cashbackBps) / BPS_DENOMINATOR;
            if (cashback > state.feePot) {
                cashback = state.feePot;
            }
            state.feePot -= cashback;

            Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
            _settleToPoolManager(outputCurrency, cashback);

            return (BaseHook.afterSwap.selector, -int128(uint128(cashback)));
        }        
        return (BaseHook.afterSwap.selector, 0);
    }




    /////////////////////////
    // HELPER Functions
    /////////////////////////

    /// @notice Converts sqrtPriceX96 to a price with 18 decimal precision.
    /// @param sqrtPriceX96 Square root price in Q96 format.
    /// @return Price as token1/token0 with 1e18 scaling.
    function _sqrtPriceToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 sq = uint256(sqrtPriceX96);
        return ((sq * sq) * 1e18) >> 192;
    }

    /// @notice Transfers tokens from this hook back to the PoolManager as settlement.
    /// @param currency Token to settle.
    /// @param amount Amount to transfer.
    function _settleToPoolManager(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Computes toxicity ratio and toxic flag for an incoming swap.
    /// A swap is toxic if it increases pool imbalance or overshoots through zero.
    /// @return toxicityRatio Value in [0, 100] where 100 means fully imbalanced.
    /// @return isToxic True if the swap worsens pool balance.
    function _computeToxicity(
        PoolFlowState storage state,
        SwapParams calldata params
    ) internal view returns (uint256 toxicityRatio, bool isToxic) {
        int256 imbalanceBefore = state.inventoryImbalance;
        uint256 swapSize = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        // Positive flow = token0 flows into the pool (pool becomes token0-heavy).
        int256 signedFlow = params.zeroForOne ? int256(swapSize) : -int256(swapSize);
        int256 imbalanceAfter = imbalanceBefore + signedFlow;

        uint256 absBefore = _abs(imbalanceBefore);
        uint256 absAfter  = _abs(imbalanceAfter);

        // Toxic if distance from 50:50 increases, or if swap overshoots through zero
        // (e.g. +50 → -49 reduces |imbalance| but creates a new imbalance on the other side).
        bool signChanged = (imbalanceBefore != 0) && ((imbalanceBefore > 0) != (imbalanceAfter > 0));
        isToxic = absAfter > absBefore || signChanged;

        uint256 scale = state.imbalanceScale > 0 ? state.imbalanceScale : DEFAULT_IMBALANCE_SCALE;
        toxicityRatio = absAfter >= scale ? 100 : (absAfter * 100) / scale;
    }

    /// @notice Returns the absolute value of a signed integer.
    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice Computes cashback in basis points for a benign swap.
    /// Cashback is proportional to how imbalanced the pool was before the swap.
    /// Returns 0 if the swap did not improve pool balance.
    /// @param imbalanceBefore Pool imbalance before the swap.
    /// @param imbalanceAfter Pool imbalance after the swap.
    /// @param imbalanceScale Per-pool scale for normalizing imbalance.

    function _computeCashbackBps(
        int256 imbalanceBefore,
        int256 imbalanceAfter,
        uint256 imbalanceScale
    ) internal pure returns (uint256) {
        uint256 absBefore = _abs(imbalanceBefore);
        uint256 absAfter  = _abs(imbalanceAfter);

        if (absAfter >= absBefore) return 0; // swap did not improve balance

        uint256 scale = imbalanceScale > 0 ? imbalanceScale : DEFAULT_IMBALANCE_SCALE;
        uint256 startRatio = absBefore >= scale ? 100 : (absBefore * 100) / scale;

        return (MAX_CASHBACK_BPS * startRatio) / 100;
    }

}
