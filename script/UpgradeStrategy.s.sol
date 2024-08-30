// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";

contract UpgradeStrategyScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0xc14Da39589AB11746A46939e7Ba4e58Cb43d3b24);
    BasisStrategy constant strategy = BasisStrategy(0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1);

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        beacon.upgradeTo(strategyImpl);
        strategy.reinitialize();
    }
}
