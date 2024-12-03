// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {Arbitrum, Bsc} from "script/utils/ProtocolAddresses.sol";

contract UpgradeStrategyXSpotScript is Script {
    UpgradeableBeacon beaconStrategy = UpgradeableBeacon(Arbitrum.BEACON_STRATEGY);
    UpgradeableBeacon beaconXSpotManager = UpgradeableBeacon(Arbitrum.BEACON_X_SPOT_MANAGER);

    function run() public {
        vm.startBroadcast();
        beaconStrategy.upgradeTo(address(new BasisStrategy()));
        beaconXSpotManager.upgradeTo(address(new XSpotManager()));
        vm.stopBroadcast();
    }
}

contract UpgradeBrotherSwapperScript is Script {
    UpgradeableBeacon beaconSwapper = UpgradeableBeacon(Bsc.BEACON_BROTHER_SWAPPER);

    function run() public {
        vm.startBroadcast();
        beaconSwapper.upgradeTo(address(new BrotherSwapper()));
        vm.stopBroadcast();
    }
}
