// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IBasisStrategy {
    function depositLimits() external view returns (uint256 userDepositLimit, uint256 strategyDepostLimit);
    function totalAssets() external view returns (uint256);
    function idleAssets() external view returns (uint256);
    function totalPendingWithdraw() external view returns (uint256);
    function isClaimable(bytes32 withdrawRequestKey) external view returns (bool);

    // callable only by vault
    function processPendingWithdrawRequests() external;
    function createWithdrawRequest() external;
    function claim(bytes32 withdrawRequestKey) external;
}
