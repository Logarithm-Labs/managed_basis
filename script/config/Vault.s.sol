// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {Script} from "forge-std/Script.sol";

contract UpgradeVault is Script {
    function run() public {
        vm.startBroadcast();
        address vaultImpl = address(new LogarithmVault());
        UpgradeableBeacon vaultBeacon = UpgradeableBeacon(Arb.BEACON_VAULT);
        vaultBeacon.upgradeTo(vaultImpl);
        vm.stopBroadcast();
    }
}
