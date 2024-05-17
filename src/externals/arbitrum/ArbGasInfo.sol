// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ArbGasInfo {
    /// @notice Get the minimum gas price needed for a tx to succeed
    function getMinimumGasPrice() external view returns (uint256);
}
