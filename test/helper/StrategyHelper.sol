// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";

import {console2 as console} from "forge-std/console2.sol";

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
    uint256 pendingUtilization;
    uint256 pendingDeutilization;
    uint256 accRequestedWithdrawAssets;
    uint256 processedWithdrawAssets;
    uint256 positionNetBalance;
    uint256 positionLeverage;
    uint256 positionSizeInTokens;
    uint256 positionSizeInAsset;
    bool processingRebalance;
    bool upkeepNeeded;
    bool rebalanceUpNeeded;
    bool rebalanceDownNeeded;
    bool deleverageNeeded;
    bool rehedgeNeeded;
    bool hedgeManagerKeepNeeded;
}

contract StrategyHelper {
    BasisStrategy strategy;
    LogarithmVault vault;

    constructor(address _strategy) {
        strategy = BasisStrategy(_strategy);
        vault = LogarithmVault(strategy.vault());
    }

    function getStrategyState() public view returns (StrategyState memory state) {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        int256 hedgeDeviationInTokens;
        bool hedgeManagerNeedKeep;
        if (performData.length > 0) {
            (rebalanceDownNeeded, deleverageNeeded, hedgeDeviationInTokens, hedgeManagerNeedKeep, rebalanceUpNeeded) =
                decodePerformData(performData);
        }

        address asset = strategy.asset();
        address product = strategy.product();
        LogarithmOracle oracle = LogarithmOracle(strategy.oracle());
        IHedgeManager hedgeManager = IHedgeManager(strategy.hedgeManager());

        state.strategyStatus = uint8(strategy.strategyStatus());
        state.totalSupply = vault.totalSupply();
        state.totalAssets = vault.totalAssets();
        state.utilizedAssets = strategy.utilizedAssets();
        state.idleAssets = vault.idleAssets();
        state.assetBalance = IERC20(asset).balanceOf(address(vault)) + IERC20(asset).balanceOf(address(strategy));
        state.productBalance = ISpotManager(strategy.spotManager()).exposure();
        state.productValueInAsset = oracle.convertTokenAmount(product, asset, state.productBalance);
        state.assetsToWithdraw = IERC20(asset).balanceOf(address(strategy));
        state.assetsToClaim = vault.assetsToClaim();
        state.totalPendingWithdraw = vault.totalPendingWithdraw();
        (state.pendingUtilization, state.pendingDeutilization) = strategy.pendingUtilizations();
        state.accRequestedWithdrawAssets = vault.accRequestedWithdrawAssets();
        state.processedWithdrawAssets = vault.processedWithdrawAssets();
        state.positionNetBalance = hedgeManager.positionNetBalance();
        state.positionLeverage = hedgeManager.currentLeverage();
        state.positionSizeInTokens = hedgeManager.positionSizeInTokens();
        state.positionSizeInAsset = oracle.convertTokenAmount(product, asset, state.positionSizeInTokens);
        state.processingRebalance = strategy.processingRebalanceDown();

        state.upkeepNeeded = upkeepNeeded;
        state.rebalanceUpNeeded = rebalanceUpNeeded;
        state.rebalanceDownNeeded = rebalanceDownNeeded;
        state.deleverageNeeded = deleverageNeeded;
        state.rehedgeNeeded = hedgeDeviationInTokens == 0 ? false : true;
        state.hedgeManagerKeepNeeded = hedgeManagerNeedKeep;
    }

    function logStrategyState(string memory stateName, StrategyState memory state) public pure {
        console.log("===================");
        console.log(stateName);
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
        console.log("pendingUtilization", state.pendingUtilization);
        console.log("pendingDeutilization", state.pendingDeutilization);
        console.log("accRequestedWithdrawAssets", state.accRequestedWithdrawAssets);
        console.log("processedWithdrawAssets", state.processedWithdrawAssets);
        console.log("positionNetBalance", state.positionNetBalance);
        console.log("positionLeverage", state.positionLeverage);
        console.log("positionSizeInTokens", state.positionSizeInTokens);
        console.log("positionSizeInAsset", state.positionSizeInAsset);
        console.log("upkeepNeeded", state.upkeepNeeded);
        console.log("rebalanceUpNeeded", state.rebalanceUpNeeded);
        console.log("rebalanceDownNeeded", state.rebalanceDownNeeded);
        console.log("deleverageNeeded", state.deleverageNeeded);
        console.log("rehedgeNeeded", state.rehedgeNeeded);
        console.log("hedgeManagerNeedKeep", state.hedgeManagerKeepNeeded);
        console.log("processingRebalance", state.processingRebalance);
        console.log("");
    }

    function decodePerformData(bytes memory performData)
        public
        pure
        returns (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool hedgeManagerNeedKeep,
            bool rebalanceUpNeeded
        )
    {
        uint256 emergencyDeutilizationAmount;
        uint256 deltaCollateralToIncrease;
        bool clearProcessingRebalanceDown;
        uint256 deltaCollateralToDecrease;

        (
            emergencyDeutilizationAmount,
            deltaCollateralToIncrease,
            clearProcessingRebalanceDown,
            hedgeDeviationInTokens,
            hedgeManagerNeedKeep,
            deltaCollateralToDecrease
        ) = abi.decode(performData, (uint256, uint256, bool, int256, bool, uint256));

        rebalanceDownNeeded = emergencyDeutilizationAmount > 0 || deltaCollateralToIncrease > 0;
        deleverageNeeded = emergencyDeutilizationAmount > 0;
        rebalanceUpNeeded = deltaCollateralToDecrease > 0;
    }
}
