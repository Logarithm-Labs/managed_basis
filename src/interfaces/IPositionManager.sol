// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IPositionManager {
    struct AdjustPositionPayload {
        uint256 sizeDeltaInTokens;
        uint256 collateralDeltaAmount;
        bool isIncrease;
    }

    function apiVersion() external view returns (string memory);

    function positionNetBalance() external view returns (uint256);

    function currentLeverage() external view returns (uint256);

    function positionSizeInTokens() external view returns (uint256);

    function keep() external;

    function needKeep() external view returns (bool);

    function adjustPosition(AdjustPositionPayload calldata requestParams) external;

    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    function increaseSizeMinMax() external view returns (uint256 min, uint256 max);

    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max);
}
