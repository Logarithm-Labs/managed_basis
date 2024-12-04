// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IMessageRecipient {
    /// @dev Can be called only by LogarithmMessenger
    function receiveMessage(bytes32 sender, bytes calldata data) external;
    /// @dev Can be called only by LogarithmMessenger
    function receiveToken(bytes32 sender, address token, uint256 amount, bytes calldata data) external;
}
