// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

contract SimpleVolatilityFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MAX_FEE = 10000;
    uint256 public constant VOL_SCALE = 100e18;

    struct PoolVolatilityState {
        bool initialized;
        int24 lastTick;
        uint256 sigmaX18;
        uint256 lastUpdatedBlock;
    }

    mapping(PoolId => PoolVolatilityState) public volatility;

    event VolatilityFeeDecision(PoolId indexed poolId, uint24 fee, uint256 sigmaX18);

    constructor(IPoolManager _pm) BaseHook(_pm) {}

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

    function currentFee(PoolId pid) public view returns (uint24) {
        PoolVolatilityState storage v = volatility[pid];
        uint256 step = uint256(MAX_FEE - BASE_FEE);
        uint256 inc = v.sigmaX18 >= VOL_SCALE ? step : (v.sigmaX18 * step) / VOL_SCALE;
        return uint24(uint256(BASE_FEE) + inc);
    }

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
