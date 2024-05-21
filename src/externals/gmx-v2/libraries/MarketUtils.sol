// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";

import {Market} from "./Market.sol";
import {Position} from "./Position.sol";
import {Price} from "./Price.sol";

// @title MarketUtils
// @dev Library for market functions
library MarketUtils {
    enum FundingRateChangeType {
        NoChange,
        Increase,
        Decrease
    }

    // @dev struct to store the prices of tokens of a market
    // @param indexTokenPrice price of the market's index token
    // @param longTokenPrice price of the market's long token
    // @param shortTokenPrice price of the market's short token
    struct MarketPrices {
        Price.Props indexTokenPrice;
        Price.Props longTokenPrice;
        Price.Props shortTokenPrice;
    }

    struct CollateralType {
        uint256 longToken;
        uint256 shortToken;
    }

    struct PositionType {
        CollateralType long;
        CollateralType short;
    }

    // @dev struct for the result of the getNextFundingAmountPerSize call
    // note that abs(nextSavedFundingFactorPerSecond) may not equal the fundingFactorPerSecond
    // see getNextFundingFactorPerSecond for more info
    struct GetNextFundingAmountPerSizeResult {
        bool longsPayShorts;
        uint256 fundingFactorPerSecond;
        int256 nextSavedFundingFactorPerSecond;
        PositionType fundingFeeAmountPerSizeDelta;
        PositionType claimableFundingAmountPerSizeDelta;
    }

    struct GetNextFundingAmountPerSizeCache {
        PositionType openInterest;
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
        uint256 durationInSeconds;
        uint256 sizeOfLargerSide;
        uint256 fundingUsd;
        uint256 fundingUsdForLongCollateral;
        uint256 fundingUsdForShortCollateral;
    }

    struct GetNextFundingFactorPerSecondCache {
        uint256 diffUsd;
        uint256 totalOpenInterest;
        uint256 fundingFactor;
        uint256 fundingExponentFactor;
        uint256 diffUsdAfterExponent;
        uint256 diffUsdToOpenInterestFactor;
        int256 savedFundingFactorPerSecond;
        uint256 savedFundingFactorPerSecondMagnitude;
        int256 nextSavedFundingFactorPerSecond;
        int256 nextSavedFundingFactorPerSecondWithMinBound;
    }

    struct FundingConfigCache {
        uint256 thresholdForStableFunding;
        uint256 thresholdForDecreaseFunding;
        uint256 fundingIncreaseFactorPerSecond;
        uint256 fundingDecreaseFactorPerSecond;
        uint256 minFundingFactorPerSecond;
        uint256 maxFundingFactorPerSecond;
    }

    struct GetExpectedMinTokenBalanceCache {
        uint256 poolAmount;
        uint256 swapImpactPoolAmount;
        uint256 claimableCollateralAmount;
        uint256 claimableFeeAmount;
        uint256 claimableUiFeeAmount;
        uint256 affiliateRewardAmount;
    }
}
