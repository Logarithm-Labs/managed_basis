// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IGmxV2PositionManager {
    function initialize(address strategy) external;
    /// @notice Used to track the deployed version of this contract. In practice you
    /// can use this version number to compare with Logarithm's GitHub and
    /// determine which version of the source matches this deployed contract
    ///
    /// @dev
    /// All contracts must have an `apiVersion()` that matches the Vault's
    /// `API_VERSION`.
    function apiVersion() external view returns (string memory);

    /// @dev set position manager's operator
    function setOperator(address operator) external;

    /// @dev create an increase order
    /// Note: value should be sent to cover the gmx execution fee
    /// this function is callable only by strategy vault
    /// gmx uses offchain prices so it is much more accurate to use usd value for position size
    /// instead of token value
    ///
    /// @param collateralDelta collateral delta amount in collateral token to increase
    /// @param sizeDeltaInUsd position delta size in usd to increase
    function increasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd) external payable;

    /// @dev create a decrease order
    /// Note: value should be sent to cover the gmx execution fee
    /// this function is callable only by strategy vault
    /// gmx uses offchain prices so it is much more accurate to use usd value for position size
    /// instead of token value
    ///
    /// @param collateralDelta collateral delta amount in collateral token to decrease
    /// @param sizeDeltaInUsd position delta size in usd to decrease
    function decreasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd) external payable;

    /// @dev claims all the claimable funding fee
    /// this is callable by anyone
    function claimFunding() external;

    /// @dev claims all the claimable callateral amount
    /// Note: this amount stored by account, token, timeKey
    /// and there is only event to figure out it
    /// @param token token address derived from the gmx event: ClaimableCollateralUpdated
    /// @param timeKey timeKey value derived from the gmx event: ClaimableCollateralUpdated
    function claimCollateral(address token, uint256 timeKey) external;

    /// @notice total asset token amount that can be claimable from gmx position when closing it
    ///
    /// @dev this amount includes the pending asset token amount
    function totalAssets() external view returns (uint256);
}
