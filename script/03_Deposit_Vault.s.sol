// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {UpgradeableBeacon} from
    "lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract DepositScript is Script {
    function run() public {
        LogarithmVault vault = LogarithmVault(0xe5fc579f20C2dbffd78a92ddD124871a35519659);
        address depositor = 0xdAC79C91164127b1E48e674dB631AfEdcc57486A;
        address USDC = vault.asset();
        uint256 balBefore = IERC20(USDC).balanceOf(depositor);

        vm.startBroadcast();
        IERC20(USDC).approve(address(vault), balBefore);
        vault.deposit(balBefore, depositor);
        vm.stopBroadcast();

        uint256 balAfter = IERC20(USDC).balanceOf(depositor);
        console.log("balAfter", vm.toString(balAfter));
        uint256 shares = IERC20(address(vault)).balanceOf(depositor);
        console.log("shares", vm.toString(shares));
        uint256 totalAssets = vault.totalAssets();
        console.log("totalAssets", vm.toString(totalAssets));
        uint256 totalSupply = vault.totalSupply();
        console.log("totalSupply", vm.toString(totalSupply));
    }
}
