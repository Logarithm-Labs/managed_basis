// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";

contract UpgradeScript is Script {
    function run() public {
        vm.startBroadcast();
        address vaultImpl = address(new LogarithmVault());
        UpgradeableBeacon vaultBeacon = UpgradeableBeacon(Arb.BEACON_VAULT);
        vaultBeacon.upgradeTo(vaultImpl);

        LogarithmVault vault = LogarithmVault(Arb.VAULT_HL_USDC_WBTC);
        address keeper = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
        vault.setSecurityManager(keeper);
    }
}
