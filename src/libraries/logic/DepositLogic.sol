// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library DepositLogic {
    using Math for uint256;

    struct DepositParams {
        address asset;
        address caller;
        address receiver;
        uint256 assets;
        uint256 shares;
        StrategyStateChache cache;
    }

    struct WithdrawParams {
        address asset;
        address caller;
        address receiver;
        address owner;
        uint256 assets;
        uint256 targetLeverage;
        uint256 requestCounter;
        StrategyStateChache cache;
    }

    function executeDeposit(DepositParams memory params) external returns (StrategyStateChache memory cache) {
        IERC20(params.asset).safeTransferFrom(params.caller, address(this), params.assets);
        cache = params.cache;
        if (cache.totalPendingWithdraw >= assets) {
            cache.assetsToWithdraw += assets;
            cache.withdrawnFromIdle += assets;
            cache.totalPendingWithdraw -= assets;
        } else {
            uint256 assetsToDeposit = assets - totalPendingWithdraw_;
            uint256 assetsToHedge = assetsToDeposit.mulDiv(PRECISION, PRECISION + $.targetLeverage);
            uint256 assetsToSpot = assetsToDeposit - assetsToHedge;
            if (cache.totalPendingWithdraw > 0) {
                cache.assetsToWithdraw += cache.totalPendingWithdraw;
                cache.withdrawnFromIdle += cache.totalPendingWithdraw;
                cache.totalPendingWithdraw = 0;
            }
            cache.pendingUtilization += assetsToSpot;
            cache.pendingIncreaseCollateral += assetsToHedge;
        }
    }

    function executeWithdraw(WithdrawParams memory params) external returns (StrategyStateChache memory cache) {
        cache = params.cache;
        (, uint256 idle) =
            IERC20(params.asset).balanceOf(address(this)).trySub(chache.assetsToClaim + cache.assetsToWithdraw);
        if (idle >= assets) {
            uint256 assetsWithdrawnFromSpot =
                params.assets.mulDiv(params.targetLeverage, PRECISION + params.targetLeverage);
            (, cache.pendingUtilization) = cache.pendingUtilization.trySub(assetsWithdrawnFromSpot);
            (, cache.pendingIncreaseCollateral) =
                cache.pendingIncreaseCollateral.trySub(params.assets - assetsWithdrawnFromSpot);
            IERC20(params.asset).safeTransfer(params.receiver, params.assets);
        } else {}
    }
}
