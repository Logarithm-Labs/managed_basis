// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";

contract UpgradeStrategyAndVaultScript is Script {
    UpgradeableBeacon constant vaultBeacon = UpgradeableBeacon(0x6e77994e0bADCF3421d1Fb0Fb8b523FCe0c989Ee);
    UpgradeableBeacon constant strategyBeacon = UpgradeableBeacon(0xc14Da39589AB11746A46939e7Ba4e58Cb43d3b24);
    address constant strategy = 0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1;

    function run() public {
        vm.startBroadcast();
        address vaultImpl = address(new LogarithmVault());
        vaultBeacon.upgradeTo(vaultImpl);
        address strategyImpl = address(new BasisStrategy());
        strategyBeacon.upgradeTo(strategyImpl);
    }
}
