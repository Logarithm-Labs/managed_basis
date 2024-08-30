// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";
import {DataProvider} from "src/DataProvider.sol";

contract ProdTest is Test {
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    LogarithmVault constant vault = LogarithmVault(0x8bbc586FD37c492566b3F65e368446e238dd7326);
    BasisStrategy constant strategy = BasisStrategy(0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1);
    DataProvider constant dataProvider = DataProvider(0xB03B9451686Dda03c5b3882dBb6860AD047716d7);

    string constant rpcUrl = "https://arb-mainnet.g.alchemy.com/v2/PeyMa7ljzBjqJxkH6AnLfVH8zRWOtE1n";

    bytes data =
        hex"b052444200000000000000000000000000000000000000000000000000000920b5db77ae000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000";

    function test_run() public {
        vm.createSelectFork(rpcUrl, 247949926);
        vm.startPrank(operator);

        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategy));
        console.log("pendingDeutilization: ", state.pendingDeutilization);

        (bool success,) = address(strategy).call(data);
        require(success);
    }

    function test_getState() public {
        vm.createSelectFork(rpcUrl, 247976586);
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
        console.log("proccessedWithdrawAssets: ", state.proccessedWithdrawAssets);
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
