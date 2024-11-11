// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {DataProvider} from "src/DataProvider.sol";
import {OffChainPositionManager} from "src/position/offchain/OffChainPositionManager.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {ArbGasInfoMock} from "test/mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "test/mock/ArbSysMock.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";

contract ProdTest is Test {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    address constant operator = 0xe7263f18e278ea0550FaD97DDF898d134483EfC6;
    address constant sender = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    LogarithmVault vault = LogarithmVault(0x4B57c9c6B58a454Def3Ad5AD0C15cF4974c818DE);
    BasisStrategy constant strategy = BasisStrategy(0x166350f9b64ED99B2Aa92413A773aDCEDa1E1438);
    DataProvider constant dataProvider = DataProvider(0x8B92925a63B580A9bBD9e0D8D185aDea850160A8);
    OffChainPositionManager constant positionManager =
        OffChainPositionManager(0x9901A001995230C20ba227bD006CFE9D4B3bee34);

    UpgradeableBeacon strategyBeacon = UpgradeableBeacon(0xA610080Bf93CC031492a29D09DBC8b234F291ea7);
    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    string constant rpcUrl = "https://arb-mainnet.g.alchemy.com/v2/PeyMa7ljzBjqJxkH6AnLfVH8zRWOtE1n";

    bytes call_data =
        hex"000000000000000000000000000000000000000000000000003eeb26175e9bfa0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e807ed2379000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd0900000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd09000000000000000000000000166350f9b64ed99b2aa92413a773adceda1e1438000000000000000000000000000000000000000000000000003eeb26175e9bfa000000000000000000000000000000000000000000000000000000000283659000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000008100000000000000000000000000000000000000000000000000000000006302a00000000000000000000000000000000000000000000000000000000002836590ee63c1e5817fcdc35463e3770c2fb992716cd070b63540b94782af49447d8a07e3bd95bd0d56f35241523fbab1111111125421ca6dc452d289314280a0f8842a6500000000000000000000000000000000000000000000000000000000000000cc51b9ac000000000000000000000000000000000000000000000000";
    bytes32 request = 0x3c2a45c9fa3439fdc17b5bb4ac31bd9926877f3e44ae24741f232b87df204c6a;

    function test_run() public {
        vm.createSelectFork(rpcUrl, 262630522);

        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);

        vm.startPrank(owner);
        strategyBeacon.upgradeTo(address(new BasisStrategy()));
        (, uint256 deutilization) = strategy.pendingUtilizations();
        console.log("deutilization", deutilization);
        (uint256 amount, ISpotManager.SwapType swapType, bytes memory swapData) =
            abi.decode(call_data, (uint256, ISpotManager.SwapType, bytes));
        console.log("amount", amount);
        vm.startPrank(operator);
        strategy.deutilize(amount, swapType, swapData);
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
