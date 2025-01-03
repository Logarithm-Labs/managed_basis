// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title WhitelistProvider
/// @author Logarithm Labs
/// @notice Store whitelisted users who are allowed for basis vaults
contract WhitelistProvider is UUPSUpgradeable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.WhitelistProvider
    struct WhitelistProviderStorage {
        EnumerableSet.AddressSet whitelistSet;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.WhitelistProvider")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant WhitelistProviderStorageLocation =
        0xeb8ff60d146ce7fa958a118578ef28883928c44fc7c24bb6e5d90448571b7b00;

    function _getWhitelistProviderStorage() private pure returns (WhitelistProviderStorage storage $) {
        assembly {
            $.slot := WhitelistProviderStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event UserAdded(address indexed user);
    event UserRemoved(address indexed user);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error WP__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier nonZeroAddress(address user) {
        if (user == address(0)) {
            revert WP__ZeroAddress();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner function to whitelist a user
    function whitelist(address user) public onlyOwner nonZeroAddress(user) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        $.whitelistSet.add(user);
        emit UserAdded(user);
    }

    /// @notice Owner function to remove a user from whitelists
    function removeWhitelist(address user) public onlyOwner nonZeroAddress(user) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        $.whitelistSet.remove(user);
        emit UserRemoved(user);
    }

    /*//////////////////////////////////////////////////////////////
                             PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address array of whitelisted users
    function whitelistedUsers() public view returns (address[] memory) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        return $.whitelistSet.values();
    }

    /// @notice True if an inputted user is whitelisted
    function isWhitelisted(address user) public view returns (bool) {
        WhitelistProviderStorage storage $ = _getWhitelistProviderStorage();
        return $.whitelistSet.contains(user);
    }
}
