// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IPositionManager {
    function apiVersion() external view returns (string memory);

    function positionNetBalance() external view returns (uint256);

    function positionSizeInTokens() external view returns (uint256);

    function adjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease) external;

    function keep() external;

    function needKeep() external view returns (bool);
}
