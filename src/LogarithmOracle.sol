// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IPriceFeed} from "src/interfaces/IPriceFeed.sol";

import {Errors} from "src/libraries/Errors.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract LogarithmOracle is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    mapping(address => IPriceFeed) public priceFeeds;

    event PriceFeedUpdated(address asset, address feed);

    struct LogarithmOracleStorage {
        mapping(address => IPriceFeed) priceFeeds;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedBasisStrategyStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LogarithmOracleStorageLocation = 0xaf7f9ee2bf6df4652c22f2985b1d5158d032a69025fa7f00df5c4473100fe400;

    function _getLogarithmOracleStorage() private pure returns (LogarithmOracleStorage storage $) {
        assembly {
            $.slot := LogarithmOracleStorageLocation
        }
    }

    function initialize(address owner) external initializer {
        __Ownable_init(owner);
    }

    function _authorizeUpgrade(address /*newImplementation*/) internal virtual override onlyOwner {}

    function setPriceFeeds(address[] calldata assets, address[] calldata feeds) external onlyOwner {
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
