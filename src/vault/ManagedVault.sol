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

/// @title A managed vault
/// @author Logarithm Labs
/// @notice Have functions to collect AUM fees
abstract contract ManagedVault is Initializable, ERC4626Upgradeable, OwnableUpgradeable {
    using Math for uint256;

    uint256 public constant MAX_MANAGEMENT_FEE = 5e16; // 5%
    uint256 public constant MAX_PERFORMANCE_FEE = 5e17; // 50%

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.ManagedVault
    struct ManagedVaultStorage {
        address feeRecipient;
        // management fee
        uint256 managementFee;
        // performance fee
        uint256 performanceFee;
        /// hurdle rate
        uint256 hurdleRate;
        // last timestamp for management fee
        uint256 lastAccruedTimestamp;
        // high water mark of share price
        // denominated in asset decimals
        uint256 sharePriceHwm;
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

    /// @notice fee configuration
    function setFeeInfos(address _feeRecipient, uint256 _managementFee, uint256 _performanceFee, uint256 _hurdleRate)
        external
        onlyOwner
    {
        require(_feeRecipient != address(0));
        require(_managementFee < MAX_MANAGEMENT_FEE);
        require(_performanceFee < MAX_PERFORMANCE_FEE);

        ManagedVaultStorage storage $ = _getManagedVaultStorage();
        $.feeRecipient = _feeRecipient;
        $.managementFee = _managementFee;
        $.performanceFee = _performanceFee;
        $.hurdleRate = _hurdleRate;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL LOGIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        address _feeRecipient = feeRecipient();

        if (_feeRecipient != address(0)) {
            if (from == _feeRecipient && to != address(0)) {
                revert Errors.ManagementFeeTransfer(_feeRecipient);
            }

            if (from != address(0) || to != _feeRecipient) {
                // called when minting to none of recipient
                // to stop infinite loop
                _accrueManagementFeeShares(_feeRecipient);
            }
        }

        super._update(from, to, value);
    }

    /// @dev should not be called when minting to fee recipient
    /// should be called only when feeRecipient is none-zero
    function _accrueManagementFeeShares(address _feeRecipient) internal {
        uint256 _managementFee = managementFee();
        uint256 _lastAccruedTimestamp = lastAccruedTimestamp();
        uint256 feeShares = _nextManagementFeeShares(_feeRecipient, _managementFee, _lastAccruedTimestamp);
        if (_managementFee == 0 || _lastAccruedTimestamp == 0) {
            // update lastAccruedTimestamp to accrue management fee only after fee is set
            // when it is set, initialize it when lastAccruedTimestamp is 0
            _getManagedVaultStorage().lastAccruedTimestamp = block.timestamp;
        } else if (feeShares > 0) {
            // only when feeShares is bigger than 0 when managementFee is set as none-zero,
            // update lastAccruedTimestamp to mitigate DOS of management fee accruing
            _mint(_feeRecipient, feeShares);
            _getManagedVaultStorage().lastAccruedTimestamp = block.timestamp;
        }
    }

    /// @dev should not be called when minting to fee recipient
    /// should be called only when feeRecipient is none-zero
    function _harvestPerformanceFeeShares(address _feeRecipient) internal {
        uint256 _performanceFee = performanceFee();
        uint256 _sharePriceHwm = sharePriceHwm();
        uint256 _sharePrice = sharePrice();
        uint256 feeShares = _nextPerformanceFeeShares(_feeRecipient, _performanceFee, _sharePriceHwm, _sharePrice);
        if ((_performanceFee == 0 || _sharePriceHwm == 0) && _sharePrice != 0) {
            // update high water mark when performanceFee is 0 to account fees right after setting fee vale as none- zero
            // initialize high water mark when it is 0 and performanceFee is set
            _getManagedVaultStorage().sharePriceHwm = _sharePrice;
        } else if (feeShares > 0) {
            _mint(_feeRecipient, feeShares);
            _getManagedVaultStorage().sharePriceHwm = _sharePrice;
        }
    }

    /// @notice calculate claimable shares for the management fee
    function _nextManagementFeeShares(address _feeRecipient, uint256 _managementFee, uint256 _lastAccruedTimestamp)
        internal
        view
        returns (uint256)
    {
        if (_feeRecipient == address(0) || _managementFee == 0 || _lastAccruedTimestamp == 0) return 0;
        uint256 duration = block.timestamp - _lastAccruedTimestamp;
        uint256 accruedFee = _managementFee.mulDiv(duration, 365 days);
        // should accrue fees regarding to other's shares except for feeRecipient
        uint256 shares = totalSupply() - balanceOf(_feeRecipient);
        // should be rounded to bottom to stop generating 1 shares by calling accrueManagementFeeShares function
        uint256 managementFeeShares = shares.mulDiv(accruedFee, Constants.FLOAT_PRECISION);
        return managementFeeShares;
    }

    /// @notice calculate the claimable performance fee shares
    function _nextPerformanceFeeShares(
        address _feeRecipient,
        uint256 _performanceFee,
        uint256 _sharePriceHwm,
        uint256 _sharePrice
    ) internal view returns (uint256) {
        if (_feeRecipient == address(0) || _performanceFee == 0 || _sharePriceHwm == 0 || _sharePrice <= _sharePriceHwm)
        {
            return 0;
        }

        uint256 profitRate = (_sharePrice - _sharePriceHwm).mulDiv(Constants.FLOAT_PRECISION, _sharePriceHwm);
        if (profitRate >= hurdleRate()) {
            // profit = totalAssets - hwm
            // profitRate = (totalAssets - hwm) / hwm
            // hwm = totalAssets / (profitRate + 1)
            // profit = hwm * profitRate = (totalAssets * profitRate) / (profitRate + 1)
            uint256 profit = totalAssets().mulDiv(profitRate, profitRate + Constants.FLOAT_PRECISION);
            uint256 performanceFeeAssets = profit.mulDiv(_performanceFee, Constants.FLOAT_PRECISION);
            uint256 performanceFeeShares = _convertToShares(performanceFeeAssets, Math.Rounding.Floor);
            return performanceFeeShares;
        } else {
            return 0;
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(totalSupplyWithNextFeeShares() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupplyWithNextFeeShares() + 10 ** _decimalsOffset(), rounding);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice mint management fee shares by anyone
    function accrueManagementFeeShares() public {
        _accrueManagementFeeShares(feeRecipient());
    }

    function totalSupplyWithNextFeeShares() public view returns (uint256) {
        return totalSupply() + nextManagementFeeShares();
    }

    function sharePrice() public view returns (uint256) {
        return _convertToAssets(10 ** decimals(), Math.Rounding.Floor);
    }

    /// @notice returns claimable shares of the management fee recipient
    function nextManagementFeeShares() public view returns (uint256) {
        return _nextManagementFeeShares(feeRecipient(), managementFee(), lastAccruedTimestamp());
    }

    function nextPerformanceFeeShares() public view returns (uint256) {
        return _nextPerformanceFeeShares(feeRecipient(), performanceFee(), sharePriceHwm(), sharePrice());
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function feeRecipient() public view returns (address) {
        return _getManagedVaultStorage().feeRecipient;
    }

    function managementFee() public view returns (uint256) {
        return _getManagedVaultStorage().managementFee;
    }

    function performanceFee() public view returns (uint256) {
        return _getManagedVaultStorage().performanceFee;
    }

    function hurdleRate() public view returns (uint256) {
        return _getManagedVaultStorage().hurdleRate;
    }

    function lastAccruedTimestamp() public view returns (uint256) {
        return _getManagedVaultStorage().lastAccruedTimestamp;
    }

    function sharePriceHwm() public view returns (uint256) {
        return _getManagedVaultStorage().sharePriceHwm;
    }
}
