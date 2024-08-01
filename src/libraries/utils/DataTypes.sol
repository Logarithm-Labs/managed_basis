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
        KEEPING,
        DEPOSITING,
        WITHDRAWING,
        NEED_REBLANCE_DOWN,
        REBALANCING_UP, // increase leverage
        REBALANCING_DOWN // decrease leverage

    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY DATATYPES   
    //////////////////////////////////////////////////////////////*/

    struct StrategyStateChache {
        uint256 assetsToClaim;
        uint256 assetsToWithdraw;
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        uint256 pendingDecreaseCollateral;
    }
    // StrategyStatus strategyStatus;

    struct StrategyWithdrawCache {
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
    }

    struct StrategyAddresses {
        address asset;
        address product;
        address oracle;
        address operator;
        address positionManager;
    }

    struct StrategyLeverages {
        uint256 currentLeverage;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
    }

    struct WithdrawRequestState {
        uint256 requestedAmount;
        uint256 accRequestedWithdrawAssets;
        uint256 requestTimestamp;
        address receiver;
        bool isClaimed;
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
        WithdrawRequestState withdrawState;
        StrategyStateChache cache;
    }
}
