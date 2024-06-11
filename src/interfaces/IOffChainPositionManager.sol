// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IOffChainPositionManager {
    function initialize(
        address strategy,
        address agent,
        address oracle,
        address indexToken,
        address collateralToken,
        bool isLong
    ) external;

    function positionNetBalance() external view returns (uint256);

    function adjustPosition(
        uint256 sizeDeltaInTokens,
        uint256 spotExectuionPrice,
        uint256 collateralDeltaAmount,
        bool isIncrease
    ) external returns (bytes32 requestId);
}
