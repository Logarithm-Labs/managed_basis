// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";

import {AccountingLogic} from "src/libraries/logic/AccountingLogic.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

library DepositorLogic {
    using Math for uint256;

    struct DepositParams {
        address caller;
        address receiver;
        uint256 assets;
        uint256 shares;
        uint256 targetLeverage;
        DataTypes.StrategyStateChache cache;
    }

    struct WithdrawParams {
        address caller;
        address receiver;
        address owner;
        address callbackTarget;
        uint256 assets;
        uint256 shares;
        uint256 requestCounter;
        uint256 targetLeverage;
        DataTypes.StrategyAddresses addr;
        DataTypes.StrategyStateChache cache;
        bytes callbackData;
    }

    struct ClaimParams {
        address caller;
        DataTypes.WithdrawState withdrawState;
        DataTypes.StrategyStateChache cache;
    }

    function executeDeposit(DepositParams memory params) external pure returns (DataTypes.StrategyStateChache memory) {
        if (params.cache.totalPendingWithdraw >= params.assets) {
            params.cache.assetsToWithdraw += params.assets;
            params.cache.withdrawnFromIdle += params.assets;
            params.cache.totalPendingWithdraw -= params.assets;
        } else {
            uint256 assetsToDeposit = params.assets - params.cache.totalPendingWithdraw;
            uint256 assetsToHedge =
                assetsToDeposit.mulDiv(Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + params.targetLeverage);
            uint256 assetsToSpot = assetsToDeposit - assetsToHedge;

            if (params.cache.totalPendingWithdraw > 0) {
                params.cache.assetsToWithdraw += params.cache.totalPendingWithdraw;
                params.cache.withdrawnFromIdle += params.cache.totalPendingWithdraw;
                params.cache.totalPendingWithdraw = 0;
            }

            params.cache.pendingUtilization += assetsToSpot;
            params.cache.pendingIncreaseCollateral += assetsToHedge;
        }

        return params.cache;
    }

    function executeWithdraw(WithdrawParams memory params)
        external
        view
        returns (bytes32, uint256, DataTypes.StrategyStateChache memory, DataTypes.WithdrawState memory)
    {
        (, uint256 idleAssets, uint256 totalAssets) = AccountingLogic.getTotalAssets(params.addr, params.cache);
        bytes32 withdrawId;
        uint256 requestedAmount;
        DataTypes.WithdrawState memory withdrawState;
        if (idleAssets >= params.assets) {
            uint256 assetsWithdrawnFromSpot =
                params.assets.mulDiv(params.targetLeverage, Constants.FLOAT_PRECISION + params.targetLeverage);
            (, params.cache.pendingUtilization) = params.cache.pendingUtilization.trySub(assetsWithdrawnFromSpot);
            (, params.cache.pendingIncreaseCollateral) =
                params.cache.pendingIncreaseCollateral.trySub(params.assets - assetsWithdrawnFromSpot);
        } else {
            requestedAmount = params.assets > totalAssets ? totalAssets : params.assets;
            withdrawId = getWithdrawId(params.owner, params.requestCounter);
            withdrawState = DataTypes.WithdrawState({
                requestTimestamp: uint128(block.timestamp),
                requestedAmount: requestedAmount,
                executedFromSpot: 0,
                executedFromIdle: 0,
                executedFromHedge: 0,
                executionCost: 0,
                receiver: params.receiver,
                callbackTarget: address(0),
                isExecuted: false,
                isClaimed: false,
                callbackData: ""
            });

            params.cache.pendingUtilization = 0;
            params.cache.pendingIncreaseCollateral = 0;
            params.cache.withdrawnFromIdle += idleAssets;
            params.cache.totalPendingWithdraw += (requestedAmount - idleAssets);

            uint256 pendingDeutilizationInAsset = params.cache.totalPendingWithdraw.mulDiv(
                params.targetLeverage, Constants.FLOAT_PRECISION + params.targetLeverage
            );
            uint256 pendingDeutilization = IOracle(params.addr.oracle).convertTokenAmount(
                params.addr.asset, params.addr.product, pendingDeutilizationInAsset
            );
            uint256 productBalance = IERC20(params.addr.product).balanceOf(address(this));

            params.cache.pendingDeutilization =
                pendingDeutilization > productBalance ? productBalance : pendingDeutilization;
            params.cache.assetsToWithdraw += idleAssets;
        }
        return (withdrawId, requestedAmount, params.cache, withdrawState);
    }

    function executeClaim(ClaimParams memory params)
        external
        view
        returns (uint256, DataTypes.StrategyStateChache memory, DataTypes.WithdrawState memory)
    {
        if (params.withdrawState.receiver != params.caller) {
            revert Errors.UnauthorizedClaimer(msg.sender, params.withdrawState.receiver);
        }
        if (!params.withdrawState.isExecuted) {
            revert Errors.RequestNotExecuted();
        }
        if (params.withdrawState.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        uint256 executedAmount = params.withdrawState.executedFromSpot + params.withdrawState.executedFromIdle
            + params.withdrawState.executedFromHedge;
        params.cache.assetsToClaim -= executedAmount;
        params.withdrawState.isClaimed = true;

        return (executedAmount, params.cache, params.withdrawState);
    }

    function getWithdrawId(address owner, uint256 counter) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }
}
