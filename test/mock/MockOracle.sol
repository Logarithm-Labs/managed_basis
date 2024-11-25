// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

contract MockOracle {
    function convertTokenAmount(address, /*from*/ address, /*to*/ uint256 amount) external pure returns (uint256) {
        return amount;
    }
}
