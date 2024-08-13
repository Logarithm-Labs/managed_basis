// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DataProvider} from "src/DataProvider.sol";

contract ProdTest is Test {
    using Math for uint256;

    uint256 PRECISION = 1e18;

    ManagedBasisStrategy public strategy = ManagedBasisStrategy(0x75032ea6f276DE687a4c7cd82BE3b91E2D321ed1);
    DataProvider public dataProvider = DataProvider(0x8fc78eD7Bec63d40bcd1e18A748c36cdC69C3f91);
    OffChainPositionManager public positionManager;
    address public asset;
    address public product;

    function setUp() public {
        asset = strategy.asset();
        product = strategy.product();
        positionManager = OffChainPositionManager(strategy.positionManager());
    }

    function test_run() public {
        bytes memory data =
            hex"b05244420000000000000000000000000000000000000000000000000013a62f4b23bbab0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001e807ed2379000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd0900000000000000000000000082af49447d8a07e3bd95bd0d56f35241523fbab1000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd0900000000000000000000000075032ea6f276de687a4c7cd82be3b91e2d321ed10000000000000000000000000000000000000000000000000013a62f4b23bbab0000000000000000000000000000000000000000000000000000000000e116db00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000008100000000000000000000000000000000000000000000000000000000006302a00000000000000000000000000000000000000000000000000000000000e116dbee63c1e581b1026b8e7276e7ac75410f1fcbbe21796e8f752682af49447d8a07e3bd95bd0d56f35241523fbab1111111125421ca6dc452d289314280a0f8842a65000000000000000000000000000000000000000000000000000000000000002b01b08a000000000000000000000000000000000000000000000000";
        vm.startPrank(0x78057a43dDc57792340BC19E50e1011F8DAdEd01);
        (bool success,) = address(strategy).call(data);
    }

    function test_state() public view {
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategy));
        _logState(state);
    }

    function _logState(DataProvider.StrategyState memory state) internal view {
        console.log("===================");
        console.log("STRATEGY STATE");
        console.log("===================");
        console.log("strategyStatus", state.strategyStatus);
        console.log("totalSupply", state.totalSupply);
        console.log("totalAssets", state.totalAssets);
        console.log("utilizedAssets", state.utilizedAssets);
        console.log("idleAssets", state.idleAssets);
        console.log("assetBalance", state.assetBalance);
        console.log("productBalance", state.productBalance);
        console.log("productValueInAsset", state.productValueInAsset);
        console.log("assetsToWithdraw", state.assetsToWithdraw);
        console.log("assetsToClaim", state.assetsToClaim);
        console.log("totalPendingWithdraw", state.totalPendingWithdraw);
        console.log("pendingIncreaseCollateral", state.pendingIncreaseCollateral);
        console.log("pendingDecreaseCollateral", state.pendingDecreaseCollateral);
        console.log("pendingUtilization", state.pendingUtilization);
        console.log("pendingDeutilization", state.pendingDeutilization);
        console.log("accRequestedWithdrawAssets", state.accRequestedWithdrawAssets);
        console.log("proccessedWithdrawAssets", state.proccessedWithdrawAssets);
        console.log("positionNetBalance", state.positionNetBalance);
        console.log("positionLeverage", state.positionLeverage);
        console.log("positionSizeInTokens", state.positionSizeInTokens);
        console.log("positionSizeInAsset", state.positionSizeInAsset);
        console.log("positionManagerBalance", state.positionManagerBalance);
        console.log("processingRebalance", state.processingRebalance);
        console.log("upkeepNeeded", state.upkeepNeeded);
        console.log("rebalanceUpNeeded", state.rebalanceUpNeeded);
        console.log("rebalanceDownNeeded", state.rebalanceDownNeeded);
        console.log("deleverageNeeded", state.deleverageNeeded);
        console.log("rehedgeNeeded", state.rehedgeNeeded);
        console.log("positionManagerNeedKeep", state.positionManagerKeepNeeded);
        console.log("");
    }
}
