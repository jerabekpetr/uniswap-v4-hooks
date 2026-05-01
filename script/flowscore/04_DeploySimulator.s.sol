// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {FlowScoreSimulator} from "../../src/FlowScoreSimulator.sol";

/// @notice Deploy script for FlowScore simulator.
/// Requires env FLOW_HOOK_ADDRESS and frontend/v4-addresses.json.
/// Writes frontend/addresses.json for the UI.
contract DeployFlowScoreSimulatorScript is Script {
    function run() external {
        address hookAddr = vm.envAddress("FLOW_HOOK_ADDRESS");

        string memory v4json = vm.readFile("./frontend/v4-addresses.json");
        address poolMgrAddr = vm.parseJsonAddress(v4json, ".poolManager");
        address posMgrAddr = vm.parseJsonAddress(v4json, ".positionManager");
        address routerAddr = vm.parseJsonAddress(v4json, ".swapRouter");
        address permit2Addr = vm.parseJsonAddress(v4json, ".permit2");

        require(hookAddr.code.length > 0, "No code at FLOW_HOOK_ADDRESS");
        require(poolMgrAddr.code.length > 0, "No code at poolManager (run 00_DeployV4 first)");

        IPoolManager poolManager = IPoolManager(poolMgrAddr);
        IPositionManager positionManager = IPositionManager(posMgrAddr);
        IUniswapV4Router04 swapRouter = IUniswapV4Router04(payable(routerAddr));
        IPermit2 permit2 = IPermit2(permit2Addr);

        vm.startBroadcast();

        MockERC20 t0 = new MockERC20("Token0", "T0", 18);
        MockERC20 t1 = new MockERC20("Token1", "T1", 18);
        (MockERC20 token0, MockERC20 token1) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);

        FlowScoreSimulator simulator =
            new FlowScoreSimulator(poolManager, positionManager, swapRouter, permit2, token0, token1, IHooks(hookAddr));
        vm.stopBroadcast();

        console2.log("FlowScoreSimulator deployed at:", address(simulator));

        string memory json = string.concat(
            "{\n",
            '  "chainId": 31337,\n',
            '  "simulator": "', vm.toString(address(simulator)), '",\n',
            '  "hook": "', vm.toString(hookAddr), '",\n',
            '  "token0": "', vm.toString(address(token0)), '",\n',
            '  "token1": "', vm.toString(address(token1)), '",\n',
            '  "poolManager": "', vm.toString(address(poolManager)), '"\n',
            "}\n"
        );
        vm.writeFile("./frontend/addresses.json", json);
        console2.log("Wrote ./frontend/addresses.json");
    }
}
