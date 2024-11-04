// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {GmxConfig} from "src/position/gmx/GmxConfig.sol";

contract ModifyGmxConfigScript is Script {
    GmxConfig config = GmxConfig(0x611169E7e9C70F23E1F9C067Ee23A3B78F3c34BF);

    function run() public {
        vm.startBroadcast();
        config.setRealizedPnlDiffFactor(0.1 ether);
    }
}
