// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IDataStore {
    function getAddressCount(bytes32 setKey) external view returns (uint256);
    function getBool(bytes32 key) external view returns (bool);
    function getUint(bytes32 key) external view returns (uint256);
    function getInt(bytes32 key) external view returns (int256);
    function getAddress(bytes32 key) external view returns (address);
    function getBytes32(bytes32 key) external view returns (bytes32);
    function containsBytes32(bytes32 setKey, bytes32 value) external view returns (bool);
    function containsAddress(bytes32 setKey, address value) external view returns (bool);
    function addAddress(bytes32 setKey, address value) external;
    function getAddressValuesAt(bytes32 setKey, uint256 start, uint256 end) external view returns (address[] memory);
}
