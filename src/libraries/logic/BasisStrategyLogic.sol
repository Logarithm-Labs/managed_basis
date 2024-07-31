// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {InchAggregatorV6Logic} from "src/libraries/logic/InchAggregatorV6Logic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

library BasisStrategyLogic {
    using Math for uint256;
    using SafeERC20 for IERC20;

    struct PreviewParams {
        uint256 assetsOrShares; // assets in case of previewDeposit, shares in case of previewMint
        uint256 fee; // entryFee for previewDeposit & previewMing, exitFee for previewWithdraw & previewRedeem
        uint256 totalSupply;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyStateChache cache;
    }

    struct DepositParams {
        address asset;
        uint256 assets;
        DataTypes.StrategyStateChache cache;
    }

    struct WithdrawParams {
        address asset;
        address receiver;
        address owner;
        uint256 requestCounter;
        uint256 assets;
        DataTypes.StrategyStateChache cache;
    }

    struct ClaimParams {
        uint256 maxLeverage;
        uint256 totalSupply;
        DataTypes.WithdrawRequestState withdrawState;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyStateChache cache;
    }

    struct UtilizeParams {
        uint256 amount;
        uint256 targetLeverage;
        DataTypes.StrategyStatus status;
        DataTypes.SwapType swapType;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyStateChache cache;
        bytes swapData;
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC   
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC   
    //////////////////////////////////////////////////////////////*/

    function executeDeposit(DepositParams memory params)
        external
        view
        returns (DataTypes.StrategyStateChache memory cache)
    {
        uint256 idleAssets = getIdleAssets(params.asset, params.cache);
        (, cache) = processWithdrawRequests(idleAssets, params.cache);
    }

    function executeWithdraw(WithdrawParams memory params)
        external
        view
        returns (
            bytes32 withdrawId,
            DataTypes.StrategyStateChache memory,
            DataTypes.WithdrawRequestState memory withdrawState
        )
    {
        uint256 idleAssets = getIdleAssets(params.asset, params.cache);
        if (idleAssets >= params.assets) {
            withdrawId = bytes32(0);
        } else {
            uint256 pendingWithdraw = params.assets - idleAssets;
            params.cache.accRequestedWithdrawAssets += pendingWithdraw;
            withdrawId = getWithdrawId(params.owner, params.requestCounter);
            withdrawState = DataTypes.WithdrawRequestState({
                requestedAmount: params.assets,
                accRequestedWithdrawAssets: params.cache.accRequestedWithdrawAssets,
                requestTimestamp: block.timestamp,
                receiver: params.receiver,
                isClaimed: false
            });
        }
        return (withdrawId, params.cache, withdrawState);
    }

    function executeClaim(ClaimParams memory params)
        external
        view
        returns (DataTypes.StrategyStateChache memory, DataTypes.WithdrawRequestState memory, uint256 executedAmount)
    {
        if (params.withdrawState.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }
        if (params.withdrawState.receiver != msg.sender) {
            revert Errors.UnauthorizedClaimer(msg.sender, params.withdrawState.receiver);
        }
        (bool isExecuted, bool isLast) = isWithdrawRequestExecuted(
            params.withdrawState, params.addr, params.cache, params.totalSupply, params.maxLeverage
        );
        if (!isExecuted) {
            revert Errors.RequestNotExecuted();
        }

        params.withdrawState.isClaimed = true;

        // separate workflow for last redeem
        if (isLast) {
            executedAmount = params.withdrawState.requestedAmount
                - (params.withdrawState.accRequestedWithdrawAssets - params.cache.proccessedWithdrawAssets);
            params.cache.proccessedWithdrawAssets = params.cache.accRequestedWithdrawAssets;
            params.cache.pendingDecreaseCollateral = 0;
        } else {
            executedAmount = params.withdrawState.requestedAmount;
        }

        params.cache.assetsToClaim -= executedAmount;

        return (params.cache, params.withdrawState, executedAmount);
    }

    function isWithdrawRequestExecuted(
        DataTypes.WithdrawRequestState memory withdrawState,
        DataTypes.StrategyAddresses memory addr,
        DataTypes.StrategyStateChache memory cache,
        uint256 totalSupply,
        uint256 maxLeverage
    ) internal view returns (bool isExecuted, bool isLast) {
        // separate worflow for last withdraw
        // check if current withdrawState is last withdraw
        if (totalSupply == 0 && withdrawState.accRequestedWithdrawAssets == cache.accRequestedWithdrawAssets) {
            isLast = true;
        }
        if (isLast) {
            // last withdraw is claimable when deutilization is complete
            uint256 pendingDeutilization = getPendingDeutilization(
                addr,
                cache,
                totalSupply,
                maxLeverage,
                cache.strategyStatus == DataTypes.StrategyStatus.NEED_REBLANCE_DOWN
            );
            isExecuted = pendingDeutilization == 0 && cache.strategyStatus == DataTypes.StrategyStatus.IDLE;
        } else {
            isExecuted = withdrawState.accRequestedWithdrawAssets <= cache.proccessedWithdrawAssets;
        }
    }

    /// @dev process withdraw request
    /// Note: should be called whenever assets come to this vault
    /// including user's deposit and system's deutilizing
    ///
    /// @return remainingAssets remaining which goes to idle or assetsToWithdraw

    function processWithdrawRequests(uint256 assets, DataTypes.StrategyStateChache memory cache)
        public
        pure
        returns (uint256 remainingAssets, DataTypes.StrategyStateChache memory)
    {
        if (assets == 0) {
            remainingAssets = 0;
        } else {
            // check if there is neccessarity to process withdraw requests
            if (cache.proccessedWithdrawAssets < cache.accRequestedWithdrawAssets) {
                uint256 proccessedWithdrawAssetsAfter = cache.proccessedWithdrawAssets + assets;

                // if proccessedWithdrawAssets overshoots accRequestedWithdrawAssets,
                // then cap it by accRequestedWithdrawAssets
                // so that the remaining asset goes to idle
                if (proccessedWithdrawAssetsAfter > cache.accRequestedWithdrawAssets) {
                    remainingAssets = proccessedWithdrawAssetsAfter - cache.accRequestedWithdrawAssets;
                    proccessedWithdrawAssetsAfter = cache.accRequestedWithdrawAssets;
                    assets = proccessedWithdrawAssetsAfter - cache.proccessedWithdrawAssets;
                }

                cache.assetsToClaim += assets;
                cache.proccessedWithdrawAssets = proccessedWithdrawAssetsAfter;
            }
        }

        return (remainingAssets, cache);
    }

    function getWithdrawId(address owner, uint256 counter) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNTING LOGIC   
    //////////////////////////////////////////////////////////////*/

    function executeUtilize(UtilizeParams memory params)
        external
        returns (
            bool success,
            uint256 amountOut,
            DataTypes.StrategyStateChache memory,
            IPositionManager.RequestParams memory
        )
    {
        uint256 idleAssets = getIdleAssets(params.addr.asset, params.cache);
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

        IPositionManager.RequestParams memory adjustPositionParams;
        // if (success) {
        //     uint256 collateralDeltaAmount;
        //     if (params.cache.pendingIncreaseCollateral > 0) {
        //         collateralDeltaAmount = getPendingIncreaseCollateral(
        //             params.addr.asset, params.targetLeverage, params.cache
        //         ).mulDiv(params.amount, pendingUtilization);
        //         params.cache.pendingIncreaseCollateral -= collateralDeltaAmount;
        //     }
        //     params.cache.pendingUtilization -= params.amount;
        //     adjustPositionParams = IPositionManager.AdjustPositionParams({
        //         sizeDeltaInTokens: amountOut,
        //         collateralDeltaAmount: collateralDeltaAmount,
        //         isIncrease: true
        //     });
        // }
        return (success, amountOut, params.cache, adjustPositionParams);
    }

    function executeDeutilize(UtilizeParams memory params)
        external
        returns (
            bool success,
            uint256 amountOut,
            DataTypes.StrategyStateChache memory,
            IPositionManager.RequestParams memory
        )
    {
        //     uint256 productBalance = IERC20(params.addr.product).balanceOf(address(this));

        //     // actual deutilize amount is min of amount, product balance and pending deutilization
        //     params.amount =
        //         params.amount > params.cache.pendingDeutilization ? params.cache.pendingDeutilization : params.amount;
        //     params.amount = params.amount > productBalance ? productBalance : params.amount;

        //     // can only deutilize when amount is positive
        //     if (params.amount == 0) {
        //         revert Errors.ZeroAmountUtilization();
        //     }

        //     if (params.swapType == DataTypes.SwapType.INCH_V6) {
        //         (amountOut, success) = InchAggregatorV6Logic.executeSwap(
        //             params.amount, params.addr.asset, params.addr.product, true, params.swapData
        //         );
        //     } else {
        //         // @consider: fallback swap
        //         revert Errors.UnsupportedSwapType();
        //     }

        IPositionManager.RequestParams memory adjustPositionParams;
        //     if (success) {
        //         if (params.status == DataTypes.StrategyStatus.IDLE) {
        //             params.cache.assetsToWithdraw += amountOut;
        //             params.cache.totalPendingWithdraw -= amountOut;
        //             params.cache.withdrawnFromSpot += amountOut;
        //             adjustPositionParams = IPositionManager.AdjustPositionParams({
        //                 sizeDeltaInTokens: params.amount,
        //                 collateralDeltaAmount: 0,
        //                 isIncrease: false
        //             });
        //         }
        //     }
        return (success, amountOut, params.cache, adjustPositionParams);
    }

    function getPendingUtilization(address asset, DataTypes.StrategyStateChache memory cache, uint256 targetLeverage)
        public
        view
        returns (uint256)
    {
        uint256 idleAssets = getIdleAssets(asset, cache);
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
        DataTypes.StrategyStateChache memory cache,
        uint256 totalSupply,
        uint256 maxLeverage,
        bool needRebalanceDownWithDeutilizing
    ) public view returns (uint256 deutilization) {
        uint256 productBalance = IERC20(addr.product).balanceOf(address(this));
        if (totalSupply == 0) return productBalance;

        uint256 positionSizeInTokens = IPositionManager(addr.positionManager).positionSizeInTokens();

        if (needRebalanceDownWithDeutilizing) {
            // currentLeverage > maxLeverage is guarranteed, so there is no math error
            // deltaSizeToDecrease =  positionSize - maxLeverage * positionSize / currentLeverage
            deutilization = positionSizeInTokens
                - positionSizeInTokens.mulDiv(maxLeverage, IPositionManager(addr.positionManager).currentLeverage());
        } else {
            uint256 positionNetBalance = IPositionManager(addr.positionManager).positionNetBalance();
            uint256 positionSizeInAssets =
                IOracle(addr.oracle).convertTokenAmount(addr.product, addr.asset, positionSizeInTokens);
            if (positionSizeInAssets == 0 && positionNetBalance == 0) return 0;
            uint256 totalPendingWithdraw = _getTotalPendingWithdraw(cache);

            // prevents underflow
            if (
                cache.pendingDecreaseCollateral > totalPendingWithdraw
                    || cache.pendingDecreaseCollateral >= (positionSizeInAssets + positionNetBalance)
            ) {
                return 0;
            }

            // note: if we do not decrease collateral after every deutilization and do not adjust totalPendingWithdraw and
            // position net balance for $.pendingDecreaseCollateral the return value for pendingDeutilization would be invalid
            deutilization = positionSizeInTokens.mulDiv(
                totalPendingWithdraw - cache.pendingDecreaseCollateral,
                positionSizeInAssets + positionNetBalance - cache.pendingDecreaseCollateral
            );
        }

        deutilization = deutilization > productBalance ? productBalance : deutilization;
        return deutilization;
    }

    function getPendingIncreaseCollateral(
        address asset,
        uint256 targetLeverage,
        DataTypes.StrategyStateChache memory cache
    ) public view returns (uint256) {
        uint256 idleAssets = getIdleAssets(asset, cache);
        return
            idleAssets.mulDiv(Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + targetLeverage, Math.Rounding.Ceil);
    }
}
