// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IBasisGmxFactory {
    /// @notice Used to track the deployed version of this contract. In practice you
    /// can use this version number to compare with Logarithm's GitHub and
    /// determine which version of the source matches this deployed contract
    ///
    /// @dev
    /// All contracts must have an `apiVersion()` that matches the Vault's
    /// `API_VERSION`.
    function apiVersion() external view returns (string memory);

    /// @return the gmx market key
    function marketKey(address asset, address product) external view returns (address);

    /// @return the gmx data store address
    function dataStore() external view returns (address);

    /// @return the gmx reader
    function reader() external view returns (address);

    /// @return the gmx order vault address
    function orderVault() external view returns (address);

    /// @return the gmx referral storage address
    function referralStorage() external view returns (address);

    /// @return the gmx exchange router address
    function exchangeRouter() external view returns (address);

    /// @return the gas limit of position manager's callback function
    function callbackGasLimit() external view returns (uint256);

    /// @return the referral code of protocol
    function referralCode() external view returns (bytes32);

    /// @return the address of gmx OrderHandler
    function orderHandler() external view returns (address);
}
