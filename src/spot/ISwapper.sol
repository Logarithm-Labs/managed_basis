// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ISwapper {
    /// @notice The manual swap path for buy
    function assetToProductSwapPath() external view returns (address[] memory);

    /// @notice The manual swap path for sell
    function productToAssetSwapPath() external view returns (address[] memory);

    /// @notice True if `pool` is registered liquidity pool in manual swap path
    function isSwapPool(address pool) external view returns (bool);
}
