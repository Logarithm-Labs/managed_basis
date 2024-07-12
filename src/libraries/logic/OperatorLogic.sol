// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

import {AccountingLogic} from "src/libraries/logic/AccountingLogic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {InchAggregatorV6Logic} from "src/libraries/InchAggregatorV6Logic.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library OperatorLogic {
    using Math for uint256;
    using SafeERC20 for IERC20;

    struct UtilizeParams {
        uint256 amount;
        CompactBasisStrategy.StrategyStatus status;
        CompactBasisStrategy.SwapType swapType;
        CompactBasisStrategy.StrategyAddresses addr;
        CompactBasisStrategy.StrategyStateChache cache;
        bytes swapData;
    }

    function executeUtilize(UtilizeParams memory params)
        external
        returns (bool success, CompactBasisStrategy.StrategyStateChache memory)
    {
        uint256 idleAssets = AccountingLogic.getIdleAssets(params.addr.asset, params.cache);
        params.amount = params.amount > idleAssets ? idleAssets : params.amount;
        params.amount =
            params.amount > params.cache.pendingUtilization ? params.cache.pendingUtilization : params.amount;

        if (params.amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        if (params.swapType == CompactBasisStrategy.SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(
                params.amount, params.addr.asset, params.addr.product, true, params.swapData
            );
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        if (success) {
            uint256 collateralDeltaAmount;
            if (params.cache.pendingIncreaseCollateral > 0) {
                collateralDeltaAmount =
                    params.cache.pendingIncreaseCollateral.mulDiv(params.amount, params.cache.pendingUtilization);
                IERC20(params.addr.asset).safeTransfer(params.addr.positionManager, collateralDeltaAmount);
                params.cache.pendingIncreaseCollateral -= collateralDeltaAmount;
            }
            IPositionManager(params.addr.positionManager).adjustPosition(amountOut, collateralDeltaAmount, true);
            params.cache.spotExecutionPrice = params.amount.mulDiv(
                10 ** IERC20Metadata(params.addr.product).decimals(), amountOut, Math.Rounding.Ceil
            );
            params.cache.pendingUtilization -= params.amount;
        }
        return (success, params.cache);
    }
}
