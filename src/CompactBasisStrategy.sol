// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AccountingLogic} from "src/libraries/logic/AccountingLogic.sol";
import {DepositorLogic} from "src/libraries/logic/DepositorLogic.sol";
import {OperatorLogic} from "src/libraries/logic/OperatorLogic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

contract CompactBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.ManagedBasisStrategyStorageV1
    struct ManagedBasisStrategyStorage {
        // address state
        address oracle;
        address operator;
        address positionManager;
        // leverage state
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        // fee state
        uint256 entryFee;
        uint256 exitFee;
        // strategy configuration
        uint256 hedgeDeviationThreshold;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        uint256 safeMarginTreasury;
        // asset state
        uint256 assetsToClaim; // asset balance that is ready to claim
        uint256 assetsToWithdraw; // asset balance that is processed for withdrawals
        // pending state
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 totalPendingWithdraw; // total amount of asset that remains to be withdrawn
        uint256 withdrawnFromSpot; // asset amount withdrawn from spot that is not yet processed
        uint256 withdrawnFromIdle; // asset amount withdrawn from idle that is not yet processed
        uint256 withdrawingFromHedge; // asset amount that is ready to be withdrawn from hedge
        uint256 spotExecutionPrice;
        // withdraw state
        bytes32[] activeWithdrawRequests;
        bytes32[] closedWithdrawRequests;
        mapping(address => uint128) requestCounter;
        mapping(bytes32 => DataTypes.WithdrawState) withdrawRequests;
        // status state
        DataTypes.StrategyStatus strategyStatus;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedBasisStrategyStorageV1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ManagedBasisStrategyStorageLocation =
        0x76bd71a320090dc5d8c5864143521b706fefaa2f93d6b1826cde0a967ebe6100;

    function _getManagedBasisStrategyStorage() private pure returns (ManagedBasisStrategyStorage storage $) {
        assembly {
            $.slot := ManagedBasisStrategyStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        string memory name,
        string memory symbol,
        address _asset,
        address _product,
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _entryFee,
        uint256 _exitFee
    ) external initializer {
        __LogBaseVault_init(IERC20(_asset), IERC20(_product), name, symbol);
        __Ownable_init(msg.sender);
        __ManagedBasisStrategy_init(
            _oracle, _operator, _targetLeverage, _minLeverage, _maxLeverage, _entryFee, _exitFee
        );
    }

    function __ManagedBasisStrategy_init(
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _entryFee,
        uint256 _exitFee
    ) public initializer {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.oracle = _oracle;
        $.operator = _operator;
        $.entryFee = _entryFee;
        $.exitFee = _exitFee;
        $.targetLeverage = _targetLeverage;
        $.minLeverage = _minLeverage;
        $.maxLeverage = _maxLeverage;
        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        $.hedgeDeviationThreshold = 1e16; // 1%
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequest(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 withdrawId, uint256 amount
    );

    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    event UpdatePendingUtilization(uint256 amount);

    event UpdatePendingDeutilization(uint256 amount);

    event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event Deutilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event SwapFailed();

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (msg.sender != $.operator) {
            revert Errors.CallerNotOperator();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        STATE TRANSITIONS   
    //////////////////////////////////////////////////////////////*/

    function _getStrategyAddresses(ManagedBasisStrategyStorage storage $)
        internal
        view
        virtual
        returns (DataTypes.StrategyAddresses memory addr)
    {
        addr.asset = asset();
        addr.product = product();
        addr.oracle = $.oracle;
        addr.operator = $.operator;
        addr.positionManager = $.positionManager;
    }

    function _getStrategyStateCache(ManagedBasisStrategyStorage storage $)
        internal
        view
        virtual
        returns (DataTypes.StrategyStateChache memory cache)
    {
        cache.assetsToClaim = $.assetsToClaim;
        cache.assetsToWithdraw = $.assetsToWithdraw;
        cache.pendingUtilization = $.pendingUtilization;
        cache.pendingDeutilization = $.pendingDeutilization;
        cache.pendingIncreaseCollateral = $.pendingIncreaseCollateral;
        cache.pendingDecreaseCollateral = $.pendingDecreaseCollateral;
        cache.totalPendingWithdraw = $.totalPendingWithdraw;
        cache.withdrawnFromSpot = $.withdrawnFromSpot;
        cache.withdrawnFromIdle = $.withdrawnFromIdle;
        cache.withdrawingFromHedge = $.withdrawingFromHedge;
        cache.spotExecutionPrice = $.spotExecutionPrice;
    }

    function _updateStrategyState(ManagedBasisStrategyStorage storage $, DataTypes.StrategyStateChache memory cache)
        internal
        virtual
    {
        if ($.pendingUtilization != cache.pendingUtilization) {
            emit UpdatePendingUtilization(cache.pendingUtilization);
        }
        if ($.pendingDeutilization != cache.pendingDeutilization) {
            emit UpdatePendingDeutilization(cache.pendingDeutilization);
        }

        $.assetsToClaim = cache.assetsToClaim;
        $.assetsToWithdraw = cache.assetsToWithdraw;
        $.pendingUtilization = cache.pendingUtilization;
        $.pendingDeutilization = cache.pendingDeutilization;
        $.pendingIncreaseCollateral = cache.pendingIncreaseCollateral;
        $.pendingDecreaseCollateral = cache.pendingDecreaseCollateral;
        $.totalPendingWithdraw = cache.totalPendingWithdraw;
        $.withdrawnFromSpot = cache.withdrawnFromSpot;
        $.withdrawnFromIdle = cache.withdrawnFromIdle;
        $.withdrawingFromHedge = cache.withdrawingFromHedge;
        $.spotExecutionPrice = cache.spotExecutionPrice;
    }

    function _updateWithdrawState(
        ManagedBasisStrategyStorage storage $,
        bytes32 withdrawId,
        DataTypes.WithdrawState memory withdrawState
    ) internal virtual {
        $.withdrawRequests[withdrawId] = withdrawState;
    }

    function _executeAdjustPosition(address positionManager, IPositionManager.AdjustPositionParams memory params)
        internal
        virtual
    {
        if (params.isIncrease && params.collateralDeltaAmount > 0) {
            IERC20(asset()).safeTransfer(positionManager, params.collateralDeltaAmount);
        }
        IPositionManager(positionManager).adjustPosition(params);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / WITHDRAW LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @dev Deposit/mint common workflow.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        DepositorLogic.DepositParams memory params = DepositorLogic.DepositParams({
            caller: msg.sender,
            receiver: receiver,
            assets: assets,
            shares: shares,
            targetLeverage: $.targetLeverage,
            cache: cache
        });
        cache = DepositorLogic.executeDeposit(params);
        _updateStrategyState($, cache);

        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw/redeem common workflow.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
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

        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        address asset_ = asset();
        bytes32 withdrawId;
        DataTypes.WithdrawState memory withdrawState;
        uint256 requestedAmount;
        DepositorLogic.WithdrawParams memory params = DepositorLogic.WithdrawParams({
            caller: msg.sender,
            receiver: receiver,
            owner: owner,
            callbackTarget: address(0),
            assets: assets,
            shares: shares,
            requestCounter: $.requestCounter[owner],
            targetLeverage: $.targetLeverage,
            addr: addr,
            cache: cache,
            callbackData: ""
        });
        (withdrawId, requestedAmount, cache, withdrawState) = DepositorLogic.executeWithdraw(params);
        if (withdrawId == bytes32(0)) {
            // empty withdrawId means withdraw was executed immediately against idle assets
            // no need to create a withdraw request, withdrawing assets should be transferred to receiver
            IERC20(asset_).safeTransfer(receiver, assets);
        } else {
            _updateWithdrawState($, withdrawId, withdrawState);
            $.activeWithdrawRequests.push(withdrawId);
            $.requestCounter[owner]++;

            emit WithdrawRequest(caller, receiver, owner, withdrawId, requestedAmount);
        }

        _updateStrategyState($, cache);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual returns (uint256 executedAmount) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        DataTypes.WithdrawState memory withdrawState = $.withdrawRequests[requestId];
        DepositorLogic.ClaimParams memory params =
            DepositorLogic.ClaimParams({caller: msg.sender, withdrawState: withdrawState, cache: cache});
        (executedAmount, cache, withdrawState) = DepositorLogic.executeClaim(params);

        _updateStrategyState($, cache);
        _updateWithdrawState($, requestId, withdrawState);

        IERC20(asset()).safeTransfer(msg.sender, executedAmount);

        emit Claim(msg.sender, requestId, executedAmount);
    }

    function getWithdrawId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return DepositorLogic.getWithdrawId(owner, counter);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view virtual override returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        (,, assets) = AccountingLogic.getTotalAssets(addr, cache);
    }

    function utilizedAssets() public view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyAddresses memory addr = _getStrategyAddresses($);
        return AccountingLogic.getUtilizedAssets(addr);
    }

    function idleAssets() public view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        return AccountingLogic.getIdleAssets(asset(), cache);
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256 shares) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return AccountingLogic.getPreviewDeposit(
            AccountingLogic.PreviewParams({
                assetsOrShares: assets,
                fee: $.entryFee,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return AccountingLogic.getPreviewMint(
            AccountingLogic.PreviewParams({
                assetsOrShares: shares,
                fee: $.entryFee,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256 shares) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return AccountingLogic.getPreviewWithdraw(
            AccountingLogic.PreviewParams({
                assetsOrShares: assets,
                fee: $.exitFee,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return AccountingLogic.getPreviewRedeem(
            AccountingLogic.PreviewParams({
                assetsOrShares: shares,
                fee: $.exitFee,
                totalSupply: totalSupply(),
                addr: _getStrategyAddresses($),
                cache: _getStrategyStateCache($)
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata swapData)
        external
        virtual
        onlyOperator
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        bool success;
        uint256 amountOut;
        IPositionManager.AdjustPositionParams memory adjustPositionParams;
        (success, amountOut, cache, adjustPositionParams) = OperatorLogic.executeUtilize(
            OperatorLogic.UtilizeParams({
                amount: amount,
                status: $.strategyStatus,
                swapType: swapType,
                addr: _getStrategyAddresses($),
                cache: cache,
                swapData: swapData
            })
        );
        if (success) {
            _updateStrategyState($, cache);
            _executeAdjustPosition($.positionManager, adjustPositionParams);
            emit Utilize(msg.sender, amount, adjustPositionParams.sizeDeltaInTokens);
        } else {
            emit SwapFailed();
        }
    }

    function deutilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata swapData)
        external
        virtual
        onlyOperator
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStateChache memory cache = _getStrategyStateCache($);
        bool success;
        uint256 amountOut;
        IPositionManager.AdjustPositionParams memory adjustPositionParams;
        (success, amountOut, cache, adjustPositionParams) = OperatorLogic.executeDeutilize(
            OperatorLogic.UtilizeParams({
                amount: amount,
                status: $.strategyStatus,
                swapType: swapType,
                addr: _getStrategyAddresses($),
                cache: cache,
                swapData: swapData
            })
        );
        if (success) {
            _updateStrategyState($, cache);
            _executeAdjustPosition($.positionManager, adjustPositionParams);
            emit Deutilize(msg.sender, amount, adjustPositionParams.sizeDeltaInTokens);
        } else {
            emit SwapFailed();
        }
    }
}
