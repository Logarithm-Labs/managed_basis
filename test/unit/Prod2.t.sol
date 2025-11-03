// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";

contract Prod2Test is Test {
    LogarithmVault public vault = LogarithmVault(0xe5fc579f20C2dbffd78a92ddD124871a35519659);
    address depositor = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address usdcOwner = 0xf89d7b9c864f589bbF53a82105107622B35EaA40;

    function test_run() public {
        vm.createSelectFork("arbitrum_one");
        bytes32 withdrawKey = vault.getWithdrawKey(depositor, 0);
        console.log("withdrawKey", vm.toString(withdrawKey));
        LogarithmVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        console.log("requestedAssets", vm.toString(request.requestedAssets));
        console.log("accRequestedWithdrawAssets", vm.toString(request.accRequestedWithdrawAssets));
        console.log("requestTimestamp", vm.toString(request.requestTimestamp));
        console.log("owner", request.owner);
        console.log("receiver", request.receiver);
        console.log("isPrioritized", request.isPrioritized);
        console.log("isClaimed", request.isClaimed);

        uint256 vaultBalance = IERC20(USDC).balanceOf(address(vault));
        uint256 balDelta = request.requestedAssets - vaultBalance;
        console.log("balDelta", vm.toString(balDelta));
        console.log("vaultBalance", vm.toString(vaultBalance));
        uint256 assetsToClaim = vault.assetsToClaim();
        console.log("assetsToClaim", vm.toString(assetsToClaim));
        uint256 processedWithdrawAssets = vault.processedWithdrawAssets();
        console.log("processedWithdrawAssets", vm.toString(processedWithdrawAssets));

        vm.startPrank(usdcOwner);
        IERC20(USDC).approve(address(vault), type(uint256).max);
        IERC20(USDC).transfer(address(vault), 1_000 * 1e6);
        vm.stopPrank();

        processedWithdrawAssets = vault.processedWithdrawAssets();
        console.log("processedWithdrawAssets", vm.toString(processedWithdrawAssets));
        assetsToClaim = vault.assetsToClaim();
        console.log("assetsToClaim", vm.toString(assetsToClaim));

        vaultBalance = IERC20(USDC).balanceOf(address(vault));
        console.log("vaultBalance", vm.toString(vaultBalance));

        vm.startPrank(depositor);
        vault.claim(withdrawKey);
    }

    function test_custome_oracle_stop() public {
        vm.createSelectFork("arbitrum_one", 396245422);
        LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
        vm.startPrank(oracle.owner());
        oracle.upgradeToAndCall(address(new LogarithmOracle()), "");
        vm.stopPrank();
        LogarithmVault vitualVault = LogarithmVault(Arb.VAULT_HL_USDC_VIRTUAL);
        uint256 totalAssets = vitualVault.totalAssets();
        console.log("totalAssets", vm.toString(totalAssets));
    }
}
