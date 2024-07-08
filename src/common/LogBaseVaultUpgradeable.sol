// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract LogBaseVaultUpgradeable is Initializable, ERC20Upgradeable, IERC4626 {
    using Math for uint256;

    /// @custom:storage-location erc7201:logarithm.storage.BaseVault
    struct BaseVaultStorage {
        IERC20 _asset;
        IERC20 _product;
        uint8 _underlyingDecimals;
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
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        (bool success, uint8 assetDecimals) = _tryGetAssetDecimals(asset_);
        $._underlyingDecimals = success ? assetDecimals : 18;
        $._asset = asset_;
        $._product = product_;
    }

    /**
     * @dev Decimals are computed by adding the decimal offset on top of the underlying asset's decimals. This
     * "original" value is cached during construction of the vault contract. If this read operation fails (e.g., the
     * asset has not been created yet), a default of 18 is used to represent the underlying asset's decimals.
     *
     * See {IERC20Metadata-decimals}.
     */
    function decimals() public view virtual override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return $._underlyingDecimals + _decimalsOffset();
    }

    /**
     * @dev See {IERC4626-asset}.
     */
    function asset() public view virtual returns (address) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return address($._asset);
    }

    function product() public view virtual returns (address) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return address($._product);
    }

    /**
     * @dev See {IERC4626-totalAssets}.
     */
    function totalAssets() public view virtual returns (uint256) {
        BaseVaultStorage storage $ = _getBaseVaultStorage();
        return $._asset.balanceOf(address(this));
    }

    /**
     * @dev Attempts to fetch the asset decimals. A return value of false indicates that the attempt failed in some way.
     */
    function _tryGetAssetDecimals(IERC20 asset_) private view returns (bool, uint8) {
        (bool success, bytes memory encodedDecimals) =
            address(asset_).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
    }

    /**
     * @dev See {IERC4626-maxDeposit}.
     */
    function maxDeposit(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev See {IERC4626-maxMint}.
     */
    function maxMint(address) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @dev See {IERC4626-maxWithdraw}.
     */
    function maxWithdraw(address owner) public view virtual returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    /**
     * @dev See {IERC4626-maxRedeem}.
     */
    function maxRedeem(address owner) public view virtual returns (uint256) {
        return balanceOf(owner);
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 2;
    }
}
