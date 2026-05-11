// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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

/// @title FlowScoreHook
/// @author Petr Jeřábek
/// @notice A Uniswap v4 hook that penalises toxic order flow with higher fees and rewards
///         benign swappers with cashback from an accumulated fee pot.
/// @dev Toxicity is determined by whether a swap worsens the pool's inventory imbalance.
///      A composite score (size, flow EMA, tick deviation) determines the exact fee within
///      [MIN_FEE, MAX_FEE]. Half the surcharge is captured in a per-pool fee pot and
///      redistributed to benign swappers as cashback.
contract FlowScoreHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    // ─────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────

    /// @notice Per-pool flow and fee-pot state.
    struct PoolFlowState {
        /// @dev EMA of the pool tick, used as a reference for deviation scoring.
        int24 emaTick;
        /// @dev EMA of signed swap flow; positive = net zeroForOne pressure.
        int256 signedFlowEma;
        /// @dev Signed inventory imbalance; positive = pool is token0-heavy.
        int256 inventoryImbalance;
        /// @dev Accumulated surcharge in token0.
        uint256 feePot0;
        /// @dev Accumulated surcharge in token1.
        uint256 feePot1;
        /// @dev Timestamp of the most recent swap update.
        uint256 lastUpdated;
        /// @dev Imbalance magnitude at which the fee reaches MAX_FEE (per-pool, owner-configurable).
        uint256 imbalanceScale;
        /// @dev Block number in which cashback was last paid from this pool.
        uint48 bonusBlock;
        /// @dev Total cashback distributed in bonusBlock; reset at the start of each new block.
        uint256 blockBonusPaid;
    }

    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────

    /// @notice The dynamic-fee flag required in the pool's fee tier for this hook.
    uint24 public constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;

    /// @notice Standard baseline LP fee (0.30%).
    uint24 public constant BASE_FEE = 3000;

    /// @notice Maximum fee charged on a maximally toxic swap (1.00%).
    uint24 public constant MAX_FEE = 10000;

    /// @notice Minimum fee charged on a fully benign swap (0.05%).
    uint24 public constant MIN_FEE = 500;

    /// @notice Denominator used when converting fee basis points to a fraction.
    uint256 public constant FEE_UNITS_DENOMINATOR = 1_000_000;

    /// @notice EMA smoothing factor applied each swap (alpha = 20/100).
    uint256 public constant EMA_ALPHA = 20;

    /// @notice EMA denominator corresponding to EMA_ALPHA.
    uint256 public constant EMA_DENOMINATOR = 100;

    /// @notice Share of the toxic surcharge that flows into the fee pot (50%).
    uint256 public constant FEE_POT_CONTRIBUTION_BPS = 5000;

    /// @notice Maximum cashback expressed in basis points of the swap size (0.35%).
    uint256 public constant MAX_CASHBACK_BPS = 35;

    /// @notice Denominator for basis-point arithmetic.
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Default imbalance scale used when none has been set for a pool.
    uint256 public constant DEFAULT_IMBALANCE_SCALE = 80e18;

    /// @notice Weight of the size component in the composite toxicity score (40%).
    uint256 public constant WEIGHT_SIZE_BPS = 4_000;

    /// @notice Weight of the signed-flow EMA component in the composite toxicity score (30%).
    uint256 public constant WEIGHT_FLOW_BPS = 3_000;

    /// @notice Weight of the tick-deviation component in the composite toxicity score (30%).
    uint256 public constant WEIGHT_DEVIATION_BPS = 3_000;

    /// @notice Reference swap size used to normalise the size toxicity score (1e18).
    uint256 public constant SIZE_SCALE = 10e18;

    /// @notice Tick deviation at which the deviation toxicity score is capped at 100%.
    uint256 public constant DEVIATION_SCALE_TICKS = 200;

    /// @notice Minimum swap size (in token units) eligible for cashback.
    uint256 public constant MIN_CASHBACK_TRADE_SIZE = 1e16;

    /// @notice Maximum fraction of the fee pot that can be distributed as cashback in a single block (20%).
    uint256 public constant MAX_BLOCK_CASHBACK_BPS_OF_POT = 2_000;

    /// @notice Minimum balance kept in the fee pot at all times to prevent full drainage.
    uint256 public constant MIN_FEE_POT_RESERVE = 1e15;

    // ─────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────

    /// @notice Per-pool flow state, keyed by PoolId.
    mapping(PoolId poolId => PoolFlowState state) public flowState;

    /// @notice Pending toxic contribution deferred from beforeSwap to afterSwap (exactOutput path).
    mapping(PoolId poolId => uint256 amount) public pendingContribution;

    /// @notice True when a toxic exactInput swap is in flight for the given pool.
    mapping(PoolId poolId => bool inFlight) public toxicSwapInProgress;

    /// @notice Tracks the last block in which each address received cashback from a given pool.
    mapping(PoolId poolId => mapping(address sender => uint48)) public lastBonusBlock;

    /// @notice Address that may call owner-restricted admin functions.
    address public owner;

    /// @notice Emitted once per swap in beforeSwap with the toxicity verdict and fee decision.
    /// @param poolId The pool in which the swap occurs.
    /// @param isToxic True when the swap worsens pool inventory imbalance.
    /// @param scoreBps Composite toxicity ratio in the range [0, 100].
    /// @param feeCharged The dynamic fee applied to this swap.
    event SwapFeeDecision(PoolId indexed poolId, bool isToxic, uint256 scoreBps, uint24 feeCharged);

    /// @notice Emitted in afterSwap whenever cashback is paid to a benign swapper.
    /// @param poolId The pool from whose fee pot the cashback is drawn.
    /// @param amount Token amount returned to the swapper.
    event CashbackPaid(PoolId indexed poolId, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Deploys the hook and sets the deployer as owner.
    /// @param _pm The Uniswap v4 pool manager.
    constructor(IPoolManager _pm) BaseHook(_pm) {
        owner = msg.sender;
    }

    /// @notice Allows the hook to receive ETH for native-currency cashback settlements.
    receive() external payable {
        // Accept ETH forwarded during native pool settlements
    }

    // ─────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────

    /// @notice Sets the imbalance scale for a pool, adjusting fee sensitivity.
    /// @dev A smaller scale makes the fee reach MAX_FEE at lower imbalance levels.
    /// @param key The pool whose scale is being updated.
    /// @param scale The new imbalance scale value; must be greater than zero.
    function setImbalanceScale(PoolKey calldata key, uint256 scale) external onlyOwner {
        require(scale > 0, "scale must be > 0");
        flowState[key.toId()].imbalanceScale = scale;
    }

    // ─────────────────────────────────────────────
    // Hook permissions
    // ─────────────────────────────────────────────

    /// @notice Returns the hook permission flags required by this contract.
    /// @return permissions Struct indicating which hook callbacks are active.
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

    /// @notice Initialises per-pool flow state using the pool's starting tick.
    /// @param key The pool key of the newly initialised pool.
    /// @param tick The initial tick of the pool.
    /// @return selector The afterInitialize selector.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
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

    /// @notice Computes toxicity and sets the dynamic fee before each swap.
    /// @dev Toxic swaps (those that worsen pool imbalance) pay up to MAX_FEE.
    ///      Benign swaps pay MIN_FEE and are eligible for cashback in afterSwap.
    ///      For exactInput toxic swaps the surcharge contribution is collected immediately
    ///      via a BeforeSwapDelta; for exactOutput it is deferred to afterSwap.
    /// @param key The pool in which the swap occurs.
    /// @param params Swap direction and amount.
    /// @return selector The beforeSwap selector.
    /// @return delta Token delta applied before the swap (non-zero for exactInput toxic surcharge).
    /// @return fee The dynamic fee with the override flag set.
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

    /// @notice Updates flow state, settles deferred toxic contributions, and pays cashback.
    /// @dev For exactOutput toxic swaps the deferred contribution is collected here.
    ///      For benign swaps, cashback is paid from the output-token fee pot subject to
    ///      several anti-gaming guards (minimum trade size, per-address cooldown, block cap,
    ///      and a minimum pot reserve).
    /// @param sender The address that initiated the swap (used for per-address cashback cooldown).
    /// @param key The pool in which the swap occurred.
    /// @param params Swap direction and amount.
    /// @param delta Actual token deltas resulting from the swap.
    /// @return selector The afterSwap selector.
    /// @return hookDelta Positive = tokens owed to pool manager; negative = tokens owed to swapper.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
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
        state.signedFlowEma =
            (int256(EMA_ALPHA) * signedFlow + int256(EMA_DENOMINATOR - EMA_ALPHA) * state.signedFlowEma)
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

    /// @notice Adds `amount` to the fee pot for the specified token side.
    /// @param state The pool flow state to mutate.
    /// @param token0 True to credit feePot0, false to credit feePot1.
    /// @param amount Amount to add.
    function _increaseFeePot(PoolFlowState storage state, bool token0, uint256 amount) internal {
        if (token0) state.feePot0 += amount;
        else state.feePot1 += amount;
    }

    /// @notice Subtracts `amount` from the fee pot for the specified token side, flooring at zero.
    /// @param state The pool flow state to mutate.
    /// @param token0 True to debit feePot0, false to debit feePot1.
    /// @param amount Amount to subtract.
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

    /// @notice Transfers tokens held by this hook to the PoolManager as settlement.
    /// @dev Handles both native ETH and ERC-20 currencies.
    /// @param currency The currency to settle.
    /// @param amount The amount to transfer.
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

    /// @notice Returns the fee pot balance for the specified token side.
    /// @param state The pool flow state to read.
    /// @param token0 True to read feePot0, false to read feePot1.
    /// @return The current pot balance.
    function _getFeePot(PoolFlowState storage state, bool token0) internal view returns (uint256) {
        return token0 ? state.feePot0 : state.feePot1;
    }

    /// @notice Computes a composite toxicity score and direction verdict for a swap.
    /// @dev Toxicity direction is determined by whether the swap increases inventory imbalance.
    ///      The ratio [0-100] is a weighted combination of three sub-scores:
    ///      size (how large relative to SIZE_SCALE), flow trend (alignment with signed-flow EMA),
    ///      and tick deviation (distance of current tick from the EMA tick).
    /// @param state The current pool flow state.
    /// @param params The swap parameters.
    /// @param pid The pool identifier (used to read current tick from pool manager).
    /// @return toxicityRatio Composite score in [0, 100].
    /// @return isToxic True when the swap worsens inventory imbalance.
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
        bool signChanged = (state.inventoryImbalance != 0) && ((state.inventoryImbalance > 0) != (imbalanceAfter > 0));
        isToxic = _abs(imbalanceAfter) > _abs(state.inventoryImbalance) || signChanged;

        // Size score: how large is the swap relative to SIZE_SCALE (1e18 reference).
        uint256 sizeScoreBps = swapSize >= SIZE_SCALE ? BPS_DENOMINATOR : (swapSize * BPS_DENOMINATOR / SIZE_SCALE);

        // Flow score: how aligned is this swap with the recent signed-flow EMA?
        bool flowDirectionMatch =
            (state.signedFlowEma > 0 && signedFlow > 0) || (state.signedFlowEma < 0 && signedFlow < 0);
        uint256 flowScoreBps;
        if (state.signedFlowEma == 0 || !flowDirectionMatch) {
            flowScoreBps = 0;
        } else {
            uint256 absEma = state.signedFlowEma > 0 ? uint256(state.signedFlowEma) : uint256(-state.signedFlowEma);
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
        uint256 compositeBps =
            (sizeScoreBps * WEIGHT_SIZE_BPS + flowScoreBps * WEIGHT_FLOW_BPS + deviationScoreBps * WEIGHT_DEVIATION_BPS)
                / BPS_DENOMINATOR;
        toxicityRatio = compositeBps / 100;
    }

    /// @notice Returns the absolute value of a signed integer.
    /// @param x The signed integer.
    /// @return The absolute value as an unsigned integer.
    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice Computes the cashback rate in basis points for a benign swap.
    /// @dev Cashback is proportional to how imbalanced the pool was before the swap.
    ///      Returns zero when the swap does not reduce imbalance.
    /// @param imbalanceBefore Signed inventory imbalance before the swap.
    /// @param imbalanceAfter Signed inventory imbalance after the swap.
    /// @param imbalanceScale The pool-specific scale at which cashback reaches its maximum.
    /// @return Cashback in basis points, capped at MAX_CASHBACK_BPS.
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
