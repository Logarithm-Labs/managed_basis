// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

contract DataProvider {
    struct StrategyState {
        uint8 strategyStatus;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 utilizedAssets;
        uint256 idleAssets;
        uint256 assetBalance;
        uint256 productBalance;
        uint256 productValueInAsset;
        uint256 assetsToWithdraw;
        uint256 assetsToClaim;
        uint256 totalPendingWithdraw;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        uint256 positionNetBalance;
        uint256 positionLeverage;
        uint256 positionSizeInTokens;
        uint256 positionSizeInAsset;
        uint256 positionManagerBalance;
        bool processingRebalance;
        bool upkeepNeeded;
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        bool rehedgeNeeded;
        bool positionManagerKeepNeeded;
    }

    function getStrategyState(address _strategy) external view returns (StrategyState memory state) {
        ManagedBasisStrategy strategy = ManagedBasisStrategy(_strategy);
        IPositionManager positionManager = IPositionManager(strategy.positionManager());
        IOracle oracle = IOracle(strategy.oracle());
        address asset = strategy.asset();
        address product = strategy.product();
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;
        if (performData.length > 0) {
            (rebalanceDownNeeded, deleverageNeeded, hedgeDeviationInTokens, positionManagerNeedKeep, rebalanceUpNeeded,)
            = abi.decode(performData, (bool, bool, int256, bool, bool, uint256));
        }

        state.strategyStatus = uint8(strategy.strategyStatus());
        state.totalSupply = strategy.totalSupply();
        state.totalAssets = strategy.totalAssets();
        state.utilizedAssets = strategy.utilizedAssets();
        state.idleAssets = strategy.idleAssets();
        state.assetBalance = IERC20(asset).balanceOf(address(strategy));
        state.productBalance = IERC20(product).balanceOf(address(strategy));
        state.productValueInAsset = oracle.convertTokenAmount(product, asset, state.productBalance);
        state.assetsToWithdraw = strategy.assetsToWithdraw();
        state.assetsToClaim = strategy.assetsToClaim();
        state.totalPendingWithdraw = strategy.totalPendingWithdraw();
        state.pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        state.pendingDecreaseCollateral = strategy.pendingDecreaseCollateral();
        (state.pendingUtilization, state.pendingDeutilization) = strategy.pendingUtilizations();
        state.accRequestedWithdrawAssets = strategy.accRequestedWithdrawAssets();
        state.proccessedWithdrawAssets = strategy.proccessedWithdrawAssets();
        state.positionNetBalance = positionManager.positionNetBalance();
        state.positionLeverage = positionManager.currentLeverage();
        state.positionSizeInTokens = positionManager.positionSizeInTokens();
        state.positionSizeInAsset = oracle.convertTokenAmount(product, asset, state.positionSizeInTokens);
        state.positionManagerBalance = IERC20(asset).balanceOf(address(positionManager));

        state.processingRebalance = strategy.processingRebalance();
        state.upkeepNeeded = upkeepNeeded;
        state.rebalanceUpNeeded = rebalanceUpNeeded;
        state.rebalanceDownNeeded = rebalanceDownNeeded;
        state.deleverageNeeded = deleverageNeeded;
        state.rehedgeNeeded = hedgeDeviationInTokens == 0 ? false : true;
        state.positionManagerKeepNeeded = positionManagerNeedKeep;
    }
}
