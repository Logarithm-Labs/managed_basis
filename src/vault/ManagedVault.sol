// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWhitelistProvider} from "src/whitelist/IWhitelistProvider.sol";

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
        // high water mark of totalAssets
        uint256 hwm;
        // last timestamp for performance fee
        uint256 lastHarvestedTimestamp;
        // address of the whitelist provider
        address whitelistProvider;
        // deposit limit in assets for each user
        uint256 userDepositLimit;
        // deposit limit in assets for this vault
        uint256 vaultDepositLimit;
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
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ManagementFeeCollected(address indexed feeRecipient, uint256 indexed feeShares);
    event PerformanceFeeCollected(address indexed feeRecipient, uint256 indexed feeShares);

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

        ManagedVaultStorage storage $ = _getManagedVaultStorage();
        $.userDepositLimit = type(uint256).max;
        $.vaultDepositLimit = type(uint256).max;
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
        require(_managementFee <= MAX_MANAGEMENT_FEE);
        require(_performanceFee <= MAX_PERFORMANCE_FEE);

        ManagedVaultStorage storage $ = _getManagedVaultStorage();
        $.feeRecipient = _feeRecipient;
        $.managementFee = _managementFee;
        $.performanceFee = _performanceFee;
        $.hurdleRate = _hurdleRate;
    }

    /// @notice set whitelist provider
    ///
    /// @param provider Address of the whitelist provider, 0 means not applying whitelist
    function setWhitelistProvider(address provider) external onlyOwner {
        _getManagedVaultStorage().whitelistProvider = provider;
    }

    /// @notice set deposit limits
    function setDepositLimits(uint256 userLimit, uint256 vaultLimit) external onlyOwner {
        ManagedVaultStorage storage $ = _getManagedVaultStorage();
        $.userDepositLimit = userLimit;
        $.vaultDepositLimit = vaultLimit;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC4626 LOGIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 _userDepositLimit = userDepositLimit();
        uint256 _vaultDepositLimit = vaultDepositLimit();

        if (_userDepositLimit == type(uint256).max && _vaultDepositLimit == type(uint256).max) {
            return type(uint256).max;
        } else {
            uint256 userShares = balanceOf(receiver);
            uint256 userAssets = convertToAssets(userShares);
            uint256 availableDepositorLimit = _userDepositLimit - userAssets;
            uint256 availableVaultLimit = _vaultDepositLimit - totalAssets();
            uint256 userBalance = IERC20(asset()).balanceOf(address(receiver));
            uint256 allowed =
                availableDepositorLimit < availableVaultLimit ? availableDepositorLimit : availableVaultLimit;
            allowed = userBalance < allowed ? userBalance : allowed;
            return allowed;
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return previewDeposit(maxAssets);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 _totalAssets = totalAssets();
        return assets.mulDiv(
            _totalSupplyWithNextFeeShares(_totalAssets) + 10 ** _decimalsOffset(), _totalAssets + 1, rounding
        );
    }

    /// @inheritdoc ERC4626Upgradeable
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 _totalAssets = totalAssets();
        return shares.mulDiv(
            _totalAssets + 1, _totalSupplyWithNextFeeShares(_totalAssets) + 10 ** _decimalsOffset(), rounding
        );
    }

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _harvestPerformanceFeeShares(assets, shares, true);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _harvestPerformanceFeeShares(assets, shares, false);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        address _feeRecipient = feeRecipient();
        address _whitelistProvider = whitelistProvider();

        if (
            to != address(0) && to != _feeRecipient && _whitelistProvider != address(0)
                && !IWhitelistProvider(_whitelistProvider).isWhitelisted(to)
        ) {
            revert Errors.NotWhitelisted(to);
        }

        if (_feeRecipient != address(0)) {
            if ((from == _feeRecipient && to != address(0)) || (from != address(0) && to == _feeRecipient)) {
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

    /*//////////////////////////////////////////////////////////////
                           FEE LOGIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev should be called before all deposits and withdrawals
    function _harvestPerformanceFeeShares(uint256 assets, uint256 shares, bool isDeposit) internal {
        address _feeRecipient = feeRecipient();
        uint256 _performanceFee = performanceFee();
        uint256 _hwm = highWaterMark();
        uint256 _totalAssets = totalAssets();
        uint256 totalSupplyWithManagementFeeShares = _totalSupplyWithManagementFeeShares(_feeRecipient);
        uint256 _lastHarvestedTimestamp = lastHarvestedTimestamp();
        uint256 feeShares = _nextPerformanceFeeShares(
            _performanceFee, _hwm, _totalAssets, totalSupplyWithManagementFeeShares, _lastHarvestedTimestamp
        );
        if (_performanceFee == 0 || _lastHarvestedTimestamp == 0) {
            // update lastHarvestedTimestamp to account for hurdleRate
            // only after performance fee is set
            _getManagedVaultStorage().lastHarvestedTimestamp = block.timestamp;
        } else if (feeShares > 0) {
            _mint(_feeRecipient, feeShares);
            _getManagedVaultStorage().lastHarvestedTimestamp = block.timestamp;
            _hwm = _totalAssets;
            emit PerformanceFeeCollected(_feeRecipient, feeShares);
        }
        _updateHighWaterMark(_hwm, totalSupplyWithManagementFeeShares, assets, shares, isDeposit);
    }

    /// @dev should not be called when minting to fee recipient
    function _accrueManagementFeeShares(address _feeRecipient) private {
        uint256 _managementFee = managementFee();
        uint256 _lastAccruedTimestamp = lastAccruedTimestamp();
        uint256 feeShares =
            _nextManagementFeeShares(_feeRecipient, _managementFee, totalSupply(), _lastAccruedTimestamp);
        if (_managementFee == 0 || _lastAccruedTimestamp == 0) {
            // update lastAccruedTimestamp to accrue management fee only after fee is set
            // when it is set, initialize it when lastAccruedTimestamp is 0
            _getManagedVaultStorage().lastAccruedTimestamp = block.timestamp;
        } else if (feeShares > 0) {
            // only when feeShares is bigger than 0 when managementFee is set as none-zero,
            // update lastAccruedTimestamp to mitigate DOS of management fee accruing
            _mint(_feeRecipient, feeShares);
            _getManagedVaultStorage().lastAccruedTimestamp = block.timestamp;
            emit ManagementFeeCollected(_feeRecipient, feeShares);
        }
    }

    /// @notice update high water mark
    function _updateHighWaterMark(
        uint256 oldHwm,
        uint256 oldTotalSupply,
        uint256 assets,
        uint256 shares,
        bool isDeposit
    ) private {
        uint256 newHwm;
        if (isDeposit) {
            newHwm = oldHwm + assets;
        } else {
            newHwm = oldHwm.mulDiv(oldTotalSupply - shares, oldTotalSupply);
        }
        _getManagedVaultStorage().hwm = newHwm;
    }

    /// @notice calculate claimable shares for the management fee
    function _nextManagementFeeShares(
        address _feeRecipient,
        uint256 _managementFee,
        uint256 _totalSupply,
        uint256 _lastAccruedTimestamp
    ) private view returns (uint256) {
        if (_managementFee == 0 || _lastAccruedTimestamp == 0) return 0;
        uint256 accruedFee = _calcFeeFraction(_managementFee, block.timestamp - _lastAccruedTimestamp);
        // should accrue fees regarding to other's shares except for feeRecipient
        uint256 shares = _totalSupply - balanceOf(_feeRecipient);
        // should be rounded to bottom to stop generating 1 shares by calling accrueManagementFeeShares function
        uint256 managementFeeShares = shares.mulDiv(accruedFee, Constants.FLOAT_PRECISION);
        return managementFeeShares;
    }

    /// @notice calculate the claimable performance fee shares
    function _nextPerformanceFeeShares(
        uint256 _performanceFee,
        uint256 _hwm,
        uint256 _totalAssets,
        uint256 _totalSupply,
        uint256 _lastHarvestedTimestamp
    ) private view returns (uint256) {
        if (_performanceFee == 0 || _hwm == 0 || _lastHarvestedTimestamp == 0 || _totalAssets <= _hwm) {
            return 0;
        }
        uint256 profit = _totalAssets - _hwm;
        uint256 profitRate = profit.mulDiv(Constants.FLOAT_PRECISION, _hwm);
        uint256 hurdleRateFraction = _calcFeeFraction(hurdleRate(), block.timestamp - _lastHarvestedTimestamp);
        if (profitRate > hurdleRateFraction) {
            uint256 feeAssets = profit.mulDiv(_performanceFee, Constants.FLOAT_PRECISION);
            uint256 feeShares = feeAssets.mulDiv(
                _totalSupply + 10 ** _decimalsOffset(), _totalAssets + 1 - feeAssets, Math.Rounding.Ceil
            );
            return feeShares;
        } else {
            return 0;
        }
    }

    function _totalSupplyWithManagementFeeShares(address _feeRecipient) private view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        return _totalSupply
            + _nextManagementFeeShares(_feeRecipient, managementFee(), _totalSupply, lastAccruedTimestamp());
    }

    /// @notice totalSupply with management and performance fee shares
    function _totalSupplyWithNextFeeShares(uint256 _totalAssets) private view returns (uint256) {
        address _feeRecipient = feeRecipient();
        uint256 totalSupplyWithManagementFeeShares = _totalSupplyWithManagementFeeShares(_feeRecipient);
        return totalSupplyWithManagementFeeShares
            + _nextPerformanceFeeShares(
                performanceFee(),
                highWaterMark(),
                _totalAssets,
                totalSupplyWithManagementFeeShares,
                lastHarvestedTimestamp()
            );
    }

    function _calcFeeFraction(uint256 annualFee, uint256 duration) private pure returns (uint256) {
        return annualFee.mulDiv(duration, 365 days);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice mint management fee shares by anyone
    function accrueManagementFeeShares() public {
        _accrueManagementFeeShares(feeRecipient());
    }

    /*//////////////////////////////////////////////////////////////
                         PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice returns claimable shares of the management fee recipient
    function nextManagementFeeShares() public view returns (uint256) {
        return _nextManagementFeeShares(feeRecipient(), managementFee(), totalSupply(), lastAccruedTimestamp());
    }

    /// @notice returns claimable shares of the performance fee recipient
    function nextPerformanceFeeShares() public view returns (uint256) {
        return _nextPerformanceFeeShares(
            performanceFee(),
            highWaterMark(),
            totalAssets(),
            _totalSupplyWithManagementFeeShares(feeRecipient()),
            lastHarvestedTimestamp()
        );
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

    function highWaterMark() public view returns (uint256) {
        return _getManagedVaultStorage().hwm;
    }

    function lastHarvestedTimestamp() public view returns (uint256) {
        return _getManagedVaultStorage().lastHarvestedTimestamp;
    }

    function whitelistProvider() public view returns (address) {
        return _getManagedVaultStorage().whitelistProvider;
    }

    function userDepositLimit() public view returns (uint256) {
        return _getManagedVaultStorage().userDepositLimit;
    }

    function vaultDepositLimit() public view returns (uint256) {
        return _getManagedVaultStorage().vaultDepositLimit;
    }
}
