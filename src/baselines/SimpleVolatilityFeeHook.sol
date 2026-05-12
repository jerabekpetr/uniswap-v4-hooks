// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @title SimpleVolatilityFeeHook
/// @author Petr Jeřábek
/// @notice A baseline Uniswap v4 hook that sets a dynamic swap fee proportional to
///         a rolling per-pool volatility estimate.
/// @dev Volatility is measured as an EMA of absolute tick-moves per swap (80/20 decay,
///      scaled by 1e18). The fee scales linearly from BASE_FEE at zero volatility to
///      MAX_FEE at VOL_SCALE. This contract acts as a simple comparison benchmark for
///      the FlowScoreHook.
/// @dev Non-production analysis contract used only for thesis benchmarks,
///      simulations, and tests. Not audited or hardened for production use.
contract SimpleVolatilityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Rolling volatility state maintained per pool.
    struct PoolVolatilityState {
        /// @dev True once the first swap has been observed for this pool.
        bool initialized;
        /// @dev Tick recorded after the most recent swap, used to compute the next absolute move.
        int24 lastTick;
        /// @dev EMA of absolute tick-move per swap, scaled by 1e18 (80/20 decay).
        uint256 sigmaX18;
        /// @dev Block number of the last volatility update.
        uint256 lastUpdatedBlock;
    }

    /// @notice Baseline fee applied when volatility is zero (0.30%).
    uint24 public constant BASE_FEE = 3000;

    /// @notice Maximum fee applied when volatility is at or above VOL_SCALE (1.00%).
    uint24 public constant MAX_FEE = 10000;

    /// @notice Rolling-sigma value (scaled by 1e18) at which the fee reaches MAX_FEE.
    uint256 public constant VOL_SCALE = 100e18;

    /// @notice Per-pool volatility state, keyed by PoolId.
    mapping(PoolId poolId => PoolVolatilityState state) public volatility;

    /// @notice Emitted once per swap with the fee that was applied and the current sigma.
    /// @param poolId The pool in which the swap occurred.
    /// @param fee The dynamic fee charged for this swap.
    /// @param sigmaX18 The rolling sigma value at the time of the swap (scaled by 1e18).
    event VolatilityFeeDecision(PoolId indexed poolId, uint24 fee, uint256 sigmaX18);

    /// @notice Deploys the hook and wires it to the given pool manager.
    /// @param _pm The Uniswap v4 pool manager.
    constructor(IPoolManager _pm) BaseHook(_pm) {}

    /// @notice Returns the current dynamic fee for a pool based on its rolling volatility.
    /// @dev Fee scales linearly from BASE_FEE (sigma = 0) to MAX_FEE (sigma >= VOL_SCALE).
    /// @param pid The pool identifier.
    /// @return The current fee in fee-unit basis points (parts per million).
    function currentFee(PoolId pid) public view returns (uint24) {
        PoolVolatilityState storage v = volatility[pid];
        uint256 step = uint256(MAX_FEE - BASE_FEE);
        uint256 inc = v.sigmaX18 >= VOL_SCALE ? step : (v.sigmaX18 * step) / VOL_SCALE;
        return uint24(uint256(BASE_FEE) + inc);
    }

    /// @notice Returns the hook permission flags required by this contract.
    /// @return permissions Struct indicating which hook callbacks are active.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Applies the current volatility-based fee before each swap.
    /// @param key The pool key.
    /// @return selector The beforeSwap selector.
    /// @return delta Zero delta (this hook does not redirect tokens).
    /// @return fee The current dynamic fee with the override flag set.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        uint24 fee = currentFee(pid);
        emit VolatilityFeeDecision(pid, fee, volatility[pid].sigmaX18);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Updates the rolling volatility estimate after each swap.
    /// @dev The first swap initialises the state. Subsequent swaps feed the absolute tick-move
    ///      into the EMA: sigmaX18 = (80 * sigmaX18 + 20 * absMove * 1e18) / 100.
    /// @param key The pool key.
    /// @return selector The afterSwap selector.
    /// @return hookDelta Zero (this hook does not redirect tokens on swaps).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId pid = key.toId();
        PoolVolatilityState storage v = volatility[pid];
        (, int24 currentTick,,) = poolManager.getSlot0(pid);

        if (!v.initialized) {
            v.initialized = true;
            v.lastTick = currentTick;
            v.sigmaX18 = 0;
            v.lastUpdatedBlock = block.number;
        } else {
            int256 tickDiff = int256(currentTick) - int256(v.lastTick);
            uint256 absMove = tickDiff < 0 ? uint256(-tickDiff) : uint256(tickDiff);
            v.sigmaX18 = (80 * v.sigmaX18 + 20 * absMove * 1e18) / 100;
            v.lastTick = currentTick;
            v.lastUpdatedBlock = block.number;
        }

        return (BaseHook.afterSwap.selector, 0);
    }
}
