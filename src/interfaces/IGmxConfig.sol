// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IGmxConfig {
    function dataStore() external view returns (address);

    function exchangeRouter() external view returns (address);

    function orderHandler() external view returns (address);

    function orderVault() external view returns (address);

    function referralStorage() external view returns (address);

    function reader() external view returns (address);

    function callbackGasLimit() external view returns (uint256);

    function referralCode() external view returns (bytes32);

    function maxClaimableFundingShare() external view returns (uint256);

    function limitDecreaseCollateral() external view returns (uint256);
}
