// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISpotManager} from "../../spot/ISpotManager.sol";
import {ILogarithmVault} from "../../vault/ILogarithmVault.sol";
import {IOracle} from "../../oracle/IOracle.sol";

import {BasisStrategyState, StrategyStatus} from "./BasisStrategyState.sol";
import {Constants} from "../utils/Constants.sol";
import {CommonLib} from "./CommonLib.sol";
import {Position} from "./Position.sol";
import {AssetsState} from "./AssetsState.sol";
import {Errors} from "../utils/Errors.sol";

library Utilization {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @dev Used internally to optimize params of utilization.
    struct InternalPendingUtilization {
        // The totalSupply of connected vault
        uint256 totalSupply;
        // The totalAssets of connected vault
        uint256 totalAssets;
        // The idle assets of connected vault
        uint256 idleAssets;
        // The targetLeverage
        uint256 targetLeverage;
        // The boolean value of storage variable processingRebalanceDown.
        bool processingRebalanceDown;
        // The boolean value tells whether strategy gets paused of not.
        bool paused;
        // The max amount for utilization
        uint256 maxAmount;
    }

    /// @dev This return value should be 0 when rebalancing down or when paused or when the totalSupply is 0.
    function _pendingUtilization(InternalPendingUtilization memory params)
        private
        view
        returns (uint256 amount, uint256 uncappedAmount)
    {
        // don't use utilize function when rebalancing or when totalSupply is zero, or when paused
        if (params.totalSupply == 0 || params.processingRebalanceDown || params.paused) {
            return (0, 0);
        } else {
            uint256 withdrawBuffer = params.totalAssets.mulDiv(
                BasisStrategyState.getConfig().withdrawBufferThreshold(), Constants.FLOAT_PRECISION
            );
            (, uint256 availableAssets) = params.idleAssets.trySub(withdrawBuffer);
            uncappedAmount =
                availableAssets.mulDiv(params.targetLeverage, Constants.FLOAT_PRECISION + params.targetLeverage);
            amount = CommonLib._capAmount(uncappedAmount, params.maxAmount);
            return (amount, uncappedAmount);
        }
    }

    function _calculateDeltaCollateralForUtilize(uint256 _utilization, uint256 _targetLeverage)
        private
        pure
        returns (uint256)
    {
        return _utilization.mulDiv(Constants.FLOAT_PRECISION, _targetLeverage);
    }

    function pendingUtilization(bool _paused) external view returns (uint256 amount, uint256 uncappedAmount) {
        return _pendingUtilization(
            InternalPendingUtilization({
                totalSupply: BasisStrategyState.getVault().totalSupply(),
                totalAssets: BasisStrategyState.getVault().totalAssets(),
                idleAssets: BasisStrategyState.getVault().idleAssets(),
                targetLeverage: BasisStrategyState.getTargetLeverage(),
                processingRebalanceDown: BasisStrategyState.getProcessingRebalanceDown(),
                paused: _paused,
                maxAmount: CommonLib._maxUtilization(
                    BasisStrategyState.getVault().idleAssets(),
                    AssetsState._utilizedAssets(),
                    BasisStrategyState.getMaxUtilizePct()
                )
            })
        );
    }

    function utilize(bool _paused, uint256 amount, ISpotManager.SwapType swapType, bytes calldata swapData) external {
        BasisStrategyState.setStrategyStatus(StrategyStatus.UTILIZING);

        ILogarithmVault _vault = BasisStrategyState.getVault();
        uint256 _targetLeverage = BasisStrategyState.getTargetLeverage();
        uint256 _idleAssets = _vault.idleAssets();
        (uint256 pendingUtilization_, uint256 uncappedUtilization) = _pendingUtilization(
            InternalPendingUtilization({
                totalSupply: _vault.totalSupply(),
                totalAssets: _vault.totalAssets(),
                idleAssets: _idleAssets,
                targetLeverage: _targetLeverage,
                processingRebalanceDown: BasisStrategyState.getProcessingRebalanceDown(),
                paused: _paused,
                maxAmount: CommonLib._maxUtilization(
                    _idleAssets, AssetsState._utilizedAssets(), BasisStrategyState.getMaxUtilizePct()
                )
            })
        );

        amount = CommonLib._capAmount(amount, pendingUtilization_);

        if (amount == uncappedUtilization) {
            BasisStrategyState.setUtilizingExecutionCost(BasisStrategyState.getReservedExecutionCost());
        } else {
            BasisStrategyState.setUtilizingExecutionCost(
                BasisStrategyState.getReservedExecutionCost().mulDiv(amount, uncappedUtilization)
            );
        }

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        ISpotManager _spotManager = BasisStrategyState.getSpotManager();
        IERC20 _asset = BasisStrategyState.getAsset();

        _asset.safeTransferFrom(address(_vault), address(_spotManager), amount);

        if (_spotManager.isXChain()) {
            // apply asynchronous utilization
            uint256 collateralDeltaAmount = _calculateDeltaCollateralForUtilize(amount, _targetLeverage);
            uint256 estimatedProductAmount = BasisStrategyState.getOracle().convertTokenAmount(
                address(_asset), address(BasisStrategyState.getProduct()), amount
            );
            // don't emit hedge request
            uint256 round = Position.adjustPosition(estimatedProductAmount, collateralDeltaAmount, true, false);
            _spotManager.buy(amount, swapType, abi.encode(round, collateralDeltaAmount));
        } else {
            // apply synchronous utilization
            _spotManager.buy(amount, swapType, swapData);
        }
    }
}
