// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

abstract contract ManagedVault is Initializable, ERC4626Upgradeable, OwnableUpgradeable {
    using Math for uint256;
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.ManagedVault
    struct ManagedVaultStorage {
        address feeRecipient;
        uint256 managementFee;
        uint256 lastAccruedTimestamp;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ManagedVaultStorageLocation =
        0x5838d87ad94106857c03412058a271bb1bc6cd6e65b028cb9d390a2ec4361000;

    function _getManagedVaultStorage() private pure returns (ManagedVaultStorage storage $) {
        assembly {
            $.slot := ManagedVaultStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZING
    //////////////////////////////////////////////////////////////*/

    function __ManagedVault_init(address owner_, address asset_, string calldata name_, string calldata symbol_)
        internal
        onlyInitializing
    {
        __Ownable_init(owner_);
        __ERC20_init_unchained(name_, symbol_);
        __ERC4626_init_unchained(IERC20(asset_));
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice set receiver of management fee
    ///
    /// @param recipient address of recipient
    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0));
        _getManagedVaultStorage().feeRecipient = recipient;
    }

    /// @notice set managementFee of management fee
    ///
    /// @param value 1 ether means 100%
    function setManagementFee(uint256 value) external onlyOwner {
        require(value < 1 ether);
        _getManagedVaultStorage().managementFee = value;
    }

    /*//////////////////////////////////////////////////////////////
                        LOGIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        address _feeRecipient = _getManagedVaultStorage().feeRecipient;

        if (_feeRecipient != address(0)) {
            if (from == _feeRecipient && to != address(0)) {
                revert Errors.ManagementFeeTransfer(_feeRecipient);
            }

            if ((from == address(0) && to != _feeRecipient) || (from != _feeRecipient && to == address(0))) {
                // called when minting to none of recipient
                // or when buring from none of recipient
                _accrueManagementFee(_feeRecipient);
            }
        }

        super._update(from, to, value);
    }

    /// @dev should not be called when minting to fee recipient
    function _accrueManagementFee(address _feeRecipient) internal {
        uint256 accuredShares = _claimableManagementFee(_feeRecipient);
        _getManagedVaultStorage().lastAccruedTimestamp = block.timestamp;
        if (accuredShares > 0) {
            _mint(_feeRecipient, accuredShares);
        }
    }

    /// @dev returns claimalbe shares for the management fee
    function _claimableManagementFee(address _feeRecipient) internal view returns (uint256) {
        if (_feeRecipient == address(0)) return 0;

        ManagedVaultStorage storage $ = _getManagedVaultStorage();
        uint256 _lastAccruedTimestamp = $.lastAccruedTimestamp;
        uint256 _managementFee = $.managementFee;

        if (_managementFee == 0 || _lastAccruedTimestamp == 0) return 0;

        uint256 duration = block.timestamp - _lastAccruedTimestamp;
        uint256 accruedFee = _managementFee.mulDiv(duration, 365 days);
        // should accrue fees regarding to other's shares except for feeRecipient
        uint256 shares = totalSupply() - balanceOf(_feeRecipient);
        uint256 sharesForManagementFee = shares.mulDiv(accruedFee, Constants.FLOAT_PRECISION);
        return sharesForManagementFee;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice mint management fee share by anyone
    function accrueManagementFee() external {
        _accrueManagementFee(_getManagedVaultStorage().feeRecipient);
    }

    /// @notice returns claimable shares of the management fee recipient
    function claimableManagementFee() external view returns (uint256) {
        return _claimableManagementFee(_getManagedVaultStorage().feeRecipient);
    }

    function feeRecipient() external view returns (address) {
        return _getManagedVaultStorage().feeRecipient;
    }

    function managementFee() external view returns (uint256) {
        return _getManagedVaultStorage().managementFee;
    }
}
