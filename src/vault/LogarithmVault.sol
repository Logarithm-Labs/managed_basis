// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IStrategy} from "src/strategy/IStrategy.sol";
import {IPriorityProvider} from "src/vault/IPriorityProvider.sol";
import {ManagedVault} from "src/vault/ManagedVault.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title LogarithmVault
///
/// @author Logarithm Labs
///
/// @notice The Logarithm Vault supplies depositor funds to a single connected strategy,
/// with depositors receiving shares proportional to their contributions and paying entry
/// fees to cover the strategy’s execution costs. Vault tokens are yield-bearing and can
/// be redeemed at any time, enabling depositors to withdraw their initial investment
/// plus any generated yield, while incurring exit fees to cover strategy-related costs.
/// When idle assets are available in the vault, redemptions may proceed synchronously;
/// otherwise, they occur asynchronously as funds are withdrawn from the strategy,
/// involving interactions with asynchronous protocols like GMX and cross-chain systems
/// such as HyperLiquid.
///
/// @dev The withdrawable assets and redeemable shares are determined by the `maxRequestWithdraw`
/// and `maxRequestRedeem` functions and are executed via `requestWithdraw` and `requestRedeem`.
/// These functions return a unique withdrawal key that can be used to check the status and
/// claimability of the withdraw request.
/// Standard ERC4626-compliant functions — `maxWithdraw`, `maxRedeem`, `withdraw`, and `redeem` —
/// remain available but operate exclusively with idle assets within the vault.
/// The Logarithm Vault is an ERC4626-compliant, upgradeable vault with asynchronous
/// redemption functionality, implemented through a beacon proxy pattern.
contract LogarithmVault is Initializable, PausableUpgradeable, ManagedVault {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice A struct describing an user's withdraw request.
    struct WithdrawRequest {
        /// @dev The requested assets to withdraw.
        uint256 requestedAssets;
        /// @dev The accumulated withdraw assets value that is used for claimability.
        uint256 accRequestedWithdrawAssets;
        /// @dev The block.timestamp when the request was created.
        uint256 requestTimestamp;
        /// @dev The owner who requested to withdraw.
        address owner;
        /// @dev The account who is receiving the executed withdrawal assets.
        address receiver;
        /// @dev True means claimed.
        bool isClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.LogarithmVault
    struct LogarithmVaultStorage {
        address strategy;
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

    /// @dev Emitted when a new withdraw/redeem request is created.
    ///
    /// @param caller The address of withdraw requestor.
    /// @param receiver The address who receives the withdraw assets.
    /// @param owner The address of owner who was requested to withdraw.
    /// @param withdrawKey The bytes32 value that identifies the withdraw request.
    /// @param assets The asset amount that is requested to withdraw.
    /// @param shares The share amount that is burnt.
    event WithdrawRequested(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        bytes32 withdrawKey,
        uint256 assets,
        uint256 shares
    );

    /// @dev Emitted when a withdraw request gets claimed.
    ///
    /// @param claimer The address who claimed the withdraw request.
    /// @param withdrawKey The bytes32 withdraw key identifying a withdraw request.
    /// @param assets The asset amount that is claimed.
    event Claimed(address indexed claimer, bytes32 withdrawKey, uint256 assets);

    /// @dev Emitted when this vault get shutdown.
    ///
    /// @param account The address who shutdown this vault.
    event Shutdown(address account);

    /// @dev Emitted when a new security manager is set.
    ///
    /// @param account The address who changed the security manager.
    /// @param newManager The address of new security manager.
    event SecurityManagerUpdated(address account, address newManager);

    /// @dev Emitted when a new strategy is set.
    ///
    /// @param account The address who changed strategy to a new one.
    /// @param newStrategy The address of a new strategy.
    event StrategyUpdated(address account, address newStrategy);

    /// @dev Emitted when the entry cost configuration is changed.
    ///
    /// @param account The address who changed the entry cost configuration.
    /// @param newEntryCost The value of the new entry cost configuration.
    event EntryCostUpdated(address account, uint256 newEntryCost);

    /// @dev Emitted when the exit cost configuration is changed.
    ///
    /// @param account The address who changed the exit cost configuration.
    /// @param newExitCost The value of the new exit cost configuration.
    event ExitCostUpdated(address account, uint256 newExitCost);

    /// @dev Emitted when the priority provider address is changed.
    ///
    /// @param account The address who changed the priority provider.
    /// @param newPriorityProvider The address of new priority provider.
    event PriorityProviderUpdated(address account, address newPriorityProvider);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts if the caller is not a security manager.
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
        _setEntryCost(entryCost_);
        _setExitCost(exitCost_);
        _setPriorityProvider(priorityProvider_);
    }

    function _setEntryCost(uint256 value) internal {
        require(value < 1 ether);
        if (entryCost() != value) {
            _getLogarithmVaultStorage().entryCost = value;
            emit EntryCostUpdated(_msgSender(), value);
        }
    }

    function _setExitCost(uint256 value) internal {
        require(value < 1 ether);
        if (exitCost() != value) {
            _getLogarithmVaultStorage().exitCost = value;
            emit ExitCostUpdated(_msgSender(), value);
        }
    }

    function _setPriorityProvider(address newProvider) internal {
        if (priorityProvider() != newProvider) {
            _getLogarithmVaultStorage().priorityProvider = newProvider;
            emit PriorityProviderUpdated(_msgSender(), newProvider);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

    /// @notice Configures the security manager.
    ///
    /// @param account The address of new security manager.
    /// A zero address means disabling security manager functions.
    function setSecurityManager(address account) external onlyOwner {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        $.securityManager = account;
        emit SecurityManagerUpdated(_msgSender(), account);
    }

    /// @notice Configures the strategy.
    /// Note:
    /// - Approve new strategy to manage asset of this vault infinitely.
    /// - If there is an old strategy, revoke its asset approval after stopping the strategy.
    function setStrategy(address _strategy) external onlyOwner {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

        IERC20 _asset = IERC20(asset());
        address prevStrategy = strategy();

        if (prevStrategy != address(0)) {
            IStrategy(prevStrategy).stop();
            _asset.approve(prevStrategy, 0);
        }

        require(_strategy != address(0));
        $.strategy = _strategy;
        _asset.approve(_strategy, type(uint256).max);

        emit StrategyUpdated(_msgSender(), _strategy);
    }

    /// @notice Configures new entry cost setting.
    function setEntryCost(uint256 newEntryCost) external onlyOwner {
        _setEntryCost(newEntryCost);
    }

    /// @notice Configures new exit cost setting.
    function setExitCost(uint256 newExitCost) external onlyOwner {
        _setExitCost(newExitCost);
    }

    /// @notice Configures new priority provider.
    function setPriorityProvider(address newProvider) external onlyOwner {
        _setPriorityProvider(newProvider);
    }

    /// @notice Shutdown vault, where all deposit/mint are disabled while withdraw/redeem are still available.
    function shutdown() external onlyOwner {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        $.shutdown = true;
        IStrategy(strategy()).stop();
        emit Shutdown(_msgSender());
    }

    /// @notice Pauses Vault temporarily so that deposit and withdraw functions are disabled.
    /// This function is callable only by the security manager
    /// and is used if some unexpected behaviors from external protocols are spotted
    /// by the security manager.
    ///
    /// @param stopStrategy True means stopping strategy, otherwise pausing strategy.
    function pause(bool stopStrategy) external onlySecurityManager whenNotPaused {
        if (stopStrategy) {
            IStrategy(strategy()).stop();
        } else {
            IStrategy(strategy()).pause();
        }
        _pause();
    }

    /// @dev Unpauses Vault while unpausing the connected strategy.
    /// This function is callable only by the security manager.
    function unpause() external onlySecurityManager whenPaused {
        IStrategy(strategy()).unpause();
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                          ASYNC WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the maximum amount of the underlying asset that can be
    /// requested to withdraw from the owner balance in the Vault,
    /// through a requestWithdraw call.
    function maxRequestWithdraw(address owner) public view returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxWithdraw(owner);
    }

    /// @notice Returns the maximum amount of Vault shares that can be
    /// requested to redeem from the owner balance in the Vault,
    /// through a requestRedeem call.
    function maxRequestRedeem(address owner) public view returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxRedeem(owner);
    }

    /// @notice Requests to withdraw assets and returns a unique withdraw key
    /// if the requested asset amount is bigger than the idle assets.
    /// If idle assets are available in the Vault, they are withdrawn synchronously
    /// within the `requestWithdraw` call, while any shortfall amount remains
    /// pending for execution by the system.
    ///
    /// @dev Burns shares from owner and sends exactly assets of underlying tokens
    /// to receiver if the idle assets is enough.
    /// If the idle assets is not enough, creates a withdraw request with
    /// the shortfall assets while sending the idle assets to receiver.
    ///
    /// @return The withdraw key that is used in the claim function.
    function requestWithdraw(uint256 assets, address receiver, address owner) public virtual returns (bytes32) {
        uint256 maxRequestAssets = maxRequestWithdraw(owner);
        if (assets > maxRequestAssets) {
            revert Errors.ExceededMaxRequestWithdraw(owner, assets, maxRequestAssets);
        }

        uint256 maxAssets = maxWithdraw(owner);
        uint256 assetsToWithdraw = assets > maxAssets ? maxAssets : assets;
        // always assetsToWithdraw <= assets
        uint256 assetsToRequest = assets - assetsToWithdraw;

        uint256 shares = previewWithdraw(assets);
        uint256 sharesToRedeem = previewWithdraw(assetsToWithdraw);
        uint256 sharesToRequest = shares - sharesToRedeem;

        if (assetsToWithdraw > 0) {
            _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);
        }

        if (assetsToRequest > 0) {
            return _requestWithdraw(_msgSender(), receiver, owner, assetsToRequest, sharesToRequest);
        }
        return bytes32(0);
    }

    /// @notice Requests to redeem shares and returns a unique withdraw key
    /// if the derived asset amount is bigger than the idle assets.
    /// If idle assets are available in the Vault, they are withdrawn synchronously
    /// within the `requestWithdraw` call, while any shortfall amount remains
    /// pending for execution by the system.
    ///
    /// @dev Burns exactly shares from owner and sends assets of underlying tokens
    /// to receiver if the idle assets is enough,
    /// If the idle assets is not enough, creates a withdraw request with
    /// the shortfall assets while sending the idle assets to receiver.
    ///
    /// @return The withdraw key that is used in the claim function.
    function requestRedeem(uint256 shares, address receiver, address owner) public virtual returns (bytes32) {
        uint256 maxRequestShares = maxRequestRedeem(owner);
        if (shares > maxRequestShares) {
            revert Errors.ExceededMaxRequestRedeem(owner, shares, maxRequestShares);
        }

        uint256 maxShares = maxRedeem(owner);
        uint256 sharesToRedeem = shares > maxShares ? maxShares : shares;
        // always sharesToRedeem <= shares
        uint256 sharesToRequest = shares - sharesToRedeem;

        uint256 assets = previewRedeem(shares);
        uint256 assetsToWithdraw = previewRedeem(sharesToRedeem);
        uint256 assetsToRequest = assets - assetsToWithdraw;

        if (sharesToRedeem > 0) {
            _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);
        }

        if (sharesToRequest > 0) {
            return _requestWithdraw(_msgSender(), receiver, owner, assetsToRequest, sharesToRequest);
        }
        return bytes32(0);
    }

    /// @dev requestWithdraw/requestRedeem common workflow.
    function _requestWithdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assetsToRequest,
        uint256 sharesToRequest
    ) internal virtual returns (bytes32) {
        if (caller != owner) {
            _spendAllowance(owner, caller, sharesToRequest);
        }
        _burn(owner, sharesToRequest);

        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        uint256 _accRequestedWithdrawAssets;
        if (isPrioritized(owner)) {
            _accRequestedWithdrawAssets = $.prioritizedAccRequestedWithdrawAssets + assetsToRequest;
            $.prioritizedAccRequestedWithdrawAssets = _accRequestedWithdrawAssets;
        } else {
            _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets + assetsToRequest;
            $.accRequestedWithdrawAssets = _accRequestedWithdrawAssets;
        }

        bytes32 withdrawKey = getWithdrawKey(owner, _useNonce(owner));
        $.withdrawRequests[withdrawKey] = WithdrawRequest({
            requestedAssets: assetsToRequest,
            accRequestedWithdrawAssets: _accRequestedWithdrawAssets,
            requestTimestamp: block.timestamp,
            owner: owner,
            receiver: receiver,
            isClaimed: false
        });
        emit WithdrawRequested(caller, receiver, owner, withdrawKey, assetsToRequest, sharesToRequest);

        return withdrawKey;
    }

    /// @notice Processes pending withdraw requests with idle assets.
    ///
    /// @dev This is a decentralized function that can be called by anyone.
    ///
    /// @return The assets used to process pending withdraw requests.
    function processPendingWithdrawRequests() public returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();

        uint256 _idleAssets = idleAssets();
        if (_idleAssets == 0) return 0;

        (uint256 remainingAssets, uint256 processedAssetsForPrioritized) = _calcProcessedAssets(
            _idleAssets, $.prioritizedProcessedWithdrawAssets, $.prioritizedAccRequestedWithdrawAssets
        );
        if (processedAssetsForPrioritized > 0) {
            $.prioritizedProcessedWithdrawAssets += processedAssetsForPrioritized;
        }

        if (remainingAssets == 0) {
            $.assetsToClaim += processedAssetsForPrioritized;
            return processedAssetsForPrioritized;
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

    /// @notice Claims a withdraw request if it is executed.
    ///
    /// @param withdrawRequestKey The withdraw key that was returned by requestWithdraw/requestRedeem.
    function claim(bytes32 withdrawRequestKey) public virtual returns (uint256) {
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

    /// @notice Tells if the withdraw request is claimable or not.
    ///
    /// @param withdrawRequestKey The withdraw key that was returned by requestWithdraw/requestRedeem.
    function isClaimable(bytes32 withdrawRequestKey) external view returns (bool) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        WithdrawRequest memory withdrawRequest = $.withdrawRequests[withdrawRequestKey];
        (bool isExecuted,) =
            _isWithdrawRequestExecuted(isPrioritized(withdrawRequest.owner), withdrawRequest.accRequestedWithdrawAssets);

        return isExecuted && !withdrawRequest.isClaimed;
    }

    /// @notice Tells if the owner is prioritized to withdraw.
    function isPrioritized(address owner) public view returns (bool) {
        address _priorityProvider = _getLogarithmVaultStorage().priorityProvider;
        if (_priorityProvider == address(0)) {
            return false;
        }
        return IPriorityProvider(_priorityProvider).isPrioritized(owner);
    }

    /// @notice The underlying asset amount in this vault that is free to withdraw or utilize.
    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - _getLogarithmVaultStorage().assetsToClaim;
    }

    /// @notice The underlying asset amount requested to withdraw, that is not executed yet.
    function totalPendingWithdraw() public view returns (uint256) {
        return prioritizedAccRequestedWithdrawAssets() + accRequestedWithdrawAssets()
            - prioritizedProcessedWithdrawAssets() - processedWithdrawAssets();
    }

    /// @dev Derives a unique withdraw key based on the user's address and his/her nonce.
    function getWithdrawKey(address user, uint256 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), user, nonce));
    }

    /*//////////////////////////////////////////////////////////////
                             ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function totalAssets() public view virtual override returns (uint256 assets) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        (, assets) = (idleAssets() + IStrategy(strategy()).utilizedAssets()).trySub(totalPendingWithdraw());
        return assets;
    }

    /// @inheritdoc ERC4626Upgradeable
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        if (totalSupply() == 0) {
            return assets;
        }
        // calculate the amount of assets that will be utilized
        (, uint256 assetsToUtilize) = assets.trySub(totalPendingWithdraw());

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
        (, uint256 assetsToUtilize) = assets.trySub(totalPendingWithdraw());

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
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (paused() || isShutdown()) {
            return 0;
        } else {
            return super.maxDeposit(receiver);
        }
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (paused() || isShutdown()) {
            return 0;
        } else {
            return super.maxDeposit(receiver);
        }
    }

    /// @dev This is limited by the idle assets.
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        uint256 assets = super.maxWithdraw(owner);
        uint256 withdrawableAssets = idleAssets();
        return assets > withdrawableAssets ? withdrawableAssets : assets;
    }

    /// @dev This is limited by the idle assets.
    ///
    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        uint256 shares = super.maxRedeem(owner);
        uint256 redeemableShares = _convertToShares(idleAssets(), Math.Rounding.Ceil);
        return shares > redeemableShares ? redeemableShares : shares;
    }

    /// @dev If there are pending withdraw requests, the deposited assets is used to process them.
    /// And disables harvesting of the performance fee as a core logarithm vault doesn't have the functionality.
    ///
    /// @inheritdoc ERC4626Upgradeable
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        ERC4626Upgradeable._deposit(caller, receiver, assets, shares);
        processPendingWithdrawRequests();
    }

    /// @dev Disables harvesting of the performance fee as a core logarithm vault doesn't have the functionality.
    ///
    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        ERC4626Upgradeable._withdraw(caller, receiver, owner, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calculates the processed withdrawal assets.
    ///
    /// @param _idleAssets The idle assets available for processing withdraw requests.
    /// @param _processedWithdrawAssets The value of processedWithdrawAssets storage variable.
    /// @param _accRequestedWithdrawAssets The value of accRequestedWithdrawAssets storage variable.
    ///
    /// @return remainingAssets The remaining asset amount after processing
    /// @return processedAssets The processed asset amount
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

    /// @dev Executable state of withdraw request
    ///
    /// @param isPrioritizedAccount Tells if account is prioritized for withdrawal
    /// @param accRequestedWithdrawAssetsOfRequest The accRequestedWithdrawAssets storage value of withdraw request
    ///
    /// @return isExecuted Tells whether a request is executed or not
    /// @return isLast Tells whether a request is last or not
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
            isExecuted = IStrategy(strategy()).utilizedAssets() == 0;
        } else {
            isExecuted = isPrioritizedAccount
                ? accRequestedWithdrawAssetsOfRequest <= $.prioritizedProcessedWithdrawAssets
                : accRequestedWithdrawAssetsOfRequest <= $.processedWithdrawAssets;
        }

        return (isExecuted, isLast);
    }

    /// @dev Uses nonce of the specified user and increase it
    function _useNonce(address user) internal returns (uint256) {
        LogarithmVaultStorage storage $ = _getLogarithmVaultStorage();
        // For each vault, the nonce has an initial value of 0, can only be incremented by one, and cannot be
        // decremented or reset. This guarantees that the nonce never overflows.
        unchecked {
            // It is important to do x++ and not ++x here.
            return $.nonces[user]++;
        }
    }

    /// @dev Calculates the cost that should be added to an amount `assets` that does not include cost.
    /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function _costOnRaw(uint256 assets, uint256 costRate) private pure returns (uint256) {
        return assets.mulDiv(costRate, Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
    }

    /// @dev Calculates the cost part of an amount `assets` that already includes cost.
    /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function _costOnTotal(uint256 assets, uint256 costRate) private pure returns (uint256) {
        return assets.mulDiv(costRate, costRate + Constants.FLOAT_PRECISION, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of strategy that uses the underlying asset of this vault.
    function strategy() public view returns (address) {
        return _getLogarithmVaultStorage().strategy;
    }

    /// @notice The priority provider address which provides the prioritized accounts.
    /// For example, the addresses of logarithm meta vaults are prioritized to withdraw.
    /// Prioritizing of withdraw means that their withdraw requests are processed before the other normal withdraw requests.
    function priorityProvider() public view returns (address) {
        return _getLogarithmVaultStorage().priorityProvider;
    }

    /// @notice The entry cost percent that is charged when depositing.
    ///
    /// @dev Denominated in 18 decimals.
    function entryCost() public view returns (uint256) {
        return _getLogarithmVaultStorage().entryCost;
    }

    /// @notice The exit cost percent that is charged when withdrawing.
    ///
    /// @dev Denominated in 18 decimals.
    function exitCost() public view returns (uint256) {
        return _getLogarithmVaultStorage().exitCost;
    }

    /// @notice The underlying asset amount that is in Vault and
    /// reserved to claim for the executed withdraw requests.
    function assetsToClaim() public view returns (uint256) {
        return _getLogarithmVaultStorage().assetsToClaim;
    }

    /// @dev The accumulated underlying asset amount requested to withdraw by the normal users.
    function accRequestedWithdrawAssets() public view returns (uint256) {
        return _getLogarithmVaultStorage().accRequestedWithdrawAssets;
    }

    /// @dev The accumulated underlying asset amount processed for the normal withdraw requests.
    function processedWithdrawAssets() public view returns (uint256) {
        return _getLogarithmVaultStorage().processedWithdrawAssets;
    }

    /// @dev The accumulated underlying asset amount requested to withdraw by the prioritized users.
    function prioritizedAccRequestedWithdrawAssets() public view returns (uint256) {
        return _getLogarithmVaultStorage().prioritizedAccRequestedWithdrawAssets;
    }

    /// @dev The accumulated underlying asset amount processed for the prioritized withdraw requests.
    function prioritizedProcessedWithdrawAssets() public view returns (uint256) {
        return _getLogarithmVaultStorage().prioritizedProcessedWithdrawAssets;
    }

    /// @dev Returns the state of a withdraw request for the withdrawKey.
    function withdrawRequests(bytes32 withdrawKey) public view returns (WithdrawRequest memory) {
        return _getLogarithmVaultStorage().withdrawRequests[withdrawKey];
    }

    /// @dev Returns a nonce of a user that are reserved to generate the next withdraw key.
    function nonces(address user) public view returns (uint256) {
        return _getLogarithmVaultStorage().nonces[user];
    }

    /// @notice The address of security manager who is responsible for pausing/unpausing vault.
    function securityManager() public view returns (address) {
        return _getLogarithmVaultStorage().securityManager;
    }

    /// @notice When this vault is shutdown, only withdrawals are available. It can't be reverted.
    function isShutdown() public view returns (bool) {
        return _getLogarithmVaultStorage().shutdown;
    }
}
