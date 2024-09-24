// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManagerForTest} from "src/GmxV2PositionManagerForTest.sol";
import {GmxConfig} from "src/GmxConfig.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradeGmxConfigAndPositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0x97E207D731CC35B68114A9923e4767306aFE45bc);
    GmxConfig config = GmxConfig(0x2cC1567874312C3D8833509F6F6ec0d322E30514);

    function run() public {
        vm.startBroadcast();
        address newConfigImpl = address(new GmxConfig());
        config.upgradeToAndCall(newConfigImpl, abi.encodeWithSelector(GmxConfig.reinitialize.selector));

        address positionManagerImpl = address(new GmxV2PositionManagerForTest());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
    }
}
