// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AccountingLogic} from "src/libraries/logic/AccountingLogic.sol";
import {InchAggregatorV6Logic} from "src/libraries/logic/InchAggregatorV6Logic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

library OperatorLogic {
    using Math for uint256;
    using SafeERC20 for IERC20;

    struct UtilizeParams {
        uint256 amount;
        uint256 targetLeverage;
        DataTypes.StrategyStatus status;
        DataTypes.SwapType swapType;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyStateChache cache;
        bytes swapData;
    }

    function executeUtilize(UtilizeParams memory params)
        external
        returns (
            bool success,
            uint256 amountOut,
            DataTypes.StrategyStateChache memory,
            IPositionManager.AdjustPositionParams memory
        )
    {
        uint256 idleAssets = AccountingLogic.getIdleAssets(params.addr.asset, params.cache);
        uint256 pendingUtilization = getPendingUtilization(params.addr.asset, params.cache, params.targetLeverage);
        params.amount = params.amount > pendingUtilization ? pendingUtilization : params.amount;
        params.amount = params.amount > idleAssets ? idleAssets : params.amount;

        if (params.amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        if (params.swapType == DataTypes.SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(
                params.amount, params.addr.asset, params.addr.product, true, params.swapData
            );
        } else {
            // @consider: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        IPositionManager.AdjustPositionParams memory adjustPositionParams;
        if (success) {
            uint256 collateralDeltaAmount;
            if (params.cache.pendingIncreaseCollateral > 0) {
                collateralDeltaAmount = params.cache.pendingIncreaseCollateral.mulDiv(params.amount, pendingUtilization);
                params.cache.pendingIncreaseCollateral -= collateralDeltaAmount;
            }
            params.cache.pendingUtilization -= params.amount;
            adjustPositionParams = IPositionManager.AdjustPositionParams({
                sizeDeltaInTokens: amountOut,
                collateralDeltaAmount: collateralDeltaAmount,
                isIncrease: true
            });
        }
        return (success, amountOut, params.cache, adjustPositionParams);
    }

    function executeDeutilize(UtilizeParams memory params)
        external
        returns (
            bool success,
            uint256 amountOut,
            DataTypes.StrategyStateChache memory,
            IPositionManager.AdjustPositionParams memory
        )
    {
        uint256 productBalance = IERC20(params.addr.product).balanceOf(address(this));

        // actual deutilize amount is min of amount, product balance and pending deutilization
        params.amount =
            params.amount > params.cache.pendingDeutilization ? params.cache.pendingDeutilization : params.amount;
        params.amount = params.amount > productBalance ? productBalance : params.amount;

        // can only deutilize when amount is positive
        if (params.amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        if (params.swapType == DataTypes.SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(
                params.amount, params.addr.asset, params.addr.product, true, params.swapData
            );
        } else {
            // @consider: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        IPositionManager.AdjustPositionParams memory adjustPositionParams;
        if (success) {
            if (params.status == DataTypes.StrategyStatus.IDLE) {
                params.cache.assetsToWithdraw += amountOut;
                params.cache.totalPendingWithdraw -= amountOut;
                params.cache.withdrawnFromSpot += amountOut;
                adjustPositionParams = IPositionManager.AdjustPositionParams({
                    sizeDeltaInTokens: params.amount,
                    collateralDeltaAmount: 0,
                    isIncrease: false
                });
            }
        }
    }

    function getPendingUtilization(address asset, DataTypes.StrategyStateChache memory cache, uint256 targetLeverage)
        external
        view
        returns (uint256)
    {
        uint256 idleAssets = AccountingLogic.getIdleAssets(asset, cache);
        return idleAssets.mulDiv(targetLeverage, Constants.FLOAT_PRECISION + targetLeverage);
    }

    /// @notice product amount to be deutilized to process the totalPendingWithdraw amount
    ///
    /// @dev the following equations are guaranteed when deutilizing to withdraw
    /// pendingDeutilizationInAsset + collateralDeltaToDecrease = totalPendingWithdraw
    /// collateralDeltaToDecrease = positionNetBalance * pendingDeutilization / positionSizeInTokens
    /// pendingDeutilizationInAsset + positionNetBalance * pendingDeutilization / positionSizeInTokens = totalPendingWithdraw
    /// pendingDeutilizationInAsset = pendingDeutilization * productPrice / assetPrice
    /// pendingDeutilization * productPrice / assetPrice + positionNetBalance * pendingDeutilization / positionSizeInTokens =
    /// = totalPendingWithdraw
    /// pendingDeutilization * (productPrice / assetPrice + positionNetBalance / positionSizeInTokens) = totalPendingWithdraw
    /// pendingDeutilization * (productPrice * positionSizeInTokens + assetPrice * positionNetBalance) /
    /// / (assetPrice * positionSizeInTokens) = totalPendingWithdraw
    /// pendingDeutilization * (positionSizeUsd + positionNetBalanceUsd) / (assetPrice * positionSizeInTokens) = totalPendingWithdraw
    /// pendingDeutilization = totalPendingWithdraw * assetPrice * positionSizeInTokens / (positionSizeUsd + positionNetBalanceUsd)
    /// pendingDeutilization = positionSizeInTokens * totalPendingWithdrawUsd / (positionSizeUsd + positionNetBalanceUsd)
    /// pendingDeutilization = positionSizeInTokens *
    /// * (totalPendingWithdrawUsd/assetPrice) / (positionSizeUsd/assetPrice + positionNetBalanceUsd/assetPrice)
    /// pendingDeutilization = positionSizeInTokens * totalPendingWithdraw / (positionSizeInAssets + positionNetBalance)
    function getPendingDeutilization(
        DataTypes.StrategyAddresses memory addr,
        DataTypes.StrategyStateChache memory cache
    ) external view returns (uint256) {
        uint256 positionNetBalance = IPositionManager(addr.positionManager).positionNetBalance();
        uint256 positionSizeInTokens = IPositionManager(addr.positionManager).positionSizeInTokens();
        uint256 positionSizeInAssets =
            IOracle(addr.oracle).convertTokenAmount(addr.product, addr.asset, positionSizeInTokens);

        if (positionSizeInAssets == 0 && positionNetBalance == 0) return 0;

        return positionSizeInTokens.mulDiv(_getTotalPendingWithdraw(cache), positionSizeInAssets + positionNetBalance);
    }

    function getPendingIncreaseCollateral(
        address asset,
        uint256 targetLeverage,
        DataTypes.StrategyStateChache memory cache
    ) external view returns (uint256) {
        uint256 idleAssets = AccountingLogic.getIdleAssets(asset, cache);
        return
            idleAssets.mulDiv(Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + targetLeverage, Math.Rounding.Ceil);
    }

    function _getTotalPendingWithdraw(DataTypes.StrategyStateChache memory cache) internal pure returns (uint256) {
        return cache.accRequestedWithdrawAssets - cache.proccessedWithdrawAssets;
    }
}
