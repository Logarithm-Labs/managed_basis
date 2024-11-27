// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradeGmxPositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0x91544E205446E673aeC904c53BdB7cA9b892CD5E);
    GmxV2PositionManager positionManager = GmxV2PositionManager(0x5903078b87795b85388102E0881d545C0f36E231);

    function run() public {
        vm.startBroadcast();
        address positionManagerImpl = address(new GmxV2PositionManager());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
    }
}
