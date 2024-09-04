// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {GmxV2PositionManagerForTest} from "src/GmxV2PositionManagerForTest.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradePositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0x97E207D731CC35B68114A9923e4767306aFE45bc);

    function run() public {
        vm.startBroadcast();
        address positionManagerImpl = address(new GmxV2PositionManagerForTest());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
    }
}
