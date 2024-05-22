// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {IOracle} from "src/interfaces/IOracle.sol";
import {Errors} from "src/libraries/Errors.sol";

contract LogarithmOracle is IOracle, Ownable2Step {
    uint256 public constant FLOAT_PRECISION = 1e30;

    mapping(address asset => IPriceFeed) public priceFeeds;
    mapping(address priceFeed => uint256) public heartbeatDurations;

    event PriceFeedUpdated(address asset, address feed, uint256 heartbeatDuration);

    constructor() Ownable(msg.sender) {}

    function renounceOwnership() public pure override {
        revert();
    }

    function setPriceFeeds(address[] calldata assets, address[] calldata feeds, uint256[] calldata heartbeats)
        external
        onlyOwner
    {
        uint256 len = assets.length;
        if (len != feeds.length || len != heartbeats.length) {
            revert Errors.IncosistentParamsLength();
        }
        for (uint256 i; i < len;) {
            priceFeeds[assets[i]] = IPriceFeed(feeds[i]);
            heartbeatDurations[feeds[i]] = heartbeats[i];
            unchecked {
                ++i;
            }
            emit PriceFeedUpdated(assets[i], feeds[i], heartbeats[i]);
        }
    }

    /// @dev returns token price in (30 - decimal of token)
    /// so that the usd value of token has 30 decimals
    /// for example, if usdc has 6 decimals, then this returns its price in 30 - 6 = 24 decimals
    function getAssetPrice(address asset) external view override returns (uint256) {
        IPriceFeed priceFeed = priceFeeds[asset];

        if (address(priceFeed) == address(0)) {
            revert Errors.PriceFeedNotConfigured();
        }

        (
            /* uint80 roundID */
            ,
            int256 _price,
            /* uint256 startedAt */
            ,
            uint256 timestamp,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        if (_price <= 0) {
            revert Errors.InvalidFeedPrice(asset, _price);
        }

        // in case chainlink price feeds are not updated
        uint256 heartbeatDuration = heartbeatDurations[address(priceFeed)];
        if (block.timestamp > timestamp && block.timestamp - timestamp > heartbeatDuration) {
            revert Errors.PriceFeedNotUpdated(asset, timestamp, heartbeatDuration);
        }

        uint256 price = SafeCast.toUint256(_price);

        // decimal of adjustedPrice should be 30 - token decimal
        // and adjustedPrice = price * precision
        // hence, precition = 10^(30 - token decimal - feed decimal)
        // btw, token decimal + feed decimal could be more than 30
        // so we use adjustedPrice = price * precision / 10^30
        // then precision = 10^(60 - token decimal - feed decimal)
        uint256 precision = 10 ** (60 - uint256(IERC20Metadata(asset).decimals()) - uint256(priceFeed.decimals()));

        if (precision == 0) {
            revert Errors.EmptyPriceFeedMultiplier(asset);
        }

        uint256 adjustedPrice = Math.mulDiv(price, precision, FLOAT_PRECISION);

        return adjustedPrice;
    }
}
