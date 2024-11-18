// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradeGmxPositionManagerScript is Script {
    UpgradeableBeacon hedgeManagerBeacon = UpgradeableBeacon(0x91544E205446E673aeC904c53BdB7cA9b892CD5E);

    function run() public {
        vm.startBroadcast();
        address hedgeManagerImpl = address(new GmxV2PositionManager());
        hedgeManagerBeacon.upgradeTo(hedgeManagerImpl);
        // hedgeManager.reinitialize();
    }
}
