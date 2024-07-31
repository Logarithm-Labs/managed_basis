// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IOrderHandler {
    struct SetPricesParams {
        address[] tokens;
        address[] providers;
        bytes[] data;
    }

    function orderVault() external view returns (address);
    function executeOrder(bytes32 key, SetPricesParams calldata oracleParams) external;
    function referralStorage() external view returns (address);
}
