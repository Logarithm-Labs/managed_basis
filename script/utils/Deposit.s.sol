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
        address vault = Arb.VAULT_HL_USDC_LINK;
        address asset = ArbAddresses.USDC;
        address depositor = 0xdAC79C91164127b1E48e674dB631AfEdcc57486A;
        uint256 amount = IERC20(asset).balanceOf(depositor);
        IERC20(asset).approve(vault, amount);
        LogarithmVault(vault).deposit(amount, depositor);
        vm.stopBroadcast();

        uint256 shares = IERC20(vault).balanceOf(depositor);
        console.log("Shares: %s", vm.toString(shares));
    }
}
