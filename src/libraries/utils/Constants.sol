// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Constants {
    uint256 internal constant FLOAT_PRECISION = 1e18;
    uint256 internal constant USD_PRECISION = 1e30;
    uint128 internal constant MAX_BUY_RESPONSE_FEE = 0.0001 ether;
    uint128 internal constant MAX_SELL_RESPONSE_FEE = 0.0001 ether;
}
