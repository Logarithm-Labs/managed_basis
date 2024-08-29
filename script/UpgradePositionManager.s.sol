// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradePositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0xe5227e7432c9AdEE1404885c5aaD506954A08A74);

    function run() public {
        vm.startBroadcast();
        address positionManagerImpl = address(new OffChainPositionManager());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
    }
}
