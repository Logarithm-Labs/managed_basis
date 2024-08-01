// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IOffChainPositionManager {
    struct DataTypes.PositionManagerPayload {
        uint256 sizeDeltaInTokens;
        uint256 collateralDeltaAmount;
        bool isIncrease;
    }

    function initialize(
        address strategy,
        address agent,
        address oracle,
        address indexToken,
        address collateralToken,
        bool isLong
    ) external;

    function positionNetBalance() external view returns (uint256);

    function currentLeverage() external view returns (uint256);

    function positionSizeInTokens() external view returns (uint256);

    function adjustPosition(DataTypes.PositionManagerPayload memory params) external;
}
