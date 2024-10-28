// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IPriorityProvider} from "src/vault/IPriorityProvider.sol";
import {ManagedVault} from "src/vault/ManagedVault.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title A logarithm vault
/// @author Logarithm Labs
contract LogarithmVault is Initializable, PausableUpgradeable, ManagedVault {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct WithdrawRequest {
        uint256 requestedAssets;
        uint256 accRequestedWithdrawAssets;
        uint256 requestTimestamp;
        address owner;
        address receiver;
        bool isClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.LogarithmVault
    struct LogarithmVaultStorage {
        IBasisStrategy strategy;
        uint256 entryCost;
        uint256 exitCost;
        // withdraw state
        uint256 assetsToClaim; // asset balance of vault that is ready to claim
        uint256 accRequestedWithdrawAssets; // total requested withdraw assets
        uint256 processedWithdrawAssets; // total processed assets
        mapping(address => uint256) nonces;
        mapping(bytes32 => WithdrawRequest) withdrawRequests;
        // prioritized withdraw state
        address priorityProvider;
        uint256 prioritizedAccRequestedWithdrawAssets;
        uint256 prioritizedProcessedWithdrawAssets;
        address securityManager;
        bool shutdown;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.LogarithmVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LogarithmVaultStorageLocation =
        0xa6bd21c53796194571f225e7dc34d762d966d8495887cd7c53f8cab2693cb800;

    function _getLogarithmVaultStorage() private pure returns (LogarithmVaultStorage storage $) {
        assembly {
            $.slot := LogarithmVaultStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequested(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 withdrawKey, uint256 assets
    );

    event Claimed(address indexed claimer, bytes32 withdrawKey, uint256 assets);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySecurityManager() {
        if (_msgSender() != securityManager()) {
            revert Errors.InvalidSecurityManager();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address owner_,
        address asset_,
        address priorityProvider_,
        uint256 entryCost_,
        uint256 exitCost_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        __ManagedVault_init(owner_, asset_, name_, symbol_);
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

        require(entryCost_ < 1 ether && exitCost_ < 1 ether);
        $.entryCost = entryCost_;
        $.exitCost = exitCost_;

        $.priorityProvider = priorityProvider_;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

    function setSecurityManager(address account) external onlyOwner {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        $.securityManager = account;
    }

    function setStrategy(address _strategy) external onlyOwner {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

        IERC20 _asset = IERC20(asset());

        address prevStrategy = address($.strategy);
        if (prevStrategy != address(0)) _asset.approve(prevStrategy, 0);

        require(_strategy != address(0));
        $.strategy = IBasisStrategy(_strategy);
        _asset.approve(_strategy, type(uint256).max);
    }

    function setEntryCost(uint256 _entryCost) external onlyOwner {
        require(_entryCost < 1 ether);
        _getLogarithmVaultStorage().entryCost = _entryCost;
    }

    function setExitCost(uint256 _exitCost) external onlyOwner {
        require(_exitCost < 1 ether);
        _getLogarithmVaultStorage().exitCost = _exitCost;
    }

    function setPriorityProvider(address _priorityProvider) external onlyOwner {
        _getLogarithmVaultStorage().priorityProvider = _priorityProvider;
    }

    function shutdown() external onlyOwner {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        $.strategy.stop();
        $.shutdown = true;
    }

    function pause(bool stopStrategy) external onlySecurityManager whenNotPaused {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        if (stopStrategy) {
            $.strategy.stop();
        } else {
            $.strategy.pause();
        }
        _pause();
    }

    function unpause() external onlySecurityManager whenPaused {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        $.strategy.unpause();
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view virtual override returns (uint256 assets) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        int256 _totalAssets = (idleAssets() + $.strategy.utilizedAssets()).toInt256() - totalPendingWithdraw();
        if (_totalAssets > 0) {
            return uint256(_totalAssets);
        } else {
            return 0;
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        if (totalSupply() == 0) {
            return assets;
        }
        // calculate the amount of assets that will be utilized
        int256 _totalPendingWithdraw = totalPendingWithdraw();
        uint256 assetsToUtilize;
        if (_totalPendingWithdraw > 0) {
            (, assetsToUtilize) = assets.trySub(uint256(_totalPendingWithdraw));
        } else {
            assetsToUtilize = assets;
        }

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            assets -= _costOnTotal(assetsToUtilize, $.entryCost);
        }

        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        if (totalSupply() == 0) {
            return shares;
        }
        uint256 assets = _convertToAssets(shares, Math.Rounding.Ceil);

        // calculate the amount of assets that will be utilized
        int256 _totalPendingWithdraw = totalPendingWithdraw();
        uint256 assetsToUtilize;
        if (_totalPendingWithdraw > 0) {
            (, assetsToUtilize) = assets.trySub(uint256(_totalPendingWithdraw));
        } else {
            assetsToUtilize = assets;
        }

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            assets += _costOnRaw(assetsToUtilize, $.entryCost);
        }
        return assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        // calc the amount of assets that can not be withdrawn via idle
        (, uint256 assetsToDeutilize) = assets.trySub(idleAssets());

        // apply exit fee to assets that should be deutilized and add exit fee amount the asset amount
        if (assetsToDeutilize > 0) {
            assets += _costOnRaw(assetsToDeutilize, $.exitCost);
        }

        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);

        // calculate the amount of assets that will be deutilized
        (, uint256 assetsToDeutilize) = assets.trySub(idleAssets());

        // apply exit fee to the portion of assets that will be deutilized
        if (assetsToDeutilize > 0) {
            assets -= _costOnTotal(assetsToDeutilize, $.exitCost);
        }

        return assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        _requireNotPaused();
        if (isShutdown()) {
            revert Errors.VaultShutdown();
        }

        IERC20 _asset = IERC20(asset());
        _asset.safeTransferFrom(caller, address(this), assets);

        _mint(receiver, shares);

        processPendingWithdrawRequests();

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _requireNotPaused();
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

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

        uint256 _idleAssets = idleAssets();
        if (_idleAssets >= assets) {
            IERC20(asset()).safeTransfer(receiver, assets);
        } else {
            // lock idle assets to claim
            $.assetsToClaim += _idleAssets;

            // request withdraw the remaining assets for strategy to deutilize
            uint256 withdrawAssets = assets - _idleAssets;

            uint256 _accRequestedWithdrawAssets;
            if (isPrioritized(owner)) {
                _accRequestedWithdrawAssets = $.prioritizedAccRequestedWithdrawAssets + withdrawAssets;
                $.prioritizedAccRequestedWithdrawAssets = _accRequestedWithdrawAssets;
            } else {
                _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets + withdrawAssets;
                $.accRequestedWithdrawAssets = _accRequestedWithdrawAssets;
            }

            bytes32 withdrawKey = getWithdrawKey(owner, _useNonce(owner));
            $.withdrawRequests[withdrawKey] = WithdrawRequest({
                requestedAssets: assets,
                accRequestedWithdrawAssets: _accRequestedWithdrawAssets,
                requestTimestamp: block.timestamp,
                owner: owner,
                receiver: receiver,
                isClaimed: false
            });
            emit WithdrawRequested(caller, receiver, owner, withdrawKey, assets);
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice process pending withdraw request with idle assets
    /// Note: anyone can call this function
    ///
    /// @return processed assets
    function processPendingWithdrawRequests() public returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

        (uint256 remainingAssets, uint256 processedAssetsForPrioritized) = _calcProcessedAssets(
            idleAssets(), $.prioritizedProcessedWithdrawAssets, $.prioritizedAccRequestedWithdrawAssets
        );
        if (processedAssetsForPrioritized > 0) {
            $.prioritizedProcessedWithdrawAssets += processedAssetsForPrioritized;
        }

        (, uint256 processedAssets) =
            _calcProcessedAssets(remainingAssets, $.processedWithdrawAssets, $.accRequestedWithdrawAssets);

        if (processedAssets > 0) $.processedWithdrawAssets += processedAssets;

        uint256 totalProcessedAssets = processedAssetsForPrioritized + processedAssets;

        if (totalProcessedAssets > 0) {
            $.assetsToClaim += totalProcessedAssets;
        }

        return totalProcessedAssets;
    }

    /// @notice claim the processed withdraw request
    function claim(bytes32 withdrawRequestKey) external virtual returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        WithdrawRequest memory withdrawRequest = $.withdrawRequests[withdrawRequestKey];

        if (withdrawRequest.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        bool isPrioritizedAccount = isPrioritized(withdrawRequest.owner);
        (bool isExecuted, bool isLast) =
            _isWithdrawRequestExecuted(isPrioritizedAccount, withdrawRequest.accRequestedWithdrawAssets);

        if (!isExecuted) {
            revert Errors.RequestNotExecuted();
        }

        withdrawRequest.isClaimed = true;

        $.withdrawRequests[withdrawRequestKey] = withdrawRequest;

        uint256 executedAssets;
        // separate workflow for last redeem
        if (isLast) {
            uint256 _processedWithdrawAssets;
            uint256 _accRequestedWithdrawAssets;
            if (isPrioritizedAccount) {
                _processedWithdrawAssets = $.prioritizedProcessedWithdrawAssets;
                _accRequestedWithdrawAssets = $.prioritizedAccRequestedWithdrawAssets;
            } else {
                _processedWithdrawAssets = $.processedWithdrawAssets;
                _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;
            }
            uint256 shortfall = _accRequestedWithdrawAssets - _processedWithdrawAssets;

            if (shortfall > 0) {
                (, executedAssets) = withdrawRequest.requestedAssets.trySub(shortfall);
                isPrioritizedAccount
                    ? $.prioritizedProcessedWithdrawAssets = _accRequestedWithdrawAssets
                    : $.processedWithdrawAssets = _accRequestedWithdrawAssets;
            } else {
                uint256 _idleAssets = idleAssets();
                executedAssets = withdrawRequest.requestedAssets + _idleAssets;
                $.assetsToClaim += _idleAssets;
            }
        } else {
            executedAssets = withdrawRequest.requestedAssets;
        }

        $.assetsToClaim -= executedAssets;

        IERC20(asset()).safeTransfer(withdrawRequest.receiver, executedAssets);

        emit Claimed(withdrawRequest.receiver, withdrawRequestKey, executedAssets);
        return executedAssets;
    }

    function isClaimable(bytes32 withdrawRequestKey) external view returns (bool) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        WithdrawRequest memory withdrawRequest = $.withdrawRequests[withdrawRequestKey];
        (bool isExecuted,) =
            _isWithdrawRequestExecuted(isPrioritized(withdrawRequest.owner), withdrawRequest.accRequestedWithdrawAssets);

        return isExecuted && !withdrawRequest.isClaimed;
    }

    /// @notice determines if the withdrawal request is prioritized
    function isPrioritized(address owner) public view returns (bool) {
        address _priorityProvider = _getLogarithmVaultStorage().priorityProvider;
        if (_priorityProvider == address(0)) {
            return false;
        }
        return IPriorityProvider(_priorityProvider).isPrioritized(owner);
    }

    /// @notice returns idle assets that can be claimed or utilized
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - _getLogarithmVaultStorage().assetsToClaim;
    }

    /// @notice returns pending withdraw assets that will be deutilized
    function totalPendingWithdraw() public view returns (int256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        return ($.prioritizedAccRequestedWithdrawAssets + $.accRequestedWithdrawAssets).toInt256()
            - ($.prioritizedProcessedWithdrawAssets + $.processedWithdrawAssets + $.strategy.assetsToWithdraw()).toInt256();
    }

    function getWithdrawKey(address user, uint256 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), user, nonce));
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev calculate the processed withdrawal assets
    ///
    /// @param _idleAssets idle assets available for proc
    /// @param _processedWithdrawAssets is the value of processedWithdrawAssets state
    /// @param _accRequestedWithdrawAssets is the value of accRequestedWithdrawAssets state
    ///
    /// @return remainingAssets is the remaining asset amount after processing
    /// @return processedAssets is the processed amount of asset
    function _calcProcessedAssets(
        uint256 _idleAssets,
        uint256 _processedWithdrawAssets,
        uint256 _accRequestedWithdrawAssets
    ) internal pure returns (uint256 remainingAssets, uint256 processedAssets) {
        // check if there is neccessarity to process withdraw requests
        if (_processedWithdrawAssets < _accRequestedWithdrawAssets) {
            uint256 assetsToBeProcessed = _accRequestedWithdrawAssets - _processedWithdrawAssets;
            if (assetsToBeProcessed > _idleAssets) {
                processedAssets = _idleAssets;
            } else {
                processedAssets = assetsToBeProcessed;
                remainingAssets = _idleAssets - processedAssets;
            }
        } else {
            remainingAssets = _idleAssets;
        }
        return (remainingAssets, processedAssets);
    }

    /// @dev return executable state of withdraw request
    ///
    /// @param isPrioritizedAccount tells if account is prioritized for withdrawal
    /// @param accRequestedWithdrawAssetsOfRequest accRequestedWithdrawAssets value of withdraw request
    ///
    /// @return isExecuted tells whether a request is executed or not
    /// @return isLast tells whether a request is last or not
    function _isWithdrawRequestExecuted(bool isPrioritizedAccount, uint256 accRequestedWithdrawAssetsOfRequest)
        internal
        view
        returns (bool isExecuted, bool isLast)
    {
        // return false if withdraw request was not issued (accRequestedWithdrawAssetsOfRequest is zero)
        if (accRequestedWithdrawAssetsOfRequest == 0) {
            return (false, false);
        }
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

        // separate workflow for last withdraw
        // check if current withdrawRequest is last withdraw
        // possible only when totalSupply is 0
        if (totalSupply() == 0) {
            isLast = isPrioritizedAccount
                ? accRequestedWithdrawAssetsOfRequest == $.prioritizedAccRequestedWithdrawAssets
                : accRequestedWithdrawAssetsOfRequest == $.accRequestedWithdrawAssets;
        }

        if (isLast) {
            // last withdraw is claimable when utilized assets is 0
            // and assetsToWithdraw is 0
            IBasisStrategy _strategy = $.strategy;
            isExecuted = _strategy.utilizedAssets() == 0 && _strategy.assetsToWithdraw() == 0;
        } else {
            isExecuted = isPrioritizedAccount
                ? accRequestedWithdrawAssetsOfRequest <= $.prioritizedProcessedWithdrawAssets
                : accRequestedWithdrawAssetsOfRequest <= $.processedWithdrawAssets;
        }

        return (isExecuted, isLast);
    }

    /// @dev use nonce for each user and increase it
    function _useNonce(address user) internal returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        // For each vault, the nonce has an initial value of 0, can only be incremented by one, and cannot be
        // decremented or reset. This guarantees that the nonce never overflows.
        unchecked {
            // It is important to do x++ and not ++x here.
            return $.nonces[user]++;
        }
    }

    /// @dev calculates the cost that should be added to an amount `assets` that does not include cost.
    /// used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function _costOnRaw(uint256 assets, uint256 costRate) private pure returns (uint256) {
        return assets.mulDiv(costRate, Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
    }

    /// @dev calculates the cost part of an amount `assets` that already includes cost.
    /// used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function _costOnTotal(uint256 assets, uint256 costRate) private pure returns (uint256) {
        return assets.mulDiv(costRate, costRate + Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

    function strategy() external view returns (address) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        return address($.strategy);
    }

    function priorityProvider() external view returns (address) {
        return _getLogarithmVaultStorage().priorityProvider;
    }

    function entryCost() external view returns (uint256) {
        return _getLogarithmVaultStorage().entryCost;
    }

    function exitCost() external view returns (uint256) {
        return _getLogarithmVaultStorage().exitCost;
    }

    function assetsToClaim() external view returns (uint256) {
        return _getLogarithmVaultStorage().assetsToClaim;
    }

    function accRequestedWithdrawAssets() external view returns (uint256) {
        return _getLogarithmVaultStorage().accRequestedWithdrawAssets;
    }

    function processedWithdrawAssets() external view returns (uint256) {
        return _getLogarithmVaultStorage().processedWithdrawAssets;
    }

    function prioritizedAccRequestedWithdrawAssets() external view returns (uint256) {
        return _getLogarithmVaultStorage().prioritizedAccRequestedWithdrawAssets;
    }

    function prioritizedProcessedWithdrawAssets() external view returns (uint256) {
        return _getLogarithmVaultStorage().prioritizedProcessedWithdrawAssets;
    }

    function withdrawRequests(bytes32 withdrawKey) external view returns (WithdrawRequest memory) {
        return _getLogarithmVaultStorage().withdrawRequests[withdrawKey];
    }

    function nonces(address user) external view returns (uint256) {
        return _getLogarithmVaultStorage().nonces[user];
    }

    function securityManager() public view returns (address) {
        return _getLogarithmVaultStorage().securityManager;
    }

    /// @notice if set to true, only withdrawals will be available. It can't be reverted.
    function isShutdown() public view returns (bool) {
        return _getLogarithmVaultStorage().shutdown;
    }
}
