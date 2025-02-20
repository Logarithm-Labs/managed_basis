// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";

contract UpgradeVaultScript is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        UpgradeableBeacon beacon = UpgradeableBeacon(Arb.BEACON_VAULT);
        beacon.upgradeTo(address(new LogarithmVault()));
        vm.stopBroadcast();
    }
}
