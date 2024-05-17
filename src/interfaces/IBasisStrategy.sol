// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IBasisStrategy {
    function asset() external view returns (address);
    function product() external view returns (address);
}
