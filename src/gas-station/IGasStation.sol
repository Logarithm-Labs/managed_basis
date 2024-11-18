// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IGasStation {
    function payGmxExecutionFee(address exchangeRouter, address orderVault, uint256 executionFee) external;
    function withdraw(uint256 amount) external;
}
