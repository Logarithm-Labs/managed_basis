// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

struct PositionManagerCallbackParams {
    uint256 sizeDeltaInTokens;
    uint256 collateralDeltaAmount;
    bool isIncrease;
    bool isSuccess;
}

interface IManagedBasisStrategy {
    function setPositionManager(address positionManager) external;
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
    function targetLeverage() external view returns (uint256);

    // callback logic
    function afterAdjustPosition(PositionManagerCallbackParams calldata params) external;
}
