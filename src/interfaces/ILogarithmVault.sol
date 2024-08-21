// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ILogarithmVault is IERC4626 {
    function idleAssets() external view returns (uint256);
    function totalPendingWithdraw() external view returns (int256);
    function processPendingWithdrawRequests() external returns (uint256);
}
