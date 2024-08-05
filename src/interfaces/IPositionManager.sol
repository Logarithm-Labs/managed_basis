// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {DataTypes} from "src/libraries/utils/DataTypes.sol";

interface IPositionManager {
    function apiVersion() external view returns (string memory);

    function positionNetBalance() external view returns (uint256);

    function currentLeverage() external view returns (uint256);

    function positionSizeInTokens() external view returns (uint256);

    function keep() external;

    function needKeep() external view returns (bool);

    function adjustPosition(DataTypes.PositionManagerPayload memory requestParams) external;

    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    function increaseSizeMinMax() external view returns (uint256 min, uint256 max);

    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max);

    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max);
}
