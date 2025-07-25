// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ISpotManager {
    enum SwapType {
        MANUAL,
        INCH_V6
    }

    /// @dev Buys product in the spot market.
    ///
    /// @param amount The asset amount to be swapped to product.
    /// @param swapType The swap type.
    /// @param data The swap data for single chain, the hedge data for cross-chain.
    function buy(uint256 amount, SwapType swapType, bytes calldata data) external;

    /// @dev Sells product in the spot market.
    ///
    /// @param amount The product amount to be swapped to asset.
    /// @param swapType The swap type.
    /// @param data The swap data for single chain, the hedge data for cross-chain.
    function sell(uint256 amount, SwapType swapType, bytes calldata data) external;

    /// @notice The spot exposure that is needed to be hedged by the perpetual positions.
    function exposure() external view returns (uint256);

    /// @notice The asset amount holding in the spot manager.
    function getAssetValue() external view returns (uint256);

    /// @notice The asset address.
    function asset() external view returns (address);

    /// @notice The product address.
    function product() external view returns (address);

    /// @notice Whether the spot manager is for cross-chain.
    function isXChain() external view returns (bool);
}
