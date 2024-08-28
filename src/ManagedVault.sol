// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        uint256 apy;
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

    /// @notice set APY of management fee
    ///
    /// @param value 1 ether means 100%
    function setApy(uint256 value) external onlyOwner {
        require(value < 1 ether);
        _getManagedVaultStorage().apy = value;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice accrue management fee in terms of shares
    ///
    /// @dev must be called before minting or buring shares of other users
    function accrueManagementFee() public {
        address _feeRecipient = _getManagedVaultStorage().feeRecipient;
        if (_feeRecipient == address(0)) return;
        uint256 _apy = _getManagedVaultStorage().apy;
        if (_apy == 0) return;
        uint256 lastAccruedTimestamp = _getManagedVaultStorage().lastAccruedTimestamp;
        _getManagedVaultStorage().lastAccruedTimestamp = block.timestamp;
        if (lastAccruedTimestamp == 0) return;
        uint256 duration = block.timestamp - lastAccruedTimestamp;
        uint256 accruedFee = _apy.mulDiv(duration, 365 days);
        uint256 accuredShares = totalSupply().mulDiv(accruedFee, Constants.FLOAT_PRECISION);
        _mint(_feeRecipient, accuredShares);
    }

    function feeRecipient() external view returns (address) {
        return _getManagedVaultStorage().feeRecipient;
    }

    function apy() external view returns (uint256) {
        return _getManagedVaultStorage().apy;
    }
}
