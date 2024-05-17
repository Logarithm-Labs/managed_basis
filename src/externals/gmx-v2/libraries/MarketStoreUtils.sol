// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./Keys.sol";
import "./Market.sol";
import "../interfaces/IDataStore.sol";

/**
 * @title MarketStoreUtils
 * @dev Library for market storage functions
 */
library MarketStoreUtils {
    using Market for Market.Props;

    bytes32 internal constant MARKET_SALT = keccak256(abi.encode("MARKET_SALT"));
    bytes32 internal constant MARKET_KEY = keccak256(abi.encode("MARKET_KEY"));
    bytes32 internal constant MARKET_TOKEN = keccak256(abi.encode("MARKET_TOKEN"));
    bytes32 internal constant INDEX_TOKEN = keccak256(abi.encode("INDEX_TOKEN"));
    bytes32 internal constant LONG_TOKEN = keccak256(abi.encode("LONG_TOKEN"));
    bytes32 internal constant SHORT_TOKEN = keccak256(abi.encode("SHORT_TOKEN"));

    function get(IDataStore dataStore, address key) internal view returns (Market.Props memory) {
        Market.Props memory market;
        if (!dataStore.containsAddress(Keys.MARKET_LIST, key)) {
            return market;
        }

        market.marketToken = dataStore.getAddress(keccak256(abi.encode(key, MARKET_TOKEN)));

        market.indexToken = dataStore.getAddress(keccak256(abi.encode(key, INDEX_TOKEN)));

        market.longToken = dataStore.getAddress(keccak256(abi.encode(key, LONG_TOKEN)));

        market.shortToken = dataStore.getAddress(keccak256(abi.encode(key, SHORT_TOKEN)));

        return market;
    }

    function getBySalt(IDataStore dataStore, bytes32 salt) external view returns (Market.Props memory) {
        address key = dataStore.getAddress(getMarketSaltHash(salt));
        return get(dataStore, key);
    }

    function getMarketSaltHash(bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(MARKET_SALT, salt));
    }

    function getMarketCount(IDataStore dataStore) internal view returns (uint256) {
        return dataStore.getAddressCount(Keys.MARKET_LIST);
    }

    function getMarketKeys(IDataStore dataStore, uint256 start, uint256 end) internal view returns (address[] memory) {
        return dataStore.getAddressValuesAt(Keys.MARKET_LIST, start, end);
    }
}
