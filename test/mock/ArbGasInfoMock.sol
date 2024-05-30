// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

contract ArbGasInfoMock {
    function getMinimumGasPrice() external view returns (uint256) {
        return tx.gasprice;
    }
}
