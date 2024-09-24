// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DataProvider} from "src/DataProvider.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";

contract UpgradeStrategyScript is Script {
    // DataProvider constant dataProvider = DataProvider(0xaB4e7519E6f7FC80A5AB255f15990444209cE159);
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0x8BDB3Ece7e238E96Cbe3645dfAd01DD5f160F587);
    BasisStrategy constant strategy = BasisStrategy(0x1231fA1067806797cF3C551745Efb30cE53aE735);

    address public operator = 0xe7263f18e278ea0550FaD97DDF898d134483EfC6;

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        beacon.upgradeTo(strategyImpl);
        strategy.reinitialize();
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
        console.log("");
    }
}
