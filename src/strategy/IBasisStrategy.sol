// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IStrategy} from "src/strategy/IStrategy.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";

interface IBasisStrategy is IStrategy {
    function assetsToWithdraw() external view returns (uint256);
    function afterAdjustPosition(IPositionManager.AdjustPositionPayload calldata responseParams) external;
    function oracle() external view returns (address);
    function vault() external view returns (address);
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
    function processAssetsToWithdraw() external;
}
