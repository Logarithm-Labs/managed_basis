// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IBasisStrategy {
    function initialize(address asset, address product, string memory name, string memory symbol) external;
    function setPositionManager(address positionManager) external;
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
    function targetLeverage() external view returns (uint256);

    // callback logic
    function afterIncreasePositionSize(uint256 amountExecuted, bool isSuccess) external;
    function afterDecreasePositionSize(uint256 amountExecuted, uint256 executionCost, bool isSuccess) external;
    function afterIncreasePositionCollateral(uint256 collateralAmount, bool isSuccess) external;
    function afterDecreasePositionCollateral(uint256 collateralAmount, bool isSuccess) external;
    function afterExecuteRequest(bytes32 requestId) external;
}
