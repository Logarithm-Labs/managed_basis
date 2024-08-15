// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IBasisVault} from "src/interfaces/IBasisVault.sol";

import {Constants} from "src/libraries/utils/Constants.sol";

/// @title A basis vault
/// @author Logarithm Labs
contract BasisVault is Initializable, ERC4626Upgradeable {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.BasisVault
    struct BasisVaultStorage {
        IERC20 product;
        IBasisStrategy strategy;
        uint256 entryCost;
        uint256 exitCost;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BasisVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BasisVaultStorageLocation =
        0x3176332e209c21f110843843692adc742ac2f78c16c19930ebc0f9f8747e5200;

    function _getBasisVaultStorage() private pure returns (BasisVaultStorage storage $) {
        assembly {
            $.slot := BasisVaultStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        string calldata name_,
        string calldata symbol_,
        address asset_,
        address product_,
        address strategy_,
        uint256 entryCost_,
        uint256 exitCost_
    ) external initializer {
        __ERC20_init_unchained(name_, symbol_);
        __ERC4626_init_unchained(IERC20(asset_));
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        $.product = IERC20(product_);

        require(strategy_ != address(0));
        $.strategy = IBasisStrategy(strategy_);
        IERC20(asset_).approve(strategy_, type(uint256).max);
        IERC20(product_).approve(strategy_, type(uint256).max);

        require(entryCost_ < 1 ether && exitCost_ < 1 ether);
        $.entryCost = entryCost_;
        $.exitCost = exitCost_;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxDeposit(address receiver) public view virtual override returns (uint256 allowed) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        (uint256 userDepositLimit, uint256 strategyDepositLimit) = $.strategy.depositLimits();
        if (userDepositLimit == type(uint256).max && strategyDepositLimit == type(uint256).max) {
            return type(uint256).max;
        } else {
            uint256 sharesBalance = balanceOf(receiver);
            uint256 sharesValue = convertToAssets(sharesBalance);
            uint256 availableDepositorLimit =
                userDepositLimit == type(uint256).max ? type(uint256).max : userDepositLimit - sharesValue;
            uint256 availableStrategyLimit =
                strategyDepositLimit == type(uint256).max ? type(uint256).max : strategyDepositLimit - totalAssets();
            uint256 userBalance = IERC20(asset()).balanceOf(address(receiver));
            allowed =
                availableDepositorLimit < availableStrategyLimit ? availableDepositorLimit : availableStrategyLimit;
            allowed = userBalance < allowed ? userBalance : allowed;
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return previewDeposit(maxAssets);
    }

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view virtual override returns (uint256 assets) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        return $.strategy.totalAssets();
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        if (totalSupply() == 0) {
            return assets;
        }
        // calculate the amount of assets that will be utilized
        (, uint256 assetsToUtilize) = assets.trySub($.strategy.totalPendingWithdraw());

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            uint256 feeAmount = assetsToUtilize.mulDiv($.entryCost, Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
            assets -= feeAmount;
        }

        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        if (totalSupply() == 0) {
            return shares;
        }
        uint256 assets = _convertToAssets(shares, Math.Rounding.Ceil);

        // calculate the amount of assets that will be utilized
        (, uint256 assetsToUtilize) = assets.trySub($.strategy.totalPendingWithdraw());

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            // feeAmount / (assetsToUtilize + feeAmount) = entryCost
            // feeAmount = (assetsToUtilize * entryCost) / (1 - entryCost)
            uint256 entryCost_ = $.entryCost;
            uint256 feeAmount =
                assetsToUtilize.mulDiv(entryCost_, Constants.FLOAT_PRECISION - entryCost_, Math.Rounding.Ceil);
            assets += feeAmount;
        }
        return assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        // calc the amount of assets that can not be withdrawn via idle
        (, uint256 assetsToDeutilize) = assets.trySub($.strategy.idleAssets());

        // apply exit fee to assets that should be deutilized and add exit fee amount the asset amount
        if (assetsToDeutilize > 0) {
            // feeAmount / assetsToDeutilize = exitCost
            uint256 feeAmount = assetsToDeutilize.mulDiv($.exitCost, Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
            assets += feeAmount;
        }

        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);

        // calculate the amount of assets that will be deutilized
        (, uint256 assetsToDeutilize) = assets.trySub($.strategy.idleAssets());

        // apply exit fee to the portion of assets that will be deutilized
        if (assetsToDeutilize > 0) {
            // feeAmount / (assetsToDeutilize - feeAmount) = exitCost
            // feeAmount = (assetsToDeutilize * exitCost) / (1 + exitCost)
            uint256 exitCost_ = $.exitCost;
            uint256 feeAmount =
                assetsToDeutilize.mulDiv(exitCost_, Constants.FLOAT_PRECISION + exitCost_, Math.Rounding.Ceil);
            assets -= feeAmount;
        }

        return assets;
    }

    /// @notice claim the processed withdraw request
    function claim(bytes32 withdrawRequestKey) external virtual {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        $.strategy.claim(withdrawRequestKey);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        BasisVaultStorage storage $ = _getBasisVaultStorage();

        IERC20 _asset = IERC20(asset());
        _asset.safeTransferFrom(caller, address(this), assets);

        _mint(receiver, shares);

        $.strategy.processPendingWithdrawRequests();

        emit Deposit(caller, receiver, assets, shares);
    }

    function isClaimable(bytes32 withdrawRequestKey) external returns (bool) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        return $.strategy.isClaimable(withdrawRequestKey);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        BasisVaultStorage storage $ = _getBasisVaultStorage();

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // If _asset is ERC777, `transfer` can trigger a reentrancy AFTER the transfer happens through the
        // `tokensReceived` hook. On the other hand, the `tokensToSend` hook, that is triggered before the transfer,
        // calls the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer after the burn so that any reentrancy would happen after the
        // shares are burned and after the assets are transferred, which is a valid state.
        _burn(owner, shares);

        $.strategy.requestWithdraw(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

    function product() external view returns (address) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        return address($.product);
    }

    function strategy() external view returns (address) {
        BasisVaultStorage storage $ = _getBasisVaultStorage();
        return address($.strategy);
    }

    function entryCost() external view returns (uint256) {
        return _getBasisVaultStorage().entryCost;
    }

    function exitCost() external view returns (uint256) {
        return _getBasisVaultStorage().exitCost;
    }
}
