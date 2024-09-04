// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DataProvider} from "src/DataProvider.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";

contract UpgradeStrategyScript is Script {
    DataProvider constant dataProvider = DataProvider(0xaB4e7519E6f7FC80A5AB255f15990444209cE159);
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0xc14Da39589AB11746A46939e7Ba4e58Cb43d3b24);
    BasisStrategy constant strategy = BasisStrategy(0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1);

    function run() public {
        DataProvider.StrategyState memory state0 = dataProvider.getStrategyState(address(strategy));
        _logState(state0);

        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        beacon.upgradeTo(strategyImpl);
        // strategy.reinitialize();

        DataProvider.StrategyState memory state1 = dataProvider.getStrategyState(address(strategy));
        _logState(state1);
    }

    function _logState(DataProvider.StrategyState memory state) internal view {
        // log all strategy state
        console.log("===================");
        console.log("STRATEGY STATE");
        console.log("===================");
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
        console.log("");
    }
}
