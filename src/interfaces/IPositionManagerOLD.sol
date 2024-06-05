// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IPositionManagerOLD {
    function initialize(address strategy) external;
    /// @notice Used to track the deployed version of this contract. In practice you
    /// can use this version number to compare with Logarithm's GitHub and
    /// determine which version of the source matches this deployed contract
    ///
    /// @dev
    /// All contracts must have an `apiVersion()` that matches the Vault's
    /// `API_VERSION`.
    function apiVersion() external view returns (string memory);

    /// @dev set position manager's keeper
    function setKeeper(address keeper) external;

    /// @notice total asset token amount that can be claimable from gmx position when closing it
    ///
    /// @dev this amount includes the pending asset token amount
    function totalAssets() external view returns (uint256);
}
