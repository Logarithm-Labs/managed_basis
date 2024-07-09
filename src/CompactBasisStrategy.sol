// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DepositLogic} from "src/libraries/logic/DepositLogic.sol";

import {Errors} from "src/libraries/Errors.sol";

contract CompactBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    enum SwapType {
        MANUAL,
        INCH_V6
    }

    enum StrategyStatus {
        IDLE,
        NEED_KEEP,
        KEEPING,
        DEPOSITING,
        WITHDRAWING,
        REBALANCING_UP, // increase leverage
        REBALANCING_DOWN // decrease leverage

    }

    struct WithdrawState {
        uint256 requestTimestamp;
        uint256 requestedAmount;
        uint256 executedFromSpot;
        uint256 executedFromIdle;
        uint256 executedFromHedge;
        uint256 executionCost;
        address receiver;
        address callbackTarget;
        bool isExecuted;
        bool isClaimed;
        bytes callbackData;
    }

    struct StrategyStateChache {
        uint256 assetsToClaim;
        uint256 assetsToWithdraw;
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 totalPendingWithdraw;
        uint256 withdrawnFromSpot;
        uint256 withdrawnFromIdle;
        uint256 withdrawingFromHedge;
        uint256 spotExecutionPrice;
    }

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
        mapping(bytes32 => WithdrawState) withdrawRequests;
        // status state
        StrategyStatus strategyStatus;
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
                        STATE TRANSITIONS   
    //////////////////////////////////////////////////////////////*/

    function getStrategyStateCache() public view returns (StrategyStateChache memory cache) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
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

    function updateStrategyState(StrategyStateChache memory cache) internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
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

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / WITHDRAW LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @dev See {IERC4626-deposit}.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual returns (uint256) {
        StrategyStateChache memory cache = getStrategyStateCache();
        DepositLogic.DepositParams memory params = DepositLogic.DepositParams({
            asset: asset(),
            caller: msg.sender,
            receiver: receiver,
            assets: assets,
            shares: shares,
            cache: cache
        });
        cache = DepositLogic.executeDeposit(msg.sender, receiver, assets, shares);
        updateStrategyState(cache);

        return shares;
    }


    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual {
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
        StrategyStateChache memory cache = getStrategyStateCache();
        DepositLogic.WithdrawParams memory params = DepositLogic.WithdrawParams({
            asset: asset(),
            caller: msg.sender,
            receiver: receiver,
            owner: owner,
            assets: assets,
            shares: shares,
            targetLeverage: $.targetLeverage,
            requestCounter: $.requestCounter[owner],
            cache: cache
        });
        cache 


        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}
