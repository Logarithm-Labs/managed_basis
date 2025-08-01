// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";

import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract DepositScript is Script {
    function run() public {
        vm.startBroadcast();
        address vault = Arb.VAULT_HL_USDC_VIRTUAL;
        address asset = ArbAddresses.USDC;
        address depositor = 0xF27cAf44644a4c774CDB2e6acC786c6B0fCB8dB2;
        uint256 amount = IERC20(asset).balanceOf(depositor);
        IERC20(asset).approve(vault, amount);
        LogarithmVault(vault).deposit(amount, depositor);
        vm.stopBroadcast();

        uint256 shares = IERC20(vault).balanceOf(depositor);
        console.log("Shares: %s", vm.toString(shares));
    }
}

contract WithdrawScript is Script {
    function run() public {
        vm.startBroadcast();
        address vault = Arb.VAULT_HL_USDC_VIRTUAL;
        address asset = ArbAddresses.USDC;
        address depositor = 0xF27cAf44644a4c774CDB2e6acC786c6B0fCB8dB2;
        uint256 idleAssets = LogarithmVault(Arb.VAULT_HL_USDC_VIRTUAL).idleAssets();
        console.log("idleAssets", vm.toString(idleAssets));

        uint256 balBefore = IERC20(asset).balanceOf(depositor);
        console.log("balBefore", vm.toString(balBefore));
        IERC20(vault).approve(vault, type(uint256).max);
        LogarithmVault(vault).withdraw(idleAssets, depositor, depositor);
        uint256 balAfter = IERC20(asset).balanceOf(depositor);
        console.log("balAfter", vm.toString(balAfter));
        vm.stopBroadcast();

        uint256 shares = IERC20(vault).balanceOf(depositor);
        console.log("Shares: %s", vm.toString(shares));
    }
}
