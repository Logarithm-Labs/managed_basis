// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IBasisStrategy {
    function initialize(address asset, address product, string memory name, string memory symbol) external;
    function setPositionManager(address positionManager) external;
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
    function targetLeverage() external view returns (uint256);
    function hedgeCallback(bool wasExecuted, int256 executionCostAmount, uint256 executedHedgeAmount) external;
}
