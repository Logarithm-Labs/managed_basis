// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IProductManager {
    function balance() external view returns (uint256);
    function utilize(uint256 amount) external returns (uint256);
    function deutilize(uint256 amount) external returns (uint256);
}
