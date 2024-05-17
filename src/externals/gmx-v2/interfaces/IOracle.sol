// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Price} from "../libraries/Price.sol";

interface IOracle {
    function getPrimaryPrice(address token) external view returns (Price.Props memory);
}
