// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ISpotManager {
    enum SwapType {
        MANUAL,
        INCH_V6
    }

    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external;
    function sell(uint256 amount, SwapType swapType, bytes calldata swapData) external;
    function exposure() external view returns (uint256);
    function asset() external view returns (address);
    function product() external view returns (address);
}
