// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";

contract UpgradeVaultScript is Script {
    UpgradeableBeacon public vaultBeacon = UpgradeableBeacon(0x221b1b60c3a794D58D47C0916579833ea834aCC8);
    LogarithmVault public gmxVault = LogarithmVault(0x4B57c9c6B58a454Def3Ad5AD0C15cF4974c818DE);
    LogarithmVault public hlVault = LogarithmVault(0x6ef9500175c6ABC3952F3DFB86dE96ACD151813B);

    function run() public {
        vm.startBroadcast();
        // upgrade vault beacon
        address vaultImpl = address(new LogarithmVault());
        vaultBeacon.upgradeTo(vaultImpl);
        gmxVault.setDepositLimits(type(uint256).max, type(uint256).max);
        hlVault.setDepositLimits(type(uint256).max, type(uint256).max);
    }
}
