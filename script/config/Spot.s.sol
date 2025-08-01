// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {Arb, Bsc, Base} from "script/utils/ProtocolAddresses.sol";

contract UpgradeSpotManager is Script {
    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast();
        UpgradeableBeacon beacon = UpgradeableBeacon(Arb.BEACON_SPOT_MANAGER);
        beacon.upgradeTo(address(new SpotManager()));
        vm.stopBroadcast();
    }
}
