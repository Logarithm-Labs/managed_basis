// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";

contract UpgradeXSpotScript is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        UpgradeableBeacon beacon = UpgradeableBeacon(Arb.BEACON_X_SPOT_MANAGER);
        beacon.upgradeTo(address(new XSpotManager()));
        vm.stopBroadcast();
    }
}
