// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {Market} from "../libraries/Market.sol";

interface IReader {
    function getMarket(address dataStore, address key) external view returns (Market.Props memory);
}
