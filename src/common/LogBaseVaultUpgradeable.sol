// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/libraries/utils/Constants.sol";

abstract contract LogBaseVaultUpgradeable is Initializable, ERC4626Upgradeable {
    using Math for uint256;

    /// @custom:storage-location erc7201:logarithm.storage.BaseVault
    struct BaseVaultStorage {
        IERC20 _product;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BaseVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BaseVaultStorageLocation =
        0x8e59cbd2ab6f86f6b051c869ece96d0f71c261860a068f87b2cb64885199d500;

    function _getBaseVaultStorage() private pure returns (BaseVaultStorage storage $) {
        assembly {
            $.slot := BaseVaultStorageLocation
        }
    }

    function __LogBaseVault_init(IERC20 asset_, IERC20 product_, string memory name_, string memory symbol_)
        internal
        onlyInitializing
    {
        __ERC20_init_unchained(name_, symbol_);
        __ERC4626_init_unchained(asset_);
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        $._product = product_;
    }

    function product() public view virtual returns (address) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return address($._product);
    }

    function _decimalsOffset() internal pure virtual override returns (uint8) {
        return Constants.DECIMAL_OFFSET;
    }
}
