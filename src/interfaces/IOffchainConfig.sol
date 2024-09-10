// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IOffchainConfig {
    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    function increaseSizeMinMax() external view returns (uint256 min, uint256 max);

    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max);

    function limitDecreaseCollateral() external view returns (uint256);
}
