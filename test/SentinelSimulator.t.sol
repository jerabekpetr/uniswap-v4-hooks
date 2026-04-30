// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {SentinelJITGuardHook} from "../src/SentinelJITGuardHook.sol";
import {SentinelSimulator} from "../src/SentinelSimulator.sol";

contract SentinelSimulatorTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    SentinelJITGuardHook hook;
    SentinelSimulator simulator;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        address flags = address(
            uint160(
                Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            ) ^ (0x5555 << 144)
        );
        bytes memory hookArgs = abi.encode(poolManager);
        deployCodeTo("SentinelJITGuardHook.sol:SentinelJITGuardHook", hookArgs, flags);
        hook = SentinelJITGuardHook(flags);

        simulator = new SentinelSimulator(
            poolManager,
            positionManager,
            swapRouter,
            permit2,
            MockERC20(Currency.unwrap(currency0)),
            MockERC20(Currency.unwrap(currency1)),
            IHooks(hook)
        );
    }

    function test_ConstructorInitializesBothPools() public view {
        PoolId poolWithHookId = simulator.poolWithHookId();
        PoolId poolNoHookId = simulator.poolNoHookId();

        (uint160 sqrtPriceWithHook,,,) = poolManager.getSlot0(poolWithHookId);
        (uint160 sqrtPriceNoHook,,,) = poolManager.getSlot0(poolNoHookId);

        assertGt(sqrtPriceWithHook, 0, "pool with hook not initialized");
        assertGt(sqrtPriceNoHook, 0, "pool no-hook not initialized");
    }

    function test_RunScenarioCallable_ReturnsZeroOnEmpty() public {
        SentinelSimulator.ScenarioResult memory r = simulator.runScenario(
            0, 0, 
            0, 0,   
            0,      
            true,   
            false   
        );
        assertEq(r.passiveLPDelta0, 0);
        assertEq(r.passiveLPDelta1, 0);
        assertEq(r.jitDelta0, 0);
        assertEq(r.jitDelta1, 0);
        assertEq(r.swapAmountOut, 0);
    }

    function test_Baseline_PassiveLPEarnsFromSwap() public {
        SentinelSimulator.ScenarioResult memory r = simulator.runScenario(
            100e18, 100e18,   
            0, 0,            
            5e18,             
            true,     
            false        
        );

        assertGt(r.passiveLPDelta0 + r.passiveLPDelta1, 0, "passive LP should earn fees");
        assertEq(r.jitDelta0, 0, "no JIT scenario -> jit delta 0");
        assertEq(r.jitDelta1, 0, "no JIT scenario -> jit delta 0");
        assertGt(r.swapAmountOut, 0, "swap should produce output");
    }

    function test_JITAttack_NoHook_AttackerProfits() public {
        SentinelSimulator.ScenarioResult memory r = simulator.runScenario(
            100e18, 100e18,
            100e18, 100e18,
            5e18,
            false,
            true     // useJIT
        );

        int256 jitNet = r.jitDelta0 + r.jitDelta1;
        assertGe(jitNet, -1e15);
    }

    function test_JITAttack_WithHook_AttackerLosesToPenalty() public {
        SentinelSimulator.ScenarioResult memory r = simulator.runScenario(
            100e18, 100e18,
            100e18, 100e18,
            5e18,
            true,    // useHook=true
            true
        );

        int256 jitNet = r.jitDelta0 + r.jitDelta1;
        assertLt(jitNet, -1e18);
    }

    function test_JITAttack_HookReducesJITProfit() public {
        uint256 snap = vm.snapshot();

        SentinelSimulator.ScenarioResult memory noHook = simulator.runScenario(
            100e18, 100e18, 100e18, 100e18, 5e18, false, true
        );
        vm.revertTo(snap);

        SentinelSimulator.ScenarioResult memory withHook = simulator.runScenario(
            100e18, 100e18, 100e18, 100e18, 5e18, true, true
        );

        assertLt(
            withHook.jitDelta0 + withHook.jitDelta1,
            noHook.jitDelta0 + noHook.jitDelta1
        );
    }

    function test_JITAttack_HookIncreasesPassiveLPEarnings() public {
        uint256 snap = vm.snapshot();

        SentinelSimulator.ScenarioResult memory noHook = simulator.runScenario(
            100e18, 100e18, 100e18, 100e18, 5e18, false, true
        );
        vm.revertTo(snap);

        SentinelSimulator.ScenarioResult memory withHook = simulator.runScenario(
            100e18, 100e18, 100e18, 100e18, 5e18, true, true
        );

        assertGt(
            withHook.passiveLPDelta0 + withHook.passiveLPDelta1,
            noHook.passiveLPDelta0 + noHook.passiveLPDelta1
        );
    }
}