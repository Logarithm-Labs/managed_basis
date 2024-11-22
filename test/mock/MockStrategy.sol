// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";

contract MockStrategy {
    uint256 public sizeDeltaInTokens;
    uint256 public executionCost;
    uint256 public collateralDelta;
    address public oracle;

    uint256 public buyAssetDelta;
    uint256 public buyProductDelta;
    uint256 public sellAssetDelta;
    uint256 public sellProductDelta;

    constructor(address _oracle) {
        oracle = _oracle;
    }

    function asset() public pure returns (address) {
        return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // usdc
    }

    function product() public pure returns (address) {
        return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    }

    function targetLeverage() public pure returns (uint256) {
        return 3 ether;
    }

    function afterAdjustPosition(IHedgeManager.AdjustPositionPayload calldata params) external {
        sizeDeltaInTokens = params.sizeDeltaInTokens;
        collateralDelta = params.collateralDeltaAmount;
        if (params.collateralDeltaAmount > 0 && !params.isIncrease) {
            IERC20(asset()).transferFrom(msg.sender, address(this), collateralDelta);
        }
    }

    function spotBuyCallback(uint256 assetDelta, uint256 productDelta) external {
        buyAssetDelta = assetDelta;
        buyProductDelta = productDelta;
    }

    function spotSellCallback(uint256 assetDelta, uint256 productDelta) external {
        sellAssetDelta = assetDelta;
        sellProductDelta = productDelta;
    }
}
