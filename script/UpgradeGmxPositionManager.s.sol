// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManagerForTest} from "src/position/gmx/GmxV2PositionManagerForTest.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradeGmxPositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0x97E207D731CC35B68114A9923e4767306aFE45bc);
    GmxV2PositionManagerForTest positionManager =
        GmxV2PositionManagerForTest(0x1ec52Db6A9C7B175507Ec3fAFb13b71cFC4e700f);

    function run() public {
        vm.startBroadcast();
        address positionManagerImpl = address(new GmxV2PositionManagerForTest());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
        // positionManager.reinitialize();
    }
}
