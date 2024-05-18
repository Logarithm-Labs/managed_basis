// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IBasisStrategy {
    function initialize(address asset, address product, string memory name, string memory symbol) external;
    function setPositionManager(address positionManager) external;
    function activateStrategy() external;
    function deactivateStrategy() external payable returns (bytes32);
    function asset() external view returns (address);
    function product() external view returns (address);
    function positionManager() external view returns (address);
    function isActive() external view returns (bool);
}
