// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IStrategy} from "../strategy/IStrategy.sol";
import {IHedgeManager} from "../hedge/IHedgeManager.sol";

interface IBasisStrategy is IStrategy {
    function oracle() external view returns (address);
    function spotManager() external view returns (address);
    function hedgeManager() external view returns (address);
    function assetsToWithdraw() external view returns (uint256);
    function processAssetsToWithdraw() external;
    // callbacks
    function afterAdjustPosition(IHedgeManager.AdjustPositionPayload calldata responseParams) external;
    function spotBuyCallback(uint256 assetDelta, uint256 productDelta, uint256 timestamp) external;
    function spotSellCallback(uint256 assetDelta, uint256 productDelta, uint256 timestamp) external;
    function harvestPerformanceFee() external;
}
