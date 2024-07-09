// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {Errors} from "src/libraries/Errors.sol";

library DepositorLogic {
    using Math for uint256;

    struct DepositParams {
        address caller;
        address receiver;
        uint256 assets;
        uint256 shares;
        CompactBasisStrategy.StrategyStateChache cache;
    }

    struct WithdrawParams {
        address asset;
        address product;
        address caller;
        address receiver;
        address owner;
        address callbackTarget;
        address oracle;
        uint256 assets;
        uint256 shares;
        uint256 totalAssets;
        uint256 idleAssets;
        uint256 requestCounter;
        uint256 targetLeverage;
        CompactBasisStrategy.StrategyStateChache cache;
        bytes callbackData;
    }

    struct ClaimParams {
        address caller;
        CompactBasisStrategy.WithdrawState withdrawState;
        CompactBasisStrategy.StrategyStateChache cache;
    }

    function executeDeposit(DepositParams memory params) external virtual returns (StrategyStateChache memory cache) {
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

    function executeWithdraw(WithdrawParams memory params)
        external
        virtual
        returns (
            bytes32 withdrawId,
            uint256 requestedAmount,
            CompactBasisStrategy.StrategyStateChache memory cache,
            CompactBasisStrategy.WithdrawState memory withdrawState
        )
    {
        cache = params.cache;
        requestedAmount = assets > params.totalAssets ? params.totalAssets : assets;
        withdrawId = getWithdrawId(owner, counter);
        withdrawState = CompactBasisStrategy.WithdrawState({
            requestTimestamp: uint128(block.timestamp),
            requestedAmount: requestedAmount,
            executedFromSpot: 0,
            executedFromIdle: 0,
            executedFromHedge: 0,
            executionCost: 0,
            receiver: receiver,
            callbackTarget: address(0),
            isExecuted: false,
            isClaimed: false,
            callbackData: ""
        });

        cache.pendingUtilization = 0;
        cache.pendingIncreaseCollateral = 0;
        cache.withdawnFromIdle += params.idle;
        cache.totalPendingWithdraw += (requestedAmount - params.idle);
        uint256 pendingDeutilizationInAsset =
            cache.totalPendingWithdraw.mulDiv(params.targetLeverage, PRECISION + params.targetLeverage);
        uint256 pendingDeutilization =
            IOracle(params.oracle).convertTokenAmount(params.asset, params.product, pendingDeutilizationInAsset);
        uint256 productBalance = IERC20(params.product).balanceOf(address(this));
        cache.pendingDeutilization = pendingDeutilization > productBalance ? productBalance : pendingDeutilization;
        cache.assetsToWithdraw += params.idle;
    }

    function executeClaim(ClaimParams memory params)
        external
        virtual
        returns (
            uint256 executedAmount,
            StrategyStateChache memory cache,
            CompactBasisStrategy.WithdrawState memory withdrawState
        )
    {
        if (params.withdrawState.recevier != params.caller) {
            revert Errors.UnauthorizedClaimer(msg.sender, params.withdrawState.receiver);
        }
        if (!prarams.withdrawStaete.isExecuted) {
            revert Errors.RequestNotExecuted();
        }
        if (params.withdrawState.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        cache = params.cache;
        executedAmount = params.withdrawState.executedFromSpot + params.withdrawState.executedFromIdle
            + params.withdrawState.executedFromHedge;
        cache.assetsToClaim -= executedAmount;
        withdrawState.isClaimed = true;
    }

    function getWithdrawId(address owner, uint128 counter) public pure virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }
}
