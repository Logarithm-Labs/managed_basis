// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";
import {DataProvider} from "src/DataProvider.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategyForEtch} from "test/mock/BasisStrategyForEtch.sol";

contract ProdTest is Test {
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant sender = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    LogarithmVault constant vault = LogarithmVault(0x8bbc586FD37c492566b3F65e368446e238dd7326);
    BasisStrategy constant strategy = BasisStrategy(0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1);
    DataProvider constant dataProvider = DataProvider(0xaB4e7519E6f7FC80A5AB255f15990444209cE159);
    OffChainPositionManager constant positionManager =
        OffChainPositionManager(0x01B407B5b9Eb00BFe23FB39424Dbbe887810ffEb);
    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    string constant rpcUrl = "https://arb-mainnet.g.alchemy.com/v2/PeyMa7ljzBjqJxkH6AnLfVH8zRWOtE1n";

    bytes data = hex"bd66528a3c2a45c9fa3439fdc17b5bb4ac31bd9926877f3e44ae24741f232b87df204c6a";
    bytes32 request = 0x3c2a45c9fa3439fdc17b5bb4ac31bd9926877f3e44ae24741f232b87df204c6a;

    function test_run() public {
        vm.createSelectFork(rpcUrl, 250085385);
        vm.startPrank(operator);

        UpgradeableBeacon strategyBeacon = UpgradeableBeacon(0xc14Da39589AB11746A46939e7Ba4e58Cb43d3b24);
        address implemetation = strategyBeacon.implementation();
        address etchImpl = address(new BasisStrategyForEtch());
        vm.etch(implemetation, etchImpl.code);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        strategy.deutilize(pendingDeutilization, BasisStrategy.SwapType.MANUAL, "");
    }

    function test_getState() public {
        vm.createSelectFork(rpcUrl, 250085398);
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
