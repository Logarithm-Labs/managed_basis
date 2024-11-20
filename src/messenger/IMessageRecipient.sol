// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IMessageRecipient {
    /// @dev Can be called only by LogarithmMessenger
    function receiveMessage(bytes32 _sender, bytes calldata _payload) external payable;
}
