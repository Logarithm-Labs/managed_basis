// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Base, Bsc} from "script/utils/ProtocolAddresses.sol";

contract BscUpgradeBeacon is Script {
    function run() public {
        vm.startBroadcast();
        UpgradeableBeacon beacon = UpgradeableBeacon(Bsc.BEACON_BROTHER_SWAPPER);
        beacon.upgradeTo(address(new BrotherSwapper()));
        vm.stopBroadcast();
    }
}

contract BaseUpgradeBeacon is Script {
    function run() public {
        vm.startBroadcast();
        UpgradeableBeacon beacon = UpgradeableBeacon(Base.BEACON_BROTHER_SWAPPER);
        beacon.upgradeTo(address(new BrotherSwapper()));
        vm.stopBroadcast();
    }
}
