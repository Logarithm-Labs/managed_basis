// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IOffChainConfig {
    function increaseCollateralMin() external view returns (uint256 min);

    function increaseSizeMin() external view returns (uint256 min);

    function decreaseCollateralMin() external view returns (uint256 min);

    function decreaseSizeMin() external view returns (uint256 min);

    function limitDecreaseCollateral() external view returns (uint256);
}
