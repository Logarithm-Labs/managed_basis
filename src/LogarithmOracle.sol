// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {IOracle} from "src/interfaces/IOracle.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

contract LogarithmOracle is IOracle, UUPSUpgradeable, Ownable2StepUpgradeable {
    uint256 public constant FLOAT_PRECISION = 1e30;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.LogarithmOracle
    struct LogarithmOracleStorage {
        mapping(address asset => IPriceFeed) priceFeeds;
        mapping(address priceFeed => uint256) heartbeatDurations;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.LogarithmOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LogarithmOracleStorageLocation =
        0x2c93e30cf348944d3203d68cfbfc99aa913023170c5de2049def7c26b25c6400;

    function _getLogarithmOracleStorage() private pure returns (LogarithmOracleStorage storage $) {
        assembly {
            $.slot := LogarithmOracleStorageLocation
        }
    }

    event PriceFeedUpdated(address asset, address feed);
    event HeartBeatUpdated(address asset, uint256 heartbeatDuration);

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function renounceOwnership() public pure override {
        revert();
    }

    function setPriceFeeds(address[] calldata assets, address[] calldata feeds) external onlyOwner {
        uint256 len = assets.length;
        if (len != feeds.length) {
            revert Errors.IncosistentParamsLength();
        }
        for (uint256 i; i < len;) {
            _getLogarithmOracleStorage().priceFeeds[assets[i]] = IPriceFeed(feeds[i]);
            emit PriceFeedUpdated(assets[i], feeds[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setHeartbeats(address[] calldata feeds, uint256[] calldata heartbeats) external onlyOwner {
        uint256 len = feeds.length;
        if (len != heartbeats.length) {
            revert Errors.IncosistentParamsLength();
        }
        for (uint256 i; i < len;) {
            _getLogarithmOracleStorage().heartbeatDurations[feeds[i]] = heartbeats[i];
            emit HeartBeatUpdated(feeds[i], heartbeats[i]);
            unchecked {
                ++i;
            }
        }
    }

    function getPriceFeed(address asset) external view returns (address) {
        return address(_getLogarithmOracleStorage().priceFeeds[asset]);
    }

    /// @dev returns token price in (30 - decimal of token)
    /// so that the usd value of token has 30 decimals
    /// for example, if usdc has 6 decimals, then this returns its price in 30 - 6 = 24 decimals
    function getAssetPrice(address asset) public view override returns (uint256) {
        IPriceFeed priceFeed = _getLogarithmOracleStorage().priceFeeds[asset];

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
        uint256 heartbeatDuration = _getLogarithmOracleStorage().heartbeatDurations[address(priceFeed)];
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

    function convertTokenAmount(address from, address to, uint256 amount) external view returns (uint256) {
        uint256 fromPrice = getAssetPrice(from);
        uint256 toPrice = getAssetPrice(to);

        return Math.mulDiv(amount, fromPrice, toPrice);
    }
}
