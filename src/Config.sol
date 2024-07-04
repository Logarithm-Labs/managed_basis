// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Config is UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.Config
    struct ConfigStorage {
        // store for uint values
        mapping(bytes32 => uint256) uintValues;
        // store for int values
        mapping(bytes32 => int256) intValues;
        // store for address values
        mapping(bytes32 => address) addressValues;
        // store for bool values
        mapping(bytes32 => bool) boolValues;
        // store for string values
        mapping(bytes32 => string) stringValues;
        // store for bytes32 values
        mapping(bytes32 => bytes32) bytes32Values;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.Config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ConfigStorageLocation = 0xfcd6f43086eacdf7b8bf0e854ed3370386cf286ed3320d695c08edd340bfe200;

    function _getConfigStorage() private pure returns (ConfigStorage storage $) {
        assembly {
            $.slot := ConfigStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // @dev get the address value for the given key
    // @param key the key of the value
    // @return the address value for the key
    function getAddress(bytes32 key) external view returns (address) {
        return _getConfigStorage().addressValues[key];
    }

    // @dev set the address value for the given key
    // @param key the key of the value
    // @param value the value to set
    // @return the address value for the key
    function setAddress(bytes32 key, address value) external onlyOwner returns (address) {
        _getConfigStorage().addressValues[key] = value;
        return value;
    }

    // @dev get the uint value for the given key
    // @param key the key of the value
    // @return the uint value for the key
    function getUint(bytes32 key) external view returns (uint256) {
        return _getConfigStorage().uintValues[key];
    }

    // @dev set the uint value for the given key
    // @param key the key of the value
    // @param value the value to set
    // @return the uint value for the key
    function setUint(bytes32 key, uint256 value) external onlyOwner returns (uint256) {
        _getConfigStorage().uintValues[key] = value;
        return value;
    }

    // @dev get the int value for the given key
    // @param key the key of the value
    // @return the int value for the key
    function getInt(bytes32 key) external view returns (int256) {
        return _getConfigStorage().intValues[key];
    }

    // @dev set the int value for the given key
    // @param key the key of the value
    // @param value the value to set
    // @return the int value for the key
    function setInt(bytes32 key, int256 value) external onlyOwner returns (int256) {
        _getConfigStorage().intValues[key] = value;
        return value;
    }

    // @dev get the bool value for the given key
    // @param key the key of the value
    // @return the bool value for the key
    function getBool(bytes32 key) external view returns (bool) {
        return _getConfigStorage().boolValues[key];
    }

    // @dev set the bool value for the given key
    // @param key the key of the value
    // @param value the value to set
    // @return the bool value for the key
    function setBool(bytes32 key, bool value) external onlyOwner returns (bool) {
        _getConfigStorage().boolValues[key] = value;
        return value;
    }

    // @dev get the string value for the given key
    // @param key the key of the value
    // @return the string value for the key
    function getString(bytes32 key) external view returns (string memory) {
        return _getConfigStorage().stringValues[key];
    }

    // @dev set the string value for the given key
    // @param key the key of the value
    // @param value the value to set
    // @return the string value for the key
    function setString(bytes32 key, string memory value) external onlyOwner returns (string memory) {
        _getConfigStorage().stringValues[key] = value;
        return value;
    }

    // @dev get the bytes32 value for the given key
    // @param key the key of the value
    // @return the bytes32 value for the key
    function getBytes32(bytes32 key) external view returns (bytes32) {
        return _getConfigStorage().bytes32Values[key];
    }

    // @dev set the bytes32 value for the given key
    // @param key the key of the value
    // @param value the value to set
    // @return the bytes32 value for the key
    function setBytes32(bytes32 key, bytes32 value) external onlyOwner returns (bytes32) {
        _getConfigStorage().bytes32Values[key] = value;
        return value;
    }
}
