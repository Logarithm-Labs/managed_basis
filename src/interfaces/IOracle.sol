// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function convertTokenAmount(address from, address to, uint256 amount) external view returns (uint256);
}
