// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {BasisStrategy} from "src/BasisStrategy.sol";
// import {ILogarithmVault} from "src/interfaces/ILogarithmVault.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";
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
        int256 totalPendingWithdraw;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        uint256 positionNetBalance;
        uint256 positionLeverage;
        uint256 positionSizeInTokens;
        bool upkeepNeeded;
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        bool decreaseCollateral;
        bool rehedgeNeeded;
        bool positionManagerKeepNeeded;
        bool processingRebalanceDown;
    }

    function getStrategyState(address _strategy) external view returns (StrategyState memory state) {
        BasisStrategy strategy = BasisStrategy(_strategy);
        IPositionManager positionManager = IPositionManager(strategy.positionManager());
        LogarithmVault vault = LogarithmVault(strategy.vault());
        IOracle oracle = IOracle(strategy.oracle());
        address asset = strategy.asset();
        address product = strategy.product();
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;
        bool decreaseCollateral;
        bool rebalanceUpNeeded;
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        if (performData.length > 0) {
            (
                rebalanceDownNeeded,
                deleverageNeeded,
                hedgeDeviationInTokens,
                positionManagerNeedKeep,
                decreaseCollateral,
                rebalanceUpNeeded
            ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool));
        }

        state.strategyStatus = uint8(strategy.strategyStatus());
        state.totalSupply = vault.totalSupply();
        state.totalAssets = vault.totalAssets();
        state.utilizedAssets = strategy.utilizedAssets();
        state.idleAssets = vault.idleAssets();
        state.assetBalance = IERC20(asset).balanceOf(address(vault)) + IERC20(asset).balanceOf(address(strategy));
        state.productBalance = IERC20(product).balanceOf(address(strategy));
        state.productValueInAsset = oracle.convertTokenAmount(product, asset, state.productBalance);
        state.assetsToWithdraw = IERC20(asset).balanceOf(address(strategy));
        state.assetsToClaim = vault.assetsToClaim();
        state.totalPendingWithdraw = vault.totalPendingWithdraw();
        state.pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        state.pendingDecreaseCollateral = strategy.pendingDecreaseCollateral();
        (state.pendingUtilization, state.pendingDeutilization) = strategy.pendingUtilizations();
        state.accRequestedWithdrawAssets = vault.accRequestedWithdrawAssets();
        state.proccessedWithdrawAssets = vault.proccessedWithdrawAssets();
        state.positionNetBalance = positionManager.positionNetBalance();
        state.positionLeverage = positionManager.currentLeverage();
        state.positionSizeInTokens = positionManager.positionSizeInTokens();
        state.upkeepNeeded = upkeepNeeded;
        state.rebalanceUpNeeded = rebalanceUpNeeded;
        state.rebalanceDownNeeded = rebalanceDownNeeded;
        state.deleverageNeeded = deleverageNeeded;
        state.decreaseCollateral = decreaseCollateral;
        state.rehedgeNeeded = hedgeDeviationInTokens == 0 ? false : true;
        state.positionManagerKeepNeeded = positionManagerNeedKeep;
        state.processingRebalanceDown = strategy.processingRebalance();
    }
}
