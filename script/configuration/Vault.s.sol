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

contract SetDepositLimitScript is Script {
    uint256 constant userDepositLimit = 1_000 * 10 ** 6;
    uint256 constant vaultDepositLimit = type(uint256).max;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        LogarithmVault wethVault = LogarithmVault(Arb.VAULT_HL_USDC_WETH);
        LogarithmVault wbtcVault = LogarithmVault(Arb.VAULT_HL_USDC_WBTC);
        LogarithmVault dogeVault = LogarithmVault(Arb.VAULT_HL_USDC_DOGE);
        LogarithmVault virtualVault = LogarithmVault(Arb.VAULT_HL_USDC_VIRTUAL);
        wethVault.setDepositLimits(userDepositLimit, vaultDepositLimit);
        wbtcVault.setDepositLimits(userDepositLimit, vaultDepositLimit);
        dogeVault.setDepositLimits(userDepositLimit, vaultDepositLimit);
        virtualVault.setDepositLimits(userDepositLimit, vaultDepositLimit);
        vm.stopBroadcast();
    }
}
