// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ISpotManager {
    enum SwapType {
        MANUAL,
        INCH_V6
    }

    /// @dev Emitted when product is bought in spot markets.
    event SpotBuy(uint256 assetDelta, uint256 productDelta);

    /// @dev Emitted when product is sold in spot markets.
    event SpotSell(uint256 assetDelta, uint256 productDelta);

    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external;
    function sell(uint256 amount, SwapType swapType, bytes calldata swapData) external;
    function exposure() external view returns (uint256);
    function asset() external view returns (address);
    function product() external view returns (address);
}
