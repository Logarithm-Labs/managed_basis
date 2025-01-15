// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {Arbitrum} from "script/utils/ProtocolAddresses.sol";

contract UpgradeStrategyScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(Arbitrum.BEACON_STRATEGY);

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        beacon.upgradeTo(strategyImpl);
    }
}
