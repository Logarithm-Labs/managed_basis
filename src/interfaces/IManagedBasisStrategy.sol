// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {DataTypes} from "src/libraries/utils/DataTypes.sol";

interface IManagedBasisStrategy {
    function setPositionManager(address positionManager) external;
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
    function targetLeverage() external view returns (uint256);

    // callback logic
    function afterAdjustPosition(DataTypes.PositionManagerPayload calldata responseParams) external;
}
