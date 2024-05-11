// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { IPriceFeed } from "src/interfaces/IPriceFeed.sol";

import { Errors } from "src/Errors.sol";

contract LogarithmOracle {

    mapping(address => IPriceFeed) public priceFeeds;

    event PriceFeedUpdated(address asset, address feed);

    function setPriceFeeds(
        address[] calldata assets,
        address[] calldata feeds
    ) external {
        if (assets.length != feeds.length) {
            revert Errors.IncosistentParamsLength();
        }
        for (uint256 i = 0; i < assets.length; i++) {
            priceFeeds[assets[i]] = IPriceFeed(feeds[i]);
            emit PriceFeedUpdated(assets[i], feeds[i]);
        }
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        IPriceFeed priceFeed = priceFeeds[asset];
        int256 price = priceFeed.latestAnswer();
        if (price > 0) {
            return uint256(price);
        } else {
            revert Errors.OracleInvalidPrice();
        }

    }
    
}