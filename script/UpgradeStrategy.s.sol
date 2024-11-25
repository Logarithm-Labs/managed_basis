// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";

contract UpgradeStrategyScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0xA610080Bf93CC031492a29D09DBC8b234F291ea7);

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        beacon.upgradeTo(strategyImpl);
        // strategy.reinitialize();
    }
}
