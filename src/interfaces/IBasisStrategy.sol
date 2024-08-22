// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IPositionManager} from "src/interfaces/IPositionManager.sol";

interface IBasisStrategy {
    function utilizedAssets() external view returns (uint256);

    function afterAdjustPosition(IPositionManager.AdjustPositionPayload calldata responseParams) external;

    function vault() external view returns (address);
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
}
