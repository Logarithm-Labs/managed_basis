// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IPositionManager {
    /// @dev Used to adjust positions.
    struct AdjustPositionPayload {
        uint256 sizeDeltaInTokens;
        uint256 collateralDeltaAmount;
        bool isIncrease;
    }

    /// @dev The address of position's collateral token.
    function collateralToken() external view returns (address);

    /// @dev The address of position's index token.
    function indexToken() external view returns (address);

    /// @dev The total collateral asset amount including pending.
    function positionNetBalance() external view returns (uint256);

    /// @dev The position's leverage.
    function currentLeverage() external view returns (uint256);

    /// @dev The position's size in index token.
    function positionSizeInTokens() external view returns (uint256);

    /// @dev Called when position is needed to keep.
    function keep() external;

    /// @dev Determines if the keep function has effects.
    function needKeep() external view returns (bool);

    /// @dev Called when requesting to adjust positions.
    function adjustPosition(AdjustPositionPayload calldata requestParams) external;

    /// @dev The collateral size limits when increasing.
    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    /// @dev The index size limits when increasing.
    function increaseSizeMinMax() external view returns (uint256 min, uint256 max);

    /// @dev The collateral size limits when decreasing.
    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    /// @dev The index size limits when decreasing.
    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max);

    /// @dev The minimum decrease collateral amount that is required for execution cost saving.
    function limitDecreaseCollateral() external view returns (uint256);
}
