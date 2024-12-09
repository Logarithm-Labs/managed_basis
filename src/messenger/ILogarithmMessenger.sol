// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

struct SendParams {
    uint256 dstChainId;
    bytes32 receiver;
    address token;
    uint128 gasLimit;
    uint256 amount;
    bytes data;
}

interface ILogarithmMessenger {
    /// @dev Assets should be sent before calling this function.
    function send(SendParams calldata params) external payable;
}
