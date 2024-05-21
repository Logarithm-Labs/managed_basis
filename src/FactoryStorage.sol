// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract FactoryStorage is Initializable {

    /// @custom:storage-location erc7201:logarithm.storage.BaseVault
    struct BaseVaultStorage {
        address _factory;
    }

    error FactoryUnauthorizedAccount(address caller, address factory);

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.FactoryStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FactoryStorageLocation = 0x1ab30f9eae9f8c9e6c0ac7525c9c13151bbafdb33097e1eb3e73ee486211a800;

    function _getFactoryStorage() private pure returns (BaseVaultStorage storage $) {
        assembly {
            $.slot := FactoryStorageLocation
        }
    }

    function __FactoryStorage_init(address factory_) internal onlyInitializing {
        BaseVaultStorage storage $ = _getFactoryStorage();
        $._factory = factory_;
    }

    function factory() public view virtual returns (address) {
        BaseVaultStorage storage $ = _getFactoryStorage();
        return $._factory;
    }

    modifier onlyFactory() {
        BaseVaultStorage storage $ = _getFactoryStorage();
        if (msg.sender != $._factory) {
            revert FactoryUnauthorizedAccount(msg.sender, $._factory);
        }
        _;
    }
    

}