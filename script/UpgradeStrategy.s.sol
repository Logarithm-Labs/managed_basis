// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DataProvider} from "src/DataProvider.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";

contract UpgradeStrategyScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0xA610080Bf93CC031492a29D09DBC8b234F291ea7);
    BasisStrategy strategy = BasisStrategy(0x166350f9b64ED99B2Aa92413A773aDCEDa1E1438);

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        beacon.upgradeTo(strategyImpl);
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
        console.log("hedgeManagerKeepNeeded: ", state.hedgeManagerKeepNeeded);
        console.log("processingRebalanceDown: ", state.processingRebalanceDown);
        console.log("");
    }
}
