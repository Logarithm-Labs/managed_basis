// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";
import {DataProvider} from "src/DataProvider.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ArbGasInfoMock} from "test/mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "test/mock/ArbSysMock.sol";

contract ProdTest is Test {
    address constant operator = 0xe7263f18e278ea0550FaD97DDF898d134483EfC6;
    address constant sender = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    LogarithmVault constant vault = LogarithmVault(0xDe56f312464F95C06EeCF4391f930877Fe4D7d93);
    BasisStrategy constant strategy = BasisStrategy(0x1231fA1067806797cF3C551745Efb30cE53aE735);
    DataProvider constant dataProvider = DataProvider(0xaB4e7519E6f7FC80A5AB255f15990444209cE159);
    OffChainPositionManager constant positionManager =
        OffChainPositionManager(0x1ec52Db6A9C7B175507Ec3fAFb13b71cFC4e700f);
    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    string constant rpcUrl = "https://arb-mainnet.g.alchemy.com/v2/PeyMa7ljzBjqJxkH6AnLfVH8zRWOtE1n";

    bytes call_data =
        hex"b05244420000000000000000000000000000000000000000000000000040c3e9a667cad000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008883800a8e00000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab10000000000000000000000000000000000000000000000000040c3e9a667cad0000000000000000000000000000000000000000000000000000000000288191b2880000000000000000000006f38e884725a116c9c7fbf208e79fe8828a2595f2b01b08a000000000000000000000000000000000000000000000000";
    bytes32 request = 0x3c2a45c9fa3439fdc17b5bb4ac31bd9926877f3e44ae24741f232b87df204c6a;

    function test_run() public {
        vm.createSelectFork(rpcUrl, 252130457);

        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);

        vm.startPrank(operator);
        strategy.deutilize(18229767668373200, BasisStrategy.SwapType.MANUAL, "");

        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategy));
        _logState(state);
    }

    function test_getState() public {
        vm.createSelectFork(rpcUrl, 252130457);
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategy));
        _logState(state);
    }

    function _logState(DataProvider.StrategyState memory state) internal view {
        // log all strategy state
        console.log("strategyStatus: ", state.strategyStatus);
        console.log("totalSupply: ", state.totalSupply);
        console.log("totalAssets: ", state.totalAssets);
        console.log("utilizedAssets: ", state.utilizedAssets);
        console.log("idleAssets: ", state.idleAssets);
        console.log("assetBalance: ", state.assetBalance);
        console.log("productBalance: ", state.productBalance);
        console.log("productValueInAsset: ", state.productValueInAsset);
        console.log("assetsToWithdraw: ", state.assetsToWithdraw);
        console.log("assetsToClaim: ", state.assetsToClaim);
        console.log("totalPendingWithdraw: ", vm.toString(state.totalPendingWithdraw));
        console.log("pendingIncreaseCollateral: ", state.pendingIncreaseCollateral);
        console.log("pendingDecreaseCollateral: ", state.pendingDecreaseCollateral);
        console.log("pendingUtilization: ", state.pendingUtilization);
        console.log("pendingDeutilization: ", state.pendingDeutilization);
        console.log("accRequestedWithdrawAssets: ", state.accRequestedWithdrawAssets);
        console.log("processedWithdrawAssets: ", state.processedWithdrawAssets);
        console.log("positionNetBalance: ", state.positionNetBalance);
        console.log("positionLeverage: ", state.positionLeverage);
        console.log("positionSizeInTokens: ", state.positionSizeInTokens);
        console.log("upkeepNeeded: ", state.upkeepNeeded);
        console.log("rebalanceUpNeeded: ", state.rebalanceUpNeeded);
        console.log("rebalanceDownNeeded: ", state.rebalanceDownNeeded);
        console.log("deleverageNeeded: ", state.deleverageNeeded);
        console.log("decreaseCollateral: ", state.decreaseCollateral);
        console.log("rehedgeNeeded: ", state.rehedgeNeeded);
        console.log("positionManagerKeepNeeded: ", state.positionManagerKeepNeeded);
        console.log("processingRebalanceDown: ", state.processingRebalanceDown);
    }
}
