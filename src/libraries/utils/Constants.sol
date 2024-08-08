// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Constants {
    uint256 internal constant FLOAT_PRECISION = 1e18;
    uint8 internal constant DECIMAL_OFFSET = 2;
    uint256 internal constant REBALANCE_BOUNDRY = 0.05 ether;
    uint256 internal constant SIZE_DELTA_DEVIATION_BOUNDRY = 0.01 ether;
}
