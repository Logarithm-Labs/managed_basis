// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "src/externals/gmx-v2/interfaces/IDataStore.sol";
import "src/externals/gmx-v2/interfaces/IReferralStorage.sol";

import "src/externals/gmx-v2/libraries/Market.sol";
import "src/externals/gmx-v2/libraries/MarketUtils.sol";
import "src/externals/gmx-v2/libraries/ReaderUtils.sol";

interface IReader {
    function getMarket(address dataStore, address key) external view returns (Market.Props memory);

    function getPosition(IDataStore dataStore, bytes32 key) external view returns (Position.Props memory);

    function getPositionInfo(
        IDataStore dataStore,
        IReferralStorage referralStorage,
        bytes32 positionKey,
        MarketUtils.MarketPrices memory prices,
        uint256 sizeDeltaUsd,
        address uiFeeReceiver,
        bool usePositionSizeAsSizeDeltaUsd
    ) external view returns (ReaderUtils.PositionInfo memory);
}
