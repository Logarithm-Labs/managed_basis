// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IPositionManager {
    function initialize(address strategy, address keeper) external;

    function apiVersion() external view returns (string memory);

    function positionNetBalance() external view returns (uint256);

    function increasePositionCollateral(uint256 collateralAmount) external;

    function decreasePositionCollateral(uint256 collateralAmount) external;

    function increasePositionSize(uint256 sizeDeltaInTokens, uint256 spotExecutionPrice) external;

    function decreasePositionSize(uint256 sizeDeltaInTokens, uint256 spotExecutionPrice) external;

    function adjustPosition(
        uint256 sizeDeltaInTokens,
        uint256 spotExectuionPrice,
        uint256 collateralDeltaAmount,
        bool isIncrease
    ) external returns (bytes32 requestId);
}
