// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {InchAggregatorV6Logic} from "src/libraries/logic/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/logic/ManualSwapLogic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

library BasisStrategyLogic {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

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
        uint256 totalSupply;
        DataTypes.StrategyStatus status;
        DataTypes.StrategyLeverages leverages;
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
        address[] assetToProductSwapPath;
        bytes swapData;
        bool processingRebalance;
    }

    struct DeutilizeParams {
        uint256 amount;
        uint256 totalSupply;
        DataTypes.StrategyStatus status;
        DataTypes.SwapType swapType;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyLeverages leverages;
        DataTypes.StrategyStateChache cache;
        address[] productToAssetSwapPath;
        bytes swapData;
        bool processingRebalance;
    }

    struct CheckUpkeepParams {
        uint256 hedgeDeviationThreshold;
        uint256 pendingDecreaseCollateral;
        bool processingRebalance;
        DataTypes.StrategyStateChache cache;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyLeverages leverages;
        DataTypes.StrategyStatus strategyStatus;
    }

    struct PerformUpkeepParams {
        uint256 totalSupply;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyLeverages leverages;
        DataTypes.StrategyStateChache cache;
        address[] productToAssetSwapPath;
        bytes performData;
    }

    struct AfterAdjustPositionParams {
        address positionManager;
        DataTypes.PositionManagerPayload requestParams;
        DataTypes.PositionManagerPayload responseParams;
        address[] revertSwapPath;
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
        (, uint256 totalAssets) = ((utilizedAssets + idleAssets) + cache.assetsToWithdraw).trySub(
            (cache.accRequestedWithdrawAssets - cache.proccessedWithdrawAssets)
        );

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
        (, uint256 assetsToUtilize) = params.assetsOrShares.trySub(getTotalPendingWithdraw(params.cache));
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
        (, uint256 assetsToUtilize) = assets.trySub(getTotalPendingWithdraw(params.cache));

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
            params.cache.assetsToClaim += idleAssets;
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
            params.status, params.withdrawState, params.addr, params.cache, params.leverages, params.totalSupply
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
        DataTypes.StrategyStatus status,
        DataTypes.WithdrawRequestState memory withdrawState,
        DataTypes.StrategyAddresses memory addr,
        DataTypes.StrategyStateChache memory cache,
        DataTypes.StrategyLeverages memory leverages,
        uint256 totalSupply
    ) public view returns (bool isExecuted, bool isLast) {
        // separate worflow for last withdraw
        // check if current withdrawState is last withdraw
        if (totalSupply == 0 && withdrawState.accRequestedWithdrawAssets == cache.accRequestedWithdrawAssets) {
            isLast = true;
        }
        if (isLast) {
            // last withdraw is claimable when deutilization is complete
            uint256 pendingDeutilization = getPendingDeutilization(addr, cache, leverages, totalSupply, false);
            isExecuted = pendingDeutilization == 0 && status == DataTypes.StrategyStatus.IDLE;
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
            return (remainingAssets, cache);
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
                        KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    function getCheckUpkeep(CheckUpkeepParams memory params)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (params.strategyStatus != DataTypes.StrategyStatus.IDLE) {
            return (upkeepNeeded, performData);
        }

        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;

        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded) = _checkRebalance(params.leverages);

        if (!rebalanceUpNeeded && params.processingRebalance) {
            (rebalanceUpNeeded,) =
                _checkNeedRebalance(params.leverages.currentLeverage, params.leverages.targetLeverage);
        }

        if (!rebalanceDownNeeded && params.processingRebalance) {
            (, rebalanceDownNeeded) =
                _checkNeedRebalance(params.leverages.currentLeverage, params.leverages.targetLeverage);
        }

        if (rebalanceUpNeeded) {
            uint256 deltaCollateralToDecrease =
                _calculateDeltaCollateralForRebalance(params.addr.positionManager, params.leverages.targetLeverage);
            (uint256 minDecreaseCollateral,) = IPositionManager(params.addr.positionManager).decreaseCollateralMinMax();
            rebalanceUpNeeded = deltaCollateralToDecrease >= minDecreaseCollateral;
        }

        if (rebalanceDownNeeded && params.processingRebalance && !deleverageNeeded) {
            uint256 idleAssets = getIdleAssets(params.addr.asset, params.cache);
            (uint256 minIncreaseCollateral,) = IPositionManager(params.addr.positionManager).increaseCollateralMinMax();
            rebalanceDownNeeded = idleAssets != 0 && idleAssets >= minIncreaseCollateral;
        }

        if (rebalanceUpNeeded || rebalanceDownNeeded) {
            upkeepNeeded = true;
        } else {
            hedgeDeviationInTokens = _checkHedgeDeviation(params.addr, params.hedgeDeviationThreshold);
            if (hedgeDeviationInTokens != 0) {
                upkeepNeeded = true;
            } else {
                positionManagerNeedKeep = IPositionManager(params.addr.positionManager).needKeep();
                if (positionManagerNeedKeep) {
                    upkeepNeeded = true;
                } else {
                    (uint256 minDecreaseCollateral,) =
                        IPositionManager(params.addr.positionManager).decreaseCollateralMinMax();
                    if (params.pendingDecreaseCollateral > minDecreaseCollateral) {
                        upkeepNeeded = true;
                    }
                }
            }
        }

        performData = abi.encode(
            rebalanceUpNeeded, rebalanceDownNeeded, deleverageNeeded, hedgeDeviationInTokens, positionManagerNeedKeep
        );

        return (upkeepNeeded, performData);
    }

    function _checkRebalance(DataTypes.StrategyLeverages memory leverages)
        internal
        pure
        returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded)
    {
        if (leverages.currentLeverage > leverages.maxLeverage) {
            rebalanceDownNeeded = true;
            if (leverages.currentLeverage > leverages.safeMarginLeverage) {
                deleverageNeeded = true;
            }
        }

        if (leverages.currentLeverage != 0 && leverages.currentLeverage < leverages.minLeverage) {
            rebalanceUpNeeded = true;
        }
    }

    function _checkHedgeDeviation(DataTypes.StrategyAddresses memory addr, uint256 hedgeDeviationThreshold)
        internal
        view
        returns (int256)
    {
        uint256 spotExposure = IERC20(addr.product).balanceOf(address(this));
        uint256 hedgeExposure = IPositionManager(addr.positionManager).positionSizeInTokens();
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return 0;
            } else {
                return -hedgeExposure.toInt256();
            }
        }
        uint256 hedgeDeviation = hedgeExposure.mulDiv(Constants.FLOAT_PRECISION, spotExposure);
        if (
            hedgeDeviation > Constants.FLOAT_PRECISION + hedgeDeviationThreshold
                || hedgeDeviation < Constants.FLOAT_PRECISION - hedgeDeviationThreshold
        ) {
            int256 hedgeDeviationInTokens = spotExposure.toInt256() - hedgeExposure.toInt256();
            if (hedgeDeviationInTokens > 0) {
                (uint256 min, uint256 max) = IPositionManager(addr.positionManager).increaseSizeMinMax();
                (min, max) = (
                    min == 0 ? 0 : IOracle(addr.oracle).convertTokenAmount(addr.asset, addr.product, min),
                    max == type(uint256).max
                        ? type(uint256).max
                        : IOracle(addr.oracle).convertTokenAmount(addr.asset, addr.product, max)
                );
                return int256(_clamp(min, uint256(hedgeDeviationInTokens), max));
            } else {
                (uint256 min, uint256 max) = IPositionManager(addr.positionManager).decreaseSizeMinMax();
                (min, max) = (
                    min == 0 ? 0 : IOracle(addr.oracle).convertTokenAmount(addr.asset, addr.product, min),
                    max == type(uint256).max
                        ? type(uint256).max
                        : IOracle(addr.oracle).convertTokenAmount(addr.asset, addr.product, max)
                );
                return -int256(_clamp(min, uint256(-hedgeDeviationInTokens), max));
            }
        }
        return 0;
    }

    function executePerformUpkeep(PerformUpkeepParams memory params)
        external
        returns (
            DataTypes.StrategyStateChache memory,
            DataTypes.PositionManagerPayload memory requestParams,
            DataTypes.StrategyStatus status,
            bool processingRebalance
        )
    {
        (
            bool rebalanceUpNeeded,
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep
        ) = abi.decode(params.performData, (bool, bool, bool, int256, bool));
        status = DataTypes.StrategyStatus.KEEPING;
        uint256 idleAssets;
        if (rebalanceUpNeeded) {
            // if reblance up is needed, we have to break normal deutilization of decreasing collateral
            params.cache.pendingDecreaseCollateral = 0;
            uint256 deltaCollateralToDecrease =
                _calculateDeltaCollateralForRebalance(params.addr.positionManager, params.leverages.targetLeverage);
            (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).decreaseCollateralMinMax();
            requestParams.collateralDeltaAmount = _clamp(min, deltaCollateralToDecrease, max);
            processingRebalance = true;
            if (requestParams.collateralDeltaAmount == 0) {
                status = DataTypes.StrategyStatus.IDLE;
            }
        } else if (rebalanceDownNeeded) {
            // if reblance down is needed, we have to break normal deutilization of decreasing collateral
            params.cache.pendingDecreaseCollateral = 0;
            idleAssets = getIdleAssets(params.addr.asset, params.cache);
            uint256 deltaCollateralToIncrease =
                _calculateDeltaCollateralForRebalance(params.addr.positionManager, params.leverages.targetLeverage);
            (uint256 minIncreaseCollateral,) = IPositionManager(params.addr.positionManager).increaseCollateralMinMax();

            if (deleverageNeeded && (deltaCollateralToIncrease > idleAssets || minIncreaseCollateral > idleAssets)) {
                uint256 amount =
                    getPendingDeutilization(params.addr, params.cache, params.leverages, params.totalSupply, true);
                (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).decreaseSizeMinMax();
                (min, max) = (
                    min == 0
                        ? 0
                        : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, min),
                    max == type(uint256).max
                        ? type(uint256).max
                        : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, max)
                );

                // @issue amount can be 0 because of clamping that breaks emergency rebalance down
                amount = _clamp(min, amount, max);
                if (amount > 0) {
                    uint256 amountOut = ManualSwapLogic.swap(amount, params.productToAssetSwapPath);
                    // produced asset shouldn't go to idle until position size is decreased
                    params.cache.assetsToWithdraw += amountOut;
                    requestParams.sizeDeltaInTokens = amount;
                } else {
                    status = DataTypes.StrategyStatus.IDLE;
                }
            } else {
                requestParams.collateralDeltaAmount =
                    idleAssets > deltaCollateralToIncrease ? deltaCollateralToIncrease : idleAssets;
                (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).increaseCollateralMinMax();
                requestParams.collateralDeltaAmount = _clamp(min, requestParams.collateralDeltaAmount, max);
                requestParams.isIncrease = true;
                if (requestParams.collateralDeltaAmount == 0) {
                    status = DataTypes.StrategyStatus.IDLE;
                }
            }
            processingRebalance = true;
        } else if (hedgeDeviationInTokens != 0) {
            if (hedgeDeviationInTokens > 0) {
                (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).increaseSizeMinMax();
                (min, max) = (
                    min == 0
                        ? 0
                        : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, min),
                    max == type(uint256).max
                        ? type(uint256).max
                        : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, max)
                );
                requestParams.sizeDeltaInTokens = _clamp(min, uint256(hedgeDeviationInTokens), max);
                requestParams.isIncrease = true;
                if (requestParams.sizeDeltaInTokens == 0) {
                    status = DataTypes.StrategyStatus.IDLE;
                }
            } else {
                (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).decreaseSizeMinMax();
                (min, max) = (
                    min == 0
                        ? 0
                        : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, min),
                    max == type(uint256).max
                        ? type(uint256).max
                        : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, max)
                );
                requestParams.sizeDeltaInTokens = _clamp(min, uint256(-hedgeDeviationInTokens), max);
                if (requestParams.sizeDeltaInTokens == 0) {
                    status = DataTypes.StrategyStatus.IDLE;
                }
            }
        } else if (positionManagerNeedKeep) {
            IPositionManager(params.addr.positionManager).keep();
        } else if (params.cache.pendingDecreaseCollateral > 0) {
            (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).decreaseCollateralMinMax();
            requestParams.collateralDeltaAmount = _clamp(min, params.cache.pendingDecreaseCollateral, max);
            if (requestParams.collateralDeltaAmount == 0) {
                status = DataTypes.StrategyStatus.IDLE;
            }
        }
        return (params.cache, requestParams, status, processingRebalance);
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC   
    //////////////////////////////////////////////////////////////*/

    function executeUtilize(UtilizeParams memory params)
        external
        returns (bool success, DataTypes.StrategyStatus status, DataTypes.PositionManagerPayload memory requestParams)
    {
        // can only utilize when the strategy status is IDLE
        if (params.status != DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(params.status));
        }

        uint256 idleAssets = getIdleAssets(params.addr.asset, params.cache);
        uint256 pendingUtilization = _pendingUtilization(idleAssets, params.targetLeverage, params.processingRebalance);

        if (pendingUtilization == 0) {
            revert Errors.ZeroPendingUtilization();
        }

        // actual utilize amount is min of amount, idle assets and pending utilization
        // @note dont need to check because always pendingUtilization_ < idle
        // params.amount = params.amount > idleAssets ? idleAssets : params.amount;
        params.amount = params.amount > pendingUtilization ? pendingUtilization : params.amount;
        // can only utilize when amount is positive
        if (params.amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        if (params.swapType == DataTypes.SwapType.INCH_V6) {
            (requestParams.sizeDeltaInTokens, success) = InchAggregatorV6Logic.executeSwap(
                params.amount, params.addr.asset, params.addr.product, true, params.swapData
            );
        } else if (params.swapType == DataTypes.SwapType.MANUAL) {
            requestParams.sizeDeltaInTokens = ManualSwapLogic.swap(params.amount, params.assetToProductSwapPath);
            success = true;
        } else {
            revert Errors.UnsupportedSwapType();
        }

        uint256 pendingIncreaseCollateral = _pendingIncreaseCollateral(idleAssets, params.targetLeverage);

        requestParams.collateralDeltaAmount = pendingIncreaseCollateral.mulDiv(params.amount, pendingUtilization);
        (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).increaseCollateralMinMax();

        // note: clamp is not required for size delta in tokens, expected behaviour is reversion in position manager
        requestParams.collateralDeltaAmount = _clamp(min, requestParams.collateralDeltaAmount, max);
        requestParams.isIncrease = true;
        status = DataTypes.StrategyStatus.UTILIZING;

        return (success, status, requestParams);
    }

    function executeDeutilize(DeutilizeParams memory params)
        external
        returns (
            bool success,
            uint256 amountOut,
            DataTypes.StrategyStatus status,
            DataTypes.StrategyStateChache memory,
            DataTypes.PositionManagerPayload memory requestParams
        )
    {
        // can only deutilize when the strategy status is IDLE
        if (params.status != DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(params.status));
        }

        // uint256 productBalance = IERC20(product()).balanceOf(address(this));

        // actual deutilize amount is min of amount, product balance and pending deutilization
        uint256 pendingDeutilization = getPendingDeutilization(
            params.addr, params.cache, params.leverages, params.totalSupply, params.processingRebalance
        );
        // @note productBalance is already checked within _pendingDeutilization()
        // amount = amount > productBalance ? productBalance : amount;
        uint256 amount = params.amount > pendingDeutilization ? pendingDeutilization : params.amount;
        (uint256 min, uint256 max) = IPositionManager(params.addr.positionManager).decreaseSizeMinMax();
        (min, max) = (
            min == 0 ? 0 : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, min),
            max == type(uint256).max
                ? type(uint256).max
                : IOracle(params.addr.oracle).convertTokenAmount(params.addr.asset, params.addr.product, max)
        );
        amount = _clamp(min, amount, max);

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        // can only execute through 1Inch with valid amountIn in swapData
        if (amount != params.amount) {
            params.swapType = DataTypes.SwapType.MANUAL;
        }

        if (params.swapType == DataTypes.SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(
                amount, params.addr.asset, params.addr.product, false, params.swapData
            );
        } else if (params.swapType == DataTypes.SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, params.productToAssetSwapPath);
            success = true;
        } else {
            revert Errors.UnsupportedSwapType();
        }

        params.cache.pendingDeutilizedAssets = amountOut;
        params.cache.assetsToWithdraw += amountOut;

        requestParams.sizeDeltaInTokens = amount;

        if (!params.processingRebalance) {
            if (amount == pendingDeutilization) {
                (, requestParams.collateralDeltaAmount) =
                    params.cache.accRequestedWithdrawAssets.trySub(params.cache.proccessedWithdrawAssets + amountOut);
                params.cache.pendingDecreaseCollateral = requestParams.collateralDeltaAmount;
            } else {
                uint256 positionNetBalance = IPositionManager(params.addr.positionManager).positionNetBalance();
                uint256 positionSizeInTokens = IPositionManager(params.addr.positionManager).positionSizeInTokens();
                uint256 collateralDeltaToDecrease = positionNetBalance.mulDiv(amount, positionSizeInTokens);
                params.cache.pendingDecreaseCollateral += collateralDeltaToDecrease;
            }
        }

        status = DataTypes.StrategyStatus.DEUTILIZING;

        return (success, amountOut, status, params.cache, requestParams);
    }

    function getTotalPendingWithdraw(DataTypes.StrategyStateChache memory cache) public pure returns (uint256) {
        (, uint256 totalPendingWithdraw) =
            cache.accRequestedWithdrawAssets.trySub(cache.proccessedWithdrawAssets + cache.assetsToWithdraw);
        return totalPendingWithdraw;
    }

    function getPendingUtilization(
        address asset,
        uint256 targetLeverage,
        DataTypes.StrategyStateChache memory cache,
        bool processingRebalance
    ) public view returns (uint256) {
        uint256 idleAssets = getIdleAssets(asset, cache);
        return _pendingUtilization(idleAssets, targetLeverage, processingRebalance);
    }

    function _pendingUtilization(uint256 idleAssets, uint256 targetLeverage, bool processingRebalance)
        public
        pure
        returns (uint256)
    {
        // don't use utilze function when rebalancing
        return processingRebalance ? 0 : idleAssets.mulDiv(targetLeverage, Constants.FLOAT_PRECISION + targetLeverage);
    }

    function getPendingIncreaseCollateral(
        address asset,
        uint256 targetLeverage,
        DataTypes.StrategyStateChache memory cache
    ) public view returns (uint256) {
        uint256 idleAssets = getIdleAssets(asset, cache);
        return _pendingIncreaseCollateral(idleAssets, targetLeverage);
    }

    function _pendingIncreaseCollateral(uint256 idleAssets, uint256 targetLeverage) public pure returns (uint256) {
        return
            idleAssets.mulDiv(Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + targetLeverage, Math.Rounding.Ceil);
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
        DataTypes.StrategyLeverages memory leverages,
        uint256 totalSupply,
        bool processingRebalance
    ) public view returns (uint256 deutilization) {
        uint256 productBalance = IERC20(addr.product).balanceOf(address(this));
        if (totalSupply == 0) return productBalance;

        uint256 positionSizeInTokens = IPositionManager(addr.positionManager).positionSizeInTokens();

        if (processingRebalance) {
            if (leverages.currentLeverage > leverages.targetLeverage) {
                // deltaSizeToDecrease =  positionSize - targetLeverage * positionSize / currentLeverage
                deutilization = positionSizeInTokens
                    - positionSizeInTokens.mulDiv(leverages.targetLeverage, leverages.currentLeverage);
            }
        } else {
            uint256 positionNetBalance = IPositionManager(addr.positionManager).positionNetBalance();
            uint256 positionSizeInAssets =
                IOracle(addr.oracle).convertTokenAmount(addr.product, addr.asset, positionSizeInTokens);
            if (positionSizeInAssets == 0 && positionNetBalance == 0) return 0;
            uint256 totalPendingWithdraw = getTotalPendingWithdraw(cache);

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

    function executeAfterIncreasePosition(
        AfterAdjustPositionParams calldata params,
        bool processingRebalance,
        uint256 currentLeverage,
        uint256 targetLeverage
    ) external returns (DataTypes.StrategyStatus, bool) {
        DataTypes.StrategyStatus status = DataTypes.StrategyStatus.IDLE;
        if (params.requestParams.sizeDeltaInTokens > 0) {
            (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens) = _checkResultedPositionSize(
                params.responseParams.sizeDeltaInTokens, params.requestParams.sizeDeltaInTokens
            );
            if (isWrongPositionSize) {
                status = DataTypes.StrategyStatus.PAUSE;
                if (sizeDeltaDeviationInTokens < 0) {
                    // revert spot to make hedge size the same as spot
                    ManualSwapLogic.swap(uint256(-sizeDeltaDeviationInTokens), params.revertSwapPath);
                }
            }
        }

        (, uint256 revertCollateralDeltaAmount) =
            params.requestParams.collateralDeltaAmount.trySub(params.responseParams.collateralDeltaAmount);

        if (revertCollateralDeltaAmount > 0) {
            IERC20(params.revertSwapPath[params.revertSwapPath.length - 1]).safeTransferFrom(
                params.positionManager, address(this), revertCollateralDeltaAmount
            );
        }

        // only when rebalance was started, we need to check
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded) = _checkNeedRebalance(currentLeverage, targetLeverage);
        processingRebalance = processingRebalance && (rebalanceUpNeeded || rebalanceDownNeeded);

        return (status, processingRebalance);
    }

    function executeAfterDecreasePosition(
        AfterAdjustPositionParams calldata params,
        DataTypes.StrategyStateChache memory cache,
        bool processingRebalance,
        uint256 currentLeverage,
        uint256 targetLeverage
    ) external returns (DataTypes.StrategyStateChache memory, DataTypes.StrategyStatus, bool) {
        DataTypes.StrategyStatus status = DataTypes.StrategyStatus.IDLE;
        uint256 remainingAssets;
        if (params.requestParams.sizeDeltaInTokens > 0) {
            (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens) = _checkResultedPositionSize(
                params.responseParams.sizeDeltaInTokens, params.requestParams.sizeDeltaInTokens
            );
            if (isWrongPositionSize) {
                status = DataTypes.StrategyStatus.PAUSE;
                if (sizeDeltaDeviationInTokens < 0) {
                    uint256 assetsToBeReverted = cache.pendingDeutilizedAssets.mulDiv(
                        uint256(-sizeDeltaDeviationInTokens), params.requestParams.sizeDeltaInTokens
                    );
                    ManualSwapLogic.swap(assetsToBeReverted, params.revertSwapPath);
                    cache.assetsToWithdraw -= assetsToBeReverted;
                    cache.pendingDeutilizedAssets -= assetsToBeReverted;
                }
            }
            if (processingRebalance) {
                // release deutilized asset to idle when rebalance down
                (, cache) = processWithdrawRequests(cache.pendingDeutilizedAssets, cache);
                cache.assetsToWithdraw -= cache.pendingDeutilizedAssets;
            } else {
                // process withdraw request
                (remainingAssets, cache) = processWithdrawRequests(cache.assetsToWithdraw, cache);
                cache.assetsToWithdraw = remainingAssets;
            }
            cache.pendingDeutilizedAssets = 0;
        }
        if (params.responseParams.collateralDeltaAmount > 0) {
            IERC20(params.revertSwapPath[0]).safeTransferFrom(
                params.positionManager, address(this), params.responseParams.collateralDeltaAmount
            );
            (remainingAssets, cache) = processWithdrawRequests(params.responseParams.collateralDeltaAmount, cache);
            if (!processingRebalance) {
                cache.assetsToWithdraw += remainingAssets;
                (, cache.pendingDecreaseCollateral) =
                    cache.pendingDecreaseCollateral.trySub(params.responseParams.collateralDeltaAmount);
            }
        }

        // only when rebalance was started, we need to check
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded) = _checkNeedRebalance(currentLeverage, targetLeverage);
        processingRebalance = processingRebalance && (rebalanceUpNeeded || rebalanceDownNeeded);

        return (cache, status, processingRebalance);
    }

    function _checkNeedRebalance(uint256 currentLeverage, uint256 targetLeverage)
        internal
        pure
        returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded)
    {
        int256 leverageDeviation = currentLeverage.toInt256() - targetLeverage.toInt256();
        if (
            (leverageDeviation < 0 ? uint256(-leverageDeviation) : uint256(leverageDeviation)).mulDiv(
                Constants.FLOAT_PRECISION, targetLeverage
            ) > Constants.REBALANCE_LEVERAGE_DEVIATION_THRESHOLD
        ) {
            rebalanceUpNeeded = leverageDeviation < 0;
            rebalanceDownNeeded = !rebalanceUpNeeded;
        }
        return (rebalanceUpNeeded, rebalanceDownNeeded);
    }

    function _clamp(uint256 min, uint256 value, uint256 max) internal pure returns (uint256 result) {
        result = value < min ? 0 : (value > max ? max : value);
    }

    // @dev should be called under the condition that sizeDeltaInTokensReq != 0
    function _checkResultedPositionSize(uint256 sizeDeltaInTokensResp, uint256 sizeDeltaInTokensReq)
        internal
        pure
        returns (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens)
    {
        sizeDeltaDeviationInTokens = sizeDeltaInTokensResp.toInt256() - sizeDeltaInTokensReq.toInt256();
        isWrongPositionSize = (
            sizeDeltaDeviationInTokens < 0 ? uint256(-sizeDeltaDeviationInTokens) : uint256(sizeDeltaDeviationInTokens)
        ).mulDiv(Constants.FLOAT_PRECISION, sizeDeltaInTokensReq) > Constants.SIZE_DELTA_DEVIATION_THRESHOLD;
        return (isWrongPositionSize, sizeDeltaDeviationInTokens);
    }

    /// @dev collateral adjustment for rebalancing
    /// currentLeverage = notional / collateral
    /// notional = currentLeverage * collateral
    /// targetLeverage = notional / targetCollateral
    /// targetCollateral = notional / targetLeverage
    /// targetCollateral = collateral * currentLeverage  / targetLeverage
    function _calculateDeltaCollateralForRebalance(address positionManager, uint256 targetLeverage)
        internal
        view
        returns (uint256)
    {
        uint256 positionNetBalance = IPositionManager(positionManager).positionNetBalance();
        uint256 currentLeverage = IPositionManager(positionManager).currentLeverage();
        uint256 targetCollateral = positionNetBalance.mulDiv(currentLeverage, targetLeverage);
        uint256 deltaCollateral;
        if (currentLeverage > targetLeverage) {
            deltaCollateral = targetCollateral - positionNetBalance;
        } else {
            deltaCollateral = positionNetBalance - targetCollateral;
        }
        return deltaCollateral;
    }
}
