// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {Chain} from "src/externals/gmx-v2/libraries/Chain.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";


import {Errors} from "./Errors.sol";

library GmxV2Lib {
    /// @dev returns token price in (30 - decimal of token)
    /// so that the usd value of token has 30 decimals
    /// for example, if usdc has 6 decimals, then this returns its price in 30 - 6 = 24 decimals
    function getPriceFeedPrice(IDataStore dataStore, address token) internal view returns (uint256) {
        address priceFeedAddress = dataStore.getAddress(Keys.priceFeedKey(token));
        if (priceFeedAddress == address(0)) {
            revert Errors.PriceFeedNotConfigured();
        }

        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);

        (
            /* uint80 roundID */,
            int256 _price,
            /* uint256 startedAt */,
            uint256 timestamp,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        if (_price <= 0) {
            revert Errors.InvalidFeedPrice(token, _price);
        }

        uint256 heartbeatDuration = dataStore.getUint(Keys.priceFeedHeartbeatDurationKey(token));
        if (Chain.currentTimestamp() > timestamp && Chain.currentTimestamp() - timestamp > heartbeatDuration) {
            revert Errors.PriceFeedNotUpdated(token, timestamp, heartbeatDuration);
        }

        uint256 price = SafeCast.toUint256(_price);

        uint256 precision = dataStore.getUint(Keys.priceFeedMultiplierKey(token));

        if (precision == 0) {
            revert Errors.EmptyPriceFeedMultiplier(token);
        }

        uint256 adjustedPrice = Precision.mulDiv(price, precision, Precision.FLOAT_PRECISION);

        return adjustedPrice;
    }
}
