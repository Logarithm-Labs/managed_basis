// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IStrategyConfig {
    function deutilizationThreshold() external view returns (uint256);
    function rebalanceDeviationThreshold() external view returns (uint256);
    function hedgeDeviationThreshold() external view returns (uint256);
    function responseDeviationThreshold() external view returns (uint256);
}
