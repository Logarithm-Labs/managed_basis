// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract LogBaseVaultUpgradeable is Initializable, UUPSUpgradeable, ERC4626Upgradeable {

    error FactoryUnauthorizedAccount(address account);

    /// @custom:storage-location erc7201:logarithm.storage.BaseVault
    struct BaseVaultStorage {
        IERC20 _product;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BaseVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BaseVautlStorageLocation = 0x8e59cbd2ab6f86f6b051c869ece96d0f71c261860a068f87b2cb64885199d500;


    function _getBaseVaultStorage() private pure returns (BaseVaultStorage storage $) {
        assembly {
            $.slot := BaseVautlStorageLocation
        }
    }

    function __LogBaseVault_init(IERC20 product_) internal onlyInitializing {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        $._product = product_;
    }

    function product() public view virtual returns (address) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return address($._product);
    }

}