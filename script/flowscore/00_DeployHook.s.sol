// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {FlowScoreHook} from "../../src/FlowScoreHook.sol";

/// @notice Deploy script for FlowScoreHook. TODO: implement once hook permissions are finalised.
contract DeployFlowScoreHookScript is Script {
    function run() public {}
}
