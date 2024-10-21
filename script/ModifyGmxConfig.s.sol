// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {GmxConfig} from "src/position/gmx/GmxConfig.sol";

contract ModifyGmxConfigScript is Script {
    GmxConfig config = GmxConfig(0x2cC1567874312C3D8833509F6F6ec0d322E30514);

    function run() public {
        vm.startBroadcast();
        config.setLimitDecreaseCollateral(0);
    }
}
