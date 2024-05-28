// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IGmxV2PositionManager {
    function increasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd) external payable;
    function decreasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd) external payable;
    function claimFunding() external;
    function getExecutionFee() external view returns (uint256 feeIncrease, uint256 feeDecrease);
    function needSettle() external view returns (bool);
    function needAdjustPositionSize() external view returns (bool isNeed, int256 deltaSizeInTokens);
}
