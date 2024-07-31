// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IGmxV2PositionManager {
    function claimFunding() external;
    function getExecutionFee() external view returns (uint256 feeIncrease, uint256 feeDecrease);
    function checkUpkeep() external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}
