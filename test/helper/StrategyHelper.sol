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
    bool clearReservedExecutionCost;
}

contract StrategyHelper {
    BasisStrategy strategy;
    LogarithmVault vault;

    struct DecodedPerformData {
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        bool clearProcessingRebalanceDown;
        int256 hedgeDeviationInTokens;
        bool hedgeManagerNeedKeep;
        bool rebalanceUpNeeded;
        bool clearReservedExecutionCost;
    }

    constructor(address _strategy) {
        strategy = BasisStrategy(_strategy);
        vault = LogarithmVault(strategy.vault());
    }

    function getStrategyState() public view returns (StrategyState memory state) {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        DecodedPerformData memory decodedPerformData;
        if (performData.length > 0) {
            decodedPerformData = decodePerformData(performData);
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
        state.rebalanceUpNeeded = decodedPerformData.rebalanceUpNeeded;
        state.rebalanceDownNeeded = decodedPerformData.rebalanceDownNeeded;
        state.deleverageNeeded = decodedPerformData.deleverageNeeded;
        state.rehedgeNeeded = decodedPerformData.hedgeDeviationInTokens == 0 ? false : true;
        state.hedgeManagerKeepNeeded = decodedPerformData.hedgeManagerNeedKeep;
        state.clearReservedExecutionCost = decodedPerformData.clearReservedExecutionCost;
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
        console.log("clearReservedExecutionCost", state.clearReservedExecutionCost);
        console.log("");
    }

    function decodePerformData(bytes memory performData)
        public
        pure
        returns (DecodedPerformData memory decodedPerformData)
    {
        BasisStrategy.InternalCheckUpkeepResult memory result =
            abi.decode(performData, (BasisStrategy.InternalCheckUpkeepResult));

        decodedPerformData.clearProcessingRebalanceDown = result.clearProcessingRebalanceDown;
        decodedPerformData.hedgeDeviationInTokens = result.hedgeDeviationInTokens;
        decodedPerformData.hedgeManagerNeedKeep = result.hedgeManagerNeedKeep;
        decodedPerformData.clearReservedExecutionCost = result.clearReservedExecutionCost;

        decodedPerformData.rebalanceDownNeeded =
            result.emergencyDeutilizationAmount > 0 || result.deltaCollateralToIncrease > 0;
        decodedPerformData.deleverageNeeded = result.emergencyDeutilizationAmount > 0;
        decodedPerformData.rebalanceUpNeeded = result.deltaCollateralToDecrease > 0;
    }
}
