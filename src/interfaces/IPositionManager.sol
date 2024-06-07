// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IPositionManager {
    function initialize(address strategy) external;
    /// @notice Used to track the deployed version of this contract. In practice you
    /// can use this version number to compare with Logarithm's GitHub and
    /// determine which version of the source matches this deployed contract
    ///
    /// @dev
    /// All contracts must have an `apiVersion()` that matches the Vault's
    /// `API_VERSION`.
    function apiVersion() external view returns (string memory);

    function setKeeper(address keeper) external;

    function positionNetBalance() external view returns (uint256);

    function increasePositionCollateral(uint256 collateralAmount) external;

    function decreasePositionCollateral(uint256 collateralAmount) external;

    function increasePositionSize(uint256 sizeDeltaInTokens, uint256 spotExecutionPrice) external;

    function decreasePositionSize(uint256 sizeDeltaInTokens, uint256 spotExecutionPrice) external;
}
