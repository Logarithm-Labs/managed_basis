// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface IConfig {
    function getAddress(bytes32 key) external view returns (address);
    function getUint(bytes32 key) external view returns (uint256);
    function getInt(bytes32 key) external view returns (int256);
    function getBool(bytes32 key) external view returns (bool);
    function getString(bytes32 key) external view returns (string memory);
    function getBytes32(bytes32 key) external view returns (bytes32);
}
