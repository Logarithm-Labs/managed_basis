// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IPositionManager} from "src/interfaces/IPositionManager.sol";

interface IBasisStrategy {
    function depositLimits() external view returns (uint256 userDepositLimit, uint256 strategyDepostLimit);
    function utilizedAssets() external view returns (uint256);

    function afterAdjustPosition(IPositionManager.PositionManagerPayload calldata responseParams) external;

    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
}
