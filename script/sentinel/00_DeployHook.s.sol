// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SentinelJITGuardHook} from "../../src/SentinelJITGuardHook.sol";

/// @notice Mines the address and deploys the SentinelJITGuardHook.sol Hook contract
contract DeployHookScript is Script {
    function run() public {
        string memory v4json = vm.readFile("./frontend/v4-addresses.json");
        IPoolManager poolManager = IPoolManager(vm.parseJsonAddress(v4json, ".poolManager"));
        require(address(poolManager).code.length > 0, "No code at poolManager (run 00_DeployV4 first)");

        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        bytes memory constructorArgs = abi.encode(address(poolManager));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(SentinelJITGuardHook).creationCode, constructorArgs);

        vm.startBroadcast();
        SentinelJITGuardHook hook = new SentinelJITGuardHook{salt: salt}(poolManager);
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: Hook Address Mismatch");
    }
}
