// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./Position.sol";
import "./Market.sol";
import "./ReaderPricingUtils.sol";
import "./PositionPricingUtils.sol";

// @title ReaderPositionUtils
// @dev Library for read utils functions
// convers some internal library functions into external functions to reduce
// the Reader contract size
library ReaderPositionUtils {
    struct PositionInfo {
        Position.Props position;
        PositionPricingUtils.PositionFees fees;
        ReaderPricingUtils.ExecutionPriceResult executionPriceResult;
        int256 basePnlUsd;
        int256 uncappedBasePnlUsd;
        int256 pnlAfterPriceImpactUsd;
    }
}
