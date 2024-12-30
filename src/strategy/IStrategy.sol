// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IStrategy {
    function processAssetsToWithdraw() external;
    function utilizedAssets() external view returns (uint256);
    function stop() external;
    function pause() external;
    function unpause() external;
}
