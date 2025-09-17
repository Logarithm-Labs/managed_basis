// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILogarithmVault} from "../../vault/ILogarithmVault.sol";
import {IHedgeManager} from "../../hedge/IHedgeManager.sol";
import {ISpotManager} from "../../spot/ISpotManager.sol";

import {BasisStrategyState, StrategyStatus} from "./BasisStrategyState.sol";
import {Constants} from "../utils/Constants.sol";
import {Errors} from "../utils/Errors.sol";
import {CommonLib} from "./CommonLib.sol";
import {Position} from "./Position.sol";
import {AssetsState} from "./AssetsState.sol";

library Deutilization {
    using Math for uint256;

    /// @dev Used internally to optimize params of deutilization.
    struct InternalPendingDeutilization {
        // The address of hedge position manager.
        IHedgeManager hedgeManager;
        // The address of the connected vault's underlying asset.
        address asset;
        // The product address.
        address product;
        // The totalSupply of shares of its connected vault
        uint256 totalSupply;
        // The current exposure of spot manager
        uint256 exposure;
        // The boolean value of storage variable processingRebalanceDown.
        bool processingRebalanceDown;
        // The boolean value tells whether strategy gets paused of not.
        bool paused;
        // The cap amount for deutilization
        uint256 maxAmount;
    }

    function _pendingDeutilization(InternalPendingDeutilization memory params)
        internal
        view
        returns (uint256 amount, uint256 uncappedAmount)
    {
        // disable only withdraw deutilization
        if (!params.processingRebalanceDown && params.paused) return (0, 0);

        if (params.totalSupply == 0) {
            uncappedAmount = params.exposure;
            amount = CommonLib._capAmount(params.exposure, params.maxAmount);
            return (amount, uncappedAmount);
        }

        uint256 positionSizeInTokens = params.hedgeManager.positionSizeInTokens();
        uint256 positionSizeInAssets =
            BasisStrategyState.getOracle().convertTokenAmount(params.product, params.asset, positionSizeInTokens);
        uint256 positionNetBalance = params.hedgeManager.positionNetBalance();
        if (positionSizeInAssets == 0 || positionNetBalance == 0) return (0, 0);

        uint256 totalPendingWithdraw = AssetsState._assetsToDeutilize();

        if (params.processingRebalanceDown) {
            // for rebalance
            uint256 currentLeverage = params.hedgeManager.currentLeverage();
            uint256 _targetLeverage = BasisStrategyState.getTargetLeverage();
            if (currentLeverage > _targetLeverage) {
                // calculate deutilization product
                // when totalPendingWithdraw is enough big to prevent increasing collateral
                uint256 deltaLeverage = currentLeverage - _targetLeverage;
                uncappedAmount = positionSizeInTokens.mulDiv(deltaLeverage, currentLeverage);
                uint256 deutilizationInAsset =
                    BasisStrategyState.getOracle().convertTokenAmount(params.product, params.asset, uncappedAmount);

                // when totalPendingWithdraw is not enough big to prevent increasing collateral
                if (totalPendingWithdraw < deutilizationInAsset) {
                    uint256 num = deltaLeverage + _targetLeverage.mulDiv(totalPendingWithdraw, positionNetBalance);
                    uint256 den = currentLeverage + _targetLeverage.mulDiv(positionSizeInAssets, positionNetBalance);
                    uncappedAmount = positionSizeInTokens.mulDiv(num, den);
                }
            }
        } else {
            if (totalPendingWithdraw == 0) return (0, 0);

            // when current leverage is bigger than target leverage,
            // don't account for pending decrease collateral
            uint256 _pendingDecreaseCollateral = params.hedgeManager.currentLeverage()
                > BasisStrategyState.getTargetLeverage() ? 0 : BasisStrategyState.getPendingDecreaseCollateral();

            uint256 sizeAndNetBalance = positionSizeInAssets + positionNetBalance;
            if (_pendingDecreaseCollateral > totalPendingWithdraw || _pendingDecreaseCollateral >= sizeAndNetBalance) {
                // in this case, should decrease collateral to process pending withdrawl through performUpkeep
                return (0, 0);
            }

            uncappedAmount = positionSizeInTokens.mulDiv(
                totalPendingWithdraw - _pendingDecreaseCollateral, sizeAndNetBalance - _pendingDecreaseCollateral
            );
        }

        uncappedAmount = CommonLib._capAmount(uncappedAmount, params.exposure);
        amount = CommonLib._capAmount(uncappedAmount, params.maxAmount);

        return (amount, uncappedAmount);
    }

    function pendingDeutilization(bool _paused) external view returns (uint256 amount, uint256 uncappedAmount) {
        uint256 maxDeutilization = BasisStrategyState.getOracle().convertTokenAmount(
            address(BasisStrategyState.getAsset()),
            address(BasisStrategyState.getProduct()),
            CommonLib._maxUtilization(
                BasisStrategyState.getVault().idleAssets(),
                AssetsState._utilizedAssets(),
                BasisStrategyState.getMaxUtilizePct()
            )
        );
        return _pendingDeutilization(
            InternalPendingDeutilization({
                hedgeManager: BasisStrategyState.getHedgeManager(),
                asset: address(BasisStrategyState.getAsset()),
                product: address(BasisStrategyState.getProduct()),
                totalSupply: BasisStrategyState.getVault().totalSupply(),
                exposure: BasisStrategyState.getSpotManager().exposure(),
                processingRebalanceDown: BasisStrategyState.getProcessingRebalanceDown(),
                paused: _paused,
                maxAmount: maxDeutilization
            })
        );
    }

    function deutilize(bool _paused, uint256 amount, ISpotManager.SwapType swapType, bytes calldata swapData)
        external
    {
        BasisStrategyState.setStrategyStatus(StrategyStatus.DEUTILIZING);

        IHedgeManager _hedgeManager = BasisStrategyState.getHedgeManager();
        bool _processingRebalanceDown = BasisStrategyState.getProcessingRebalanceDown();
        address _asset = address(BasisStrategyState.getAsset());
        address _product = address(BasisStrategyState.getProduct());
        ILogarithmVault _vault = BasisStrategyState.getVault();
        uint256 _totalSupply = _vault.totalSupply();
        ISpotManager _spotManager = BasisStrategyState.getSpotManager();
        uint256 _exposure = _spotManager.exposure();
        uint256 maxDeutilization = BasisStrategyState.getOracle().convertTokenAmount(
            _asset,
            _product,
            CommonLib._maxUtilization(
                _vault.idleAssets(), AssetsState._utilizedAssets(), BasisStrategyState.getMaxUtilizePct()
            )
        );

        (uint256 pendingDeutilization_, uint256 uncappedDeutilization) = _pendingDeutilization(
            InternalPendingDeutilization({
                hedgeManager: _hedgeManager,
                asset: _asset,
                product: _product,
                totalSupply: _totalSupply,
                exposure: _exposure,
                processingRebalanceDown: _processingRebalanceDown,
                paused: _paused,
                maxAmount: maxDeutilization
            })
        );

        amount = CommonLib._capAmount(amount, pendingDeutilization_);

        // Replace amount with uncappedDeutilization when intend to deutilize fully
        // Note: Oracle price keeps changing, so need to check deviation.
        // Note: If the remaining product is smaller than the min size, treat it as full.
        // because there is no way to deutilize it.
        (bool exceedsThreshold, int256 deutilizationDeviation) = CommonLib._checkDeviation(
            uncappedDeutilization, amount, BasisStrategyState.getConfig().deutilizationThreshold()
        );
        uint256 min = _hedgeManager.decreaseSizeMin();
        (, uint256 absoluteThreshold) = uncappedDeutilization.trySub(min);
        if (deutilizationDeviation < 0 || !exceedsThreshold || amount >= absoluteThreshold) {
            amount = uncappedDeutilization;
        }

        if (_processingRebalanceDown && amount > 0 && amount < min) {
            // when processing rebalance down, deutilization should be at least decreaseSizeMin
            amount = min;
        } else {
            // check if amount is in the possible adjustment range
            amount = CommonLib._clamp(min, amount);
        }

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 collateralDeltaAmount;
        uint256 sizeDeltaInTokens = amount;
        // if the operation is not for processing rebalance down,
        // that means deutilizing for withdraw requests, then decreases
        // the collateral of hedge position as well.
        if (!_processingRebalanceDown) {
            if (amount == uncappedDeutilization) {
                // when full deutilization
                BasisStrategyState.setUtilizingExecutionCost(BasisStrategyState.getReservedExecutionCost());
                if (_totalSupply == 0) {
                    // in case of redeeming all by users,
                    // or selling out all product
                    // close hedge position
                    sizeDeltaInTokens = type(uint256).max;
                    collateralDeltaAmount = type(uint256).max;
                } else {
                    // estimate assets that will be derived from selling spot
                    uint256 estimatedAssets =
                        BasisStrategyState.getOracle().convertTokenAmount(_product, _asset, amount);
                    // subtract 1% less than the estimated one to process fully
                    (, collateralDeltaAmount) = AssetsState._assetsToDeutilize().trySub(estimatedAssets * 99 / 100);
                    min = _hedgeManager.decreaseCollateralMin();
                    if (collateralDeltaAmount < min) {
                        collateralDeltaAmount = min;
                    }
                }
            } else {
                // when partial deutilizing
                BasisStrategyState.setUtilizingExecutionCost(
                    BasisStrategyState.getReservedExecutionCost().mulDiv(amount, uncappedDeutilization)
                );
                uint256 positionNetBalance = _hedgeManager.positionNetBalance();
                uint256 currentLeverage = _hedgeManager.currentLeverage();
                uint256 _targetLeverage = BasisStrategyState.getTargetLeverage();
                // when current leverage is bigger than target leverage,
                // don't account for pending decrease collateral
                uint256 _pendingDecreaseCollateral =
                    currentLeverage > _targetLeverage ? 0 : BasisStrategyState.getPendingDecreaseCollateral();
                if (_pendingDecreaseCollateral > 0) {
                    (, positionNetBalance) = positionNetBalance.trySub(_pendingDecreaseCollateral);
                }
                uint256 positionSizeInTokens = _hedgeManager.positionSizeInTokens();
                uint256 collateralDeltaToDecrease = positionNetBalance.mulDiv(amount, positionSizeInTokens);
                collateralDeltaToDecrease += _pendingDecreaseCollateral;
                uint256 limitDecreaseCollateral = _hedgeManager.limitDecreaseCollateral();
                if (collateralDeltaToDecrease < limitDecreaseCollateral) {
                    if (currentLeverage > _targetLeverage) {
                        // when current leverage is bigger than target leverage,
                        // don't account for pending decrease collateral
                        BasisStrategyState.setPendingDecreaseCollateral(0);
                    } else {
                        // when current leverage is smaller than target leverage,
                        // we should decrease accumulated pending decrease collateral
                        BasisStrategyState.setPendingDecreaseCollateral(collateralDeltaToDecrease);
                    }
                } else {
                    collateralDeltaAmount = collateralDeltaToDecrease;
                }
            }
        }

        if (sizeDeltaInTokens == type(uint256).max) {
            Position.adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false, true);
            if (_spotManager.isXChain()) {
                _spotManager.sell(amount, swapType, "");
            } else {
                _spotManager.sell(amount, swapType, swapData);
            }
        } else {
            if (_spotManager.isXChain()) {
                uint256 round = Position.adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false, false);
                _spotManager.sell(amount, swapType, abi.encode(round, collateralDeltaAmount));
            } else {
                Position.adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false, true);
                _spotManager.sell(amount, swapType, swapData);
            }
        }
    }
}
