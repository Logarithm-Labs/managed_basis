// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";

contract UpgradeVaultScript is Script {
    UpgradeableBeacon public vaultBeacon = UpgradeableBeacon(0x6e77994e0bADCF3421d1Fb0Fb8b523FCe0c989Ee);
    LogarithmVault public vault = LogarithmVault(0xDe56f312464F95C06EeCF4391f930877Fe4D7d93);

    function run() public {
        vm.startBroadcast();
        // upgrade vault beacon
        address vaultImpl = address(new LogarithmVault());
        vaultBeacon.upgradeTo(vaultImpl);
    }
}
