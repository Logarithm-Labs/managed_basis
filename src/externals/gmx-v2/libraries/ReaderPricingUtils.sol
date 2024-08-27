// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

// @title ReaderPricingUtils
library ReaderPricingUtils {
    struct ExecutionPriceResult {
        int256 priceImpactUsd;
        uint256 priceImpactDiffUsd;
        uint256 executionPrice;
    }
}
