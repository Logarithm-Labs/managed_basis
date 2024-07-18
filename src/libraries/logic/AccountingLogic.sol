// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";

library AccountingLogic {
    using Math for uint256;

    struct PreviewParams {
        uint256 assetsOrShares; // assets in case of previewDeposit, shares in case of previewMint
        uint256 fee; // entryFee for previewDeposit & previewMing, exitFee for previewWithdraw & previewRedeem
        uint256 totalSupply;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyStateChache cache;
    }

    function getTotalAssets(DataTypes.StrategyAddresses memory addr, DataTypes.StrategyStateChache memory cache)
        public
        view
        returns (uint256, uint256, uint256)
    {
        uint256 utilizedAssets = getUtilizedAssets(addr);
        uint256 idleAssets = getIdleAssets(addr.asset, cache);

        // In the scenario where user tries to withdraw all of the remaining assets the volatility
        // of oracle price can create a situation where pending withdraw is greater then the sum of
        // idle and utilized assets. In this case we will return 0 as total assets.
        (, uint256 totalAssets) = (utilizedAssets + idleAssets).trySub(_getTotalPendingWithdraw(cache));
        return (utilizedAssets, idleAssets, totalAssets);
    }

    function getUtilizedAssets(DataTypes.StrategyAddresses memory addr) public view returns (uint256) {
        uint256 productBalance = IERC20(addr.product).balanceOf(address(this));
        uint256 productValueInAsset = IOracle(addr.oracle).convertTokenAmount(addr.product, addr.asset, productBalance);
        return productValueInAsset + IPositionManager(addr.positionManager).positionNetBalance();
    }

    // @optimize: consider providing only assetsToClaim and assetsToWithdraw as arguments (potentially as a struct)
    function getIdleAssets(address asset, DataTypes.StrategyStateChache memory cache) public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) - (cache.assetsToClaim + cache.assetsToWithdraw);
    }

    function getPreviewDeposit(PreviewParams memory params) external view returns (uint256 shares) {
        if (params.totalSupply == 0) {
            return params.assetsOrShares;
        }

        // calculate the amount of assets that will be utilized
        (, uint256 assetsToUtilize) = params.assetsOrShares.trySub(_getTotalPendingWithdraw(params.cache));
        (,, uint256 totalAssets) = getTotalAssets(params.addr, params.cache);

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            uint256 feeAmount = assetsToUtilize.mulDiv(params.fee, Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
            params.assetsOrShares -= feeAmount;
        }
        shares = _convertToShares(params.assetsOrShares, totalAssets, params.totalSupply, Math.Rounding.Floor);
    }

    function getPreviewMint(PreviewParams memory params) external view returns (uint256 assets) {
        if (params.totalSupply == 0) {
            return params.assetsOrShares;
        }

        // calculate amount of assets before applying entry fee
        (,, uint256 totalAssets) = getTotalAssets(params.addr, params.cache);
        assets = _convertToAssets(params.assetsOrShares, totalAssets, params.totalSupply, Math.Rounding.Ceil);

        // calculate amount of assets that will be utilized
        (, uint256 assetsToUtilize) = assets.trySub(_getTotalPendingWithdraw(params.cache));

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            // feeAmount / (assetsToUtilize + feeAmount) = entryCost
            // feeAmount = (assetsToUtilize * entryCost) / (1 - entryCost)
            uint256 feeAmount =
                assetsToUtilize.mulDiv(params.fee, Constants.FLOAT_PRECISION - params.fee, Math.Rounding.Ceil);
            assets += feeAmount;
        }
    }

    function getPreviewWithdraw(PreviewParams memory params) external view returns (uint256 shares) {
        // get idle assets
        (, uint256 idleAssets, uint256 totalAssets) = getTotalAssets(params.addr, params.cache);

        // calc the amount of assets that can not be withdrawn via idle
        (, uint256 assetsToDeutilize) = params.assetsOrShares.trySub(idleAssets);

        // apply exit fee to assets that should be deutilized and add exit fee amount the asset amount
        if (assetsToDeutilize > 0) {
            // feeAmount / assetsToDeutilize = exitCost
            uint256 feeAmount = assetsToDeutilize.mulDiv(params.fee, Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
            params.assetsOrShares += feeAmount;
        }
        shares = _convertToShares(params.assetsOrShares, totalAssets, params.totalSupply, Math.Rounding.Ceil);
    }

    function getPreviewRedeem(PreviewParams memory params) external view returns (uint256 assets) {
        // calculate the amount of assets before applying exit fee
        (, uint256 idleAssets, uint256 totalAssets) = getTotalAssets(params.addr, params.cache);
        assets = _convertToAssets(params.assetsOrShares, totalAssets, params.totalSupply, Math.Rounding.Floor);

        // calculate the amount of assets that will be deutilized
        (, uint256 assetsToDeutilize) = assets.trySub(idleAssets);

        // aply exit fee to the portion of assets that will be deutilized
        if (assetsToDeutilize > 0) {
            // feeAmount / (assetsToDeutilize - feeAmount) = exitCost
            // feeAmount = (assetsToDeutilize * exitCost) / (1 + exitCost)
            uint256 feeAmount =
                assetsToDeutilize.mulDiv(params.fee, Constants.FLOAT_PRECISION + params.fee, Math.Rounding.Ceil);
            assets -= feeAmount;
        }
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, uint256 totalAssets, uint256 totalSupply, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return assets.mulDiv(totalSupply + 10 ** Constants.DECIMAL_OFFSET, totalAssets + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, uint256 totalAssets, uint256 totalSupply, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(totalAssets + 1, totalSupply + 10 ** Constants.DECIMAL_OFFSET, rounding);
    }

    function _getTotalPendingWithdraw(DataTypes.StrategyStateChache memory cache) internal pure returns (uint256) {
        return cache.accRequestedWithdrawAssets - cache.proccessedWithdrawAssets;
    }
}
