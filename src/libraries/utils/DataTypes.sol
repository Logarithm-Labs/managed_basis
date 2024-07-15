// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library DataTypes {
    /*//////////////////////////////////////////////////////////////
                                ENUMS   
    //////////////////////////////////////////////////////////////*/

    enum SwapType {
        MANUAL,
        INCH_V6
    }

    enum StrategyStatus {
        IDLE,
        NEED_KEEP,
        KEEPING,
        DEPOSITING,
        WITHDRAWING,
        REBALANCING_UP, // increase leverage
        REBALANCING_DOWN // decrease leverage

    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY DATATYPES   
    //////////////////////////////////////////////////////////////*/

    struct WithdrawState {
        uint256 requestTimestamp;
        uint256 requestedAmount;
        uint256 executedFromSpot;
        uint256 executedFromIdle;
        uint256 executedFromHedge;
        uint256 executionCost;
        address receiver;
        address callbackTarget;
        bool isExecuted;
        bool isClaimed;
        bytes callbackData;
    }

    struct StrategyStateChache {
        uint256 assetsToClaim;
        uint256 assetsToWithdraw;
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 totalPendingWithdraw;
        uint256 withdrawnFromSpot;
        uint256 withdrawnFromIdle;
        uint256 withdrawingFromHedge;
        uint256 spotExecutionPrice;
    }

    struct StrategyAddresses {
        address asset;
        address product;
        address oracle;
        address operator;
        address positionManager;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSITOR DATATYPES   
    //////////////////////////////////////////////////////////////*/

    struct DepositParams {
        address caller;
        address receiver;
        uint256 assets;
        uint256 shares;
        uint256 targetLeverage;
        StrategyStateChache cache;
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
        StrategyAddresses addr;
        StrategyStateChache cache;
        bytes callbackData;
    }

    struct ClaimParams {
        address caller;
        WithdrawState withdrawState;
        StrategyStateChache cache;
    }
}
