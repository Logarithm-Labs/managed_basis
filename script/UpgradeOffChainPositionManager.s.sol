// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DataProvider} from "src/DataProvider.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";

contract UpgradeOffChainPositionManagerScript is Script {
    DataProvider constant dataProvider = DataProvider(0xaB4e7519E6f7FC80A5AB255f15990444209cE159);
    OffChainPositionManager constant positionManager =
        OffChainPositionManager(0x01B407B5b9Eb00BFe23FB39424Dbbe887810ffEb);
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0xe5227e7432c9AdEE1404885c5aaD506954A08A74);
    address constant strategy = 0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1;
    LogarithmVault constant vault = LogarithmVault(0x8bbc586FD37c492566b3F65e368446e238dd7326);

    bytes32 request = 0x3c2a45c9fa3439fdc17b5bb4ac31bd9926877f3e44ae24741f232b87df204c6a;

    function run() public {
        vm.startBroadcast();
        address impl = address(new OffChainPositionManager());
        beacon.upgradeTo(impl);
        positionManager.reinitialize();

        DataProvider.StrategyState memory state0 = dataProvider.getStrategyState(address(strategy));
        _logState(state0);

        require(vault.isClaimable(request));
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
