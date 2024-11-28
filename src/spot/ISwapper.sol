// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ISwapper {
    function assetToProductSwapPath() external view returns (address[] memory);
    function productToAssetSwapPath() external view returns (address[] memory);
    function isSwapPool(address pool) external view returns (bool);
}
