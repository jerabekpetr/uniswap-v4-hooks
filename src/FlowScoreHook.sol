// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract FlowScoreHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────
    // Access control
    // ─────────────────────────────────────────────

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IPoolManager _pm) BaseHook(_pm) {
        owner = msg.sender;
    }

    receive() external payable {}

    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    uint24 public constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 public constant BASE_FEE = 3000; // 0.30% – standard LP fee
    uint24 public constant MAX_FEE = 10000; // 1.00% – max penalty fee
    uint24 public constant MIN_FEE = 500; // 0.05% – reward for benign swaps
    uint256 public constant FEE_UNITS_DENOMINATOR = 1_000_000;
    uint256 public constant EMA_ALPHA = 20;
    uint256 public constant EMA_DENOMINATOR = 100;
    uint256 public constant FEE_POT_CONTRIBUTION_BPS = 5000; // 50% of extra fee → feePot
    uint256 public constant MAX_CASHBACK_BPS = 35; // 0.35% max cashback
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant DEFAULT_IMBALANCE_SCALE = 80e18;

    //composite toxicity weights (must sum to BPS_DENOMINATOR).
    uint256 public constant WEIGHT_SIZE_BPS = 4_000;
    uint256 public constant WEIGHT_FLOW_BPS = 3_000;
    uint256 public constant WEIGHT_DEVIATION_BPS = 3_000;
    uint256 public constant SIZE_SCALE = 10e18; // reference swap size for size score normalisation
    uint256 public constant DEVIATION_SCALE_TICKS = 200; // tick deviation at which score is capped

    //anti-gaming constants.
    uint256 public constant MIN_CASHBACK_TRADE_SIZE = 1e16; // minimum swap size eligible for cashback
    uint256 public constant MAX_BLOCK_CASHBACK_BPS_OF_POT = 2_000; // 20% of pot cap per block
    uint256 public constant MIN_FEE_POT_RESERVE = 1e15; // reserve kept in pot at all times

    // ─────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────

    //extended PoolFlowState.
    struct PoolFlowState {
        int24 emaTick; // EMA of pool tick (replaces emaPrice)
        int256 signedFlowEma; // EMA of signed swap flow (positive = net zeroForOne)
        int256 inventoryImbalance; // positive = pool is token0-heavy
        uint256 feePot0; // surcharges accumulated in token0
        uint256 feePot1; // surcharges accumulated in token1
        uint256 lastUpdated; // timestamp of the last swap
        uint256 imbalanceScale; // imbalance at which fee reaches maximum (per-pool)
        uint48 bonusBlock; // last block in which cashback was paid from this pool
        uint256 blockBonusPaid; // total cashback paid in bonusBlock (reset each new block)
    }

    // Emitted once per swap in beforeSwap with the fee decision.
    event SwapFeeDecision(
        PoolId indexed poolId,
        bool isToxic,
        uint256 scoreBps, // toxicity ratio 0-100
        uint24 feeCharged
    );

    // Emitted in afterSwap whenever a cashback is paid to a benign swapper.
    event CashbackPaid(PoolId indexed poolId, uint256 amount);

    mapping(PoolId => PoolFlowState) public flowState;
    mapping(PoolId => uint256) public pendingContribution;
    mapping(PoolId => bool) public toxicSwapInProgress;
    // per-address cooldown – one cashback per address per block.
    mapping(PoolId => mapping(address => uint48)) public lastBonusBlock;

    // ─────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────

    function setImbalanceScale(PoolKey calldata key, uint256 scale) external onlyOwner {
        require(scale > 0, "scale must be > 0");
        flowState[key.toId()].imbalanceScale = scale;
    }

    // ─────────────────────────────────────────────
    // Hook permissions
    // ─────────────────────────────────────────────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─────────────────────────────────────────────
    // Callbacks
    // ─────────────────────────────────────────────

    /// @notice initialises per-pool flow state using the initial tick (not sqrtPrice).
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId pid = key.toId();
        flowState[pid] = PoolFlowState({
            emaTick: tick,
            signedFlowEma: 0,
            inventoryImbalance: 0,
            feePot0: 0,
            feePot1: 0,
            lastUpdated: block.timestamp,
            imbalanceScale: DEFAULT_IMBALANCE_SCALE,
            bonusBlock: 0,
            blockBonusPaid: 0
        });
        return BaseHook.afterInitialize.selector;
    }

    /// @notice Computes toxicity and sets the dynamic fee.
    /// Toxic swaps (those that worsen pool imbalance) pay up to MAX_FEE;
    /// benign swaps pay MIN_FEE and are eligible for cashback.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        PoolFlowState storage state = flowState[pid];

        (uint256 toxicityRatio, bool isToxic) = _computeToxicity(state, params, pid);

        uint24 fee = isToxic ? uint24(BASE_FEE + (uint256(MAX_FEE - BASE_FEE) * toxicityRatio) / 100) : MIN_FEE;

        emit SwapFeeDecision(pid, isToxic, toxicityRatio, fee);

        if (isToxic) {
            uint256 swapSize =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

            uint256 extraFee = fee - BASE_FEE;
            uint256 contribution =
                (swapSize * extraFee * FEE_POT_CONTRIBUTION_BPS) / (FEE_UNITS_DENOMINATOR * BPS_DENOMINATOR);

            bool inputIsToken0 = params.zeroForOne;
            toxicSwapInProgress[pid] = contribution > 0;

            if (contribution > 0 && params.amountSpecified < 0) {
                // exactInput: collect contribution from input token immediately.
                _increaseFeePot(state, inputIsToken0, contribution);
                pendingContribution[pid] = 0;

                Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
                poolManager.take(inputCurrency, address(this), contribution);

                return (
                    BaseHook.beforeSwap.selector,
                    toBeforeSwapDelta(int128(uint128(contribution)), 0),
                    fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
            }

            // exactOutput: defer collection to afterSwap.
            pendingContribution[pid] = contribution;
        } else {
            pendingContribution[pid] = 0;
            toxicSwapInProgress[pid] = false;
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Updates flow state, handles deferred toxic contributions, and pays cashback to benign swappers.
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId pid = key.toId();
        PoolFlowState storage state = flowState[pid];
        int256 imbalanceBefore = state.inventoryImbalance;

        // update emaTick using the post-swap tick.
        (, int24 currentTick,,) = poolManager.getSlot0(pid);
        state.emaTick = int24(
            (int256(EMA_ALPHA) * int256(currentTick) + int256(EMA_DENOMINATOR - EMA_ALPHA) * int256(state.emaTick))
                / int256(EMA_DENOMINATOR)
        );

        // update signedFlowEma.
        uint256 swapSizeAbs =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        int256 signedFlow = params.zeroForOne ? int256(swapSizeAbs) : -int256(swapSizeAbs);
        state.signedFlowEma = (int256(EMA_ALPHA) * signedFlow + int256(EMA_DENOMINATOR - EMA_ALPHA) * state.signedFlowEma)
            / int256(EMA_DENOMINATOR);

        // Update inventory imbalance based on actual delta.
        int128 amount0 = delta.amount0();
        if (params.zeroForOne) {
            state.inventoryImbalance += int256(uint256(uint128(amount0 < 0 ? -amount0 : amount0)));
        } else {
            state.inventoryImbalance -= int256(uint256(uint128(amount0 < 0 ? -amount0 : amount0)));
        }
        int256 imbalanceAfter = state.inventoryImbalance;

        state.lastUpdated = block.timestamp;

        // Toxic swap – exactOutput deferred contribution.
        uint256 contribution = pendingContribution[pid];
        if (contribution > 0) {
            bool inputIsToken0 = params.zeroForOne;
            _increaseFeePot(state, inputIsToken0, contribution);
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

        // Benign swap – cashback from the pot for the output token.
        bool outputIsToken0 = !params.zeroForOne;
        uint256 availablePot = _getFeePot(state, outputIsToken0);

        if (availablePot == 0) return (BaseHook.afterSwap.selector, 0);

        // anti-gaming guards.
        if (swapSizeAbs < MIN_CASHBACK_TRADE_SIZE) return (BaseHook.afterSwap.selector, 0);
        if (lastBonusBlock[pid][sender] >= uint48(block.number)) return (BaseHook.afterSwap.selector, 0);

        // Per-block cap: reset counter on a new block.
        if (state.bonusBlock != uint48(block.number)) {
            state.bonusBlock = uint48(block.number);
            state.blockBonusPaid = 0;
        }
        uint256 blockCap = availablePot * MAX_BLOCK_CASHBACK_BPS_OF_POT / BPS_DENOMINATOR;
        if (state.blockBonusPaid >= blockCap) return (BaseHook.afterSwap.selector, 0);

        // Compute cashback.
        uint256 cashbackBps = _computeCashbackBps(imbalanceBefore, imbalanceAfter, state.imbalanceScale);
        uint256 cashback = (swapSizeAbs * cashbackBps) / BPS_DENOMINATOR;
        if (cashback == 0) return (BaseHook.afterSwap.selector, 0);

        // Reserve guard: keep MIN_FEE_POT_RESERVE in the pot.
        if (availablePot > MIN_FEE_POT_RESERVE && cashback > availablePot - MIN_FEE_POT_RESERVE) {
            cashback = availablePot - MIN_FEE_POT_RESERVE;
        } else if (availablePot <= MIN_FEE_POT_RESERVE) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Per-block cap (applied after reserve guard).
        uint256 remaining = blockCap - state.blockBonusPaid;
        if (cashback > remaining) cashback = remaining;
        if (cashback == 0) return (BaseHook.afterSwap.selector, 0);

        _decreaseFeePot(state, outputIsToken0, cashback);
        state.blockBonusPaid += cashback;
        lastBonusBlock[pid][sender] = uint48(block.number);

        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        _settleToPoolManager(outputCurrency, cashback);

        emit CashbackPaid(pid, cashback);
        return (BaseHook.afterSwap.selector, -int128(uint128(cashback)));
    }

    // ─────────────────────────────────────────────
    // Fee pot helpers
    // ─────────────────────────────────────────────

    function _getFeePot(PoolFlowState storage state, bool token0) internal view returns (uint256) {
        return token0 ? state.feePot0 : state.feePot1;
    }

    function _increaseFeePot(PoolFlowState storage state, bool token0, uint256 amount) internal {
        if (token0) state.feePot0 += amount;
        else state.feePot1 += amount;
    }

    function _decreaseFeePot(PoolFlowState storage state, bool token0, uint256 amount) internal {
        if (token0) {
            state.feePot0 = amount > state.feePot0 ? 0 : state.feePot0 - amount;
        } else {
            state.feePot1 = amount > state.feePot1 ? 0 : state.feePot1 - amount;
        }
    }

    // ─────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────

    /// @notice Transfers tokens from this hook to the PoolManager as settlement.
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

    /// @notice composite toxicity score.
    /// isToxic is determined directionally (does the swap worsen inventory imbalance?).
    /// toxicityRatio [0-100] is a composite of size, flow-trend, and tick-deviation scores.
    function _computeToxicity(PoolFlowState storage state, SwapParams calldata params, PoolId pid)
        internal
        view
        returns (uint256 toxicityRatio, bool isToxic)
    {
        uint256 swapSize =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Direction-based toxicity: does the swap worsen pool imbalance?
        int256 signedFlow = params.zeroForOne ? int256(swapSize) : -int256(swapSize);
        int256 imbalanceAfter = state.inventoryImbalance + signedFlow;
        bool signChanged = (state.inventoryImbalance != 0)
            && ((state.inventoryImbalance > 0) != (imbalanceAfter > 0));
        isToxic = _abs(imbalanceAfter) > _abs(state.inventoryImbalance) || signChanged;

        // Size score: how large is the swap relative to SIZE_SCALE (1e18 reference).
        uint256 sizeScoreBps = swapSize >= SIZE_SCALE ? BPS_DENOMINATOR : (swapSize * BPS_DENOMINATOR / SIZE_SCALE);

        // Flow score: how aligned is this swap with the recent signed-flow EMA?
        bool flowDirectionMatch = (state.signedFlowEma > 0 && signedFlow > 0)
            || (state.signedFlowEma < 0 && signedFlow < 0);
        uint256 flowScoreBps;
        if (state.signedFlowEma == 0 || !flowDirectionMatch) {
            flowScoreBps = 0;
        } else {
            uint256 absEma =
                state.signedFlowEma > 0 ? uint256(state.signedFlowEma) : uint256(-state.signedFlowEma);
            flowScoreBps = absEma >= SIZE_SCALE ? BPS_DENOMINATOR : (absEma * BPS_DENOMINATOR / SIZE_SCALE);
        }

        // Deviation score: how far has the tick drifted from its EMA?
        (, int24 currentTick,,) = poolManager.getSlot0(pid);
        int256 deviation = int256(currentTick) - int256(state.emaTick);
        uint256 absDeviation = deviation < 0 ? uint256(-deviation) : uint256(deviation);
        uint256 deviationScoreBps = absDeviation >= DEVIATION_SCALE_TICKS
            ? BPS_DENOMINATOR
            : (absDeviation * BPS_DENOMINATOR / DEVIATION_SCALE_TICKS);

        // Weighted composite → normalise to 0-100.
        uint256 compositeBps = (
            sizeScoreBps * WEIGHT_SIZE_BPS + flowScoreBps * WEIGHT_FLOW_BPS
                + deviationScoreBps * WEIGHT_DEVIATION_BPS
        ) / BPS_DENOMINATOR;
        toxicityRatio = compositeBps / 100;
    }

    /// @notice Returns the absolute value of a signed integer.
    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice Computes cashback in basis points for a benign swap.
    /// Proportional to how imbalanced the pool was before the swap.
    function _computeCashbackBps(int256 imbalanceBefore, int256 imbalanceAfter, uint256 imbalanceScale)
        internal
        pure
        returns (uint256)
    {
        uint256 absBefore = _abs(imbalanceBefore);
        uint256 absAfter = _abs(imbalanceAfter);

        if (absAfter >= absBefore) return 0;

        uint256 scale = imbalanceScale > 0 ? imbalanceScale : DEFAULT_IMBALANCE_SCALE;
        uint256 startRatio = absBefore >= scale ? 100 : (absBefore * 100) / scale;

        return (MAX_CASHBACK_BPS * startRatio) / 100;
    }
}
