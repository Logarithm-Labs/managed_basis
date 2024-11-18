// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IHedgeManager {
    /// @dev Payload structure for adjusting hedge positions.
    ///
    /// @param sizeDeltaInTokens The amount to adjust the position size in terms of index tokens.
    /// @param collateralDeltaAmount The amount to adjust the collateral in the position.
    /// @param isIncrease A boolean indicating whether the adjustment is an increase (true) or decrease (false) in position size.
    struct AdjustPositionPayload {
        uint256 sizeDeltaInTokens;
        uint256 collateralDeltaAmount;
        bool isIncrease;
    }

    /// @notice Returns the address of the collateral token used in the position.
    ///
    /// @return The address of the collateral token.
    function collateralToken() external view returns (address);

    /// @notice Returns the address of the index token used in the position.
    ///
    /// @return The address of the index token.
    function indexToken() external view returns (address);

    /// @notice Gets the net collateral balance of the position, including pending adjustments.
    ///
    /// @return The total collateral asset amount in the position.
    function positionNetBalance() external view returns (uint256);

    /// @notice Retrieves the current leverage of the position.
    ///
    /// @return The leverage ratio as a uint256.
    function currentLeverage() external view returns (uint256);

    /// @notice Returns the current size of the position in terms of index tokens.
    ///
    /// @return The size of the position in index tokens.
    function positionSizeInTokens() external view returns (uint256);

    /// @notice Called to maintain or adjust the hedge position as required by strategy logic.
    ///
    /// @dev Executes actions needed to align the position with target hedge requirements.
    function keep() external;

    /// @notice Checks whether the `keep` function needs to be called to maintain the position.
    ///
    /// @return A boolean indicating if `keep` should be executed.
    function needKeep() external view returns (bool);

    /// @notice Called to adjust the hedge position based on specified parameters.
    ///
    /// @param requestParams The parameters used for adjusting the position (size and collateral delta).
    function adjustPosition(AdjustPositionPayload calldata requestParams) external;

    /// @notice Returns the minimum and maximum collateral limits for increasing the position.
    ///
    /// @return min The minimum allowable collateral increase amount.
    /// @return max The maximum allowable collateral increase amount.
    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    /// @notice Returns the minimum and maximum limits for increasing the position size.
    ///
    /// @return min The minimum allowable increase in position size.
    /// @return max The maximum allowable increase in position size.
    function increaseSizeMinMax() external view returns (uint256 min, uint256 max);

    /// @notice Returns the minimum and maximum collateral limits for decreasing the position.
    ///
    /// @return min The minimum allowable collateral decrease amount.
    /// @return max The maximum allowable collateral decrease amount.
    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    /// @notice Returns the minimum and maximum limits for decreasing the position size.
    ///
    /// @return min The minimum allowable decrease in position size.
    /// @return max The maximum allowable decrease in position size.
    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max);

    /// @notice Retrieves the minimum decrease in collateral required for cost-efficient execution.
    ///
    /// @dev Helps in optimizing gas usage and cost efficiency.
    ///
    /// @return The minimum decrease collateral amount that qualifies for cost-effective execution.
    function limitDecreaseCollateral() external view returns (uint256);
}
