// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IManagedBasisCallbackReceiver {
    function managedBasisCallback(bytes32 withdrawId, uint256 amountExecuted, bytes memory data) external;
}
