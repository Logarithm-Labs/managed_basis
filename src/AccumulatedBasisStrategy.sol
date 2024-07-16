// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOffChainPositionManager} from "src/interfaces/IOffChainPositionManager.sol";
import "src/interfaces/IManagedBasisStrategy.sol";
import {IManagedBasisCallbackReceiver} from "src/interfaces/IManagedBasisCallbackReceiver.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {InchAggregatorV6Logic} from "src/libraries/InchAggregatorV6Logic.sol";

import {IOracle} from "src/interfaces/IOracle.sol";

import {Errors} from "src/libraries/Errors.sol";
import {FactoryDeployable} from "src/common/FactoryDeployable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";

import {console2 as console} from "forge-std/console2.sol";

contract AccumulatedBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
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

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct WithdrawRequest {
        address receiver;
        uint256 requestedAssets;
        uint256 accRequestedWithdrawAssets;
    }

    struct ManagedBasisStrategyStorage {
        IOracle oracle;
        address operator;
        address positionManager;
        uint256 targetLeverage;
        uint256 entryCost;
        uint256 exitCost;
        uint256 hedgeDeviationThreshold;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        uint256 assetsToClaim; // asset balance that is ready to claim
        uint256 assetsToWithdraw; // asset balance that is processed for withdrawals
        uint256 pendingUtilization;
        // uint256 pendingDeutilization;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        // uint256 totalPendingWithdraw; // total amount of asset that remains to be withdrawn
        // uint256 withdrawnFromSpot; // asset amount withdrawn from spot that is not yet processed
        // uint256 withdrawnFromIdle; // asset amount withdrawn from idle that is not yet processed
        // uint256 withdrawingFromHedge; // asset amount that is ready to be withdrawn from hedge
        // uint256 spotExecutionPrice;
        // bytes32[] activeWithdrawRequests;
        // bytes32[] closedWithdrawRequests;
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        StrategyStatus strategyStatus;
        mapping(address => uint128) requestCounter;
        // mapping(bytes32 => WithdrawState) withdrawRequests;
        mapping(bytes32 => WithdrawRequest) withdrawRequests;
    }
    // mapping(bytes32 => RequestParams) positionRequests;

    uint256 public constant PRECISION = 1e18;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.ManagedBasisStrategyStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ManagedBasisStrategyStorageLocation =
        0xf5ffd60679e080b7c4e308f2409616890be7bc10ba607661a7e13210852af100;

    function _getManagedBasisStrategyStorage() private pure returns (ManagedBasisStrategyStorage storage $) {
        assembly {
            $.slot := ManagedBasisStrategyStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _asset,
        address _product,
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _entryCost,
        uint256 _exitCost
    ) external initializer {
        __ERC4626_init(IERC20(_asset));
        __LogBaseVault_init(IERC20(_product));
        __Ownable_init(msg.sender);
        __ManagedBasisStrategy_init(_oracle, _operator, _targetLeverage, _entryCost, _exitCost);
    }

    function __ManagedBasisStrategy_init(
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _entryCost,
        uint256 _exitCost
    ) public initializer {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.oracle = IOracle(_oracle);
        $.operator = _operator;
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
        $.targetLeverage = _targetLeverage;
        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        $.hedgeDeviationThreshold = 1e16; // 1%
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequested(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 withdrawId, uint256 amount
    );

    event ExecuteWithdraw(bytes32 requestKey, uint256 requestedAmount, uint256 executedAmount);

    event Claim(address indexed claimer, bytes32 requestKey, uint256 amount);

    event UpdatePendingUtilization(uint256 amount);

    event UpdatePendingDeutilization(uint256 amount);

    event Utilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    event Deutilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    event AfterAdjustPosition(
        uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease, bool isSuccess
    );

    event UpdateStrategyStatus(StrategyStatus status);

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

    modifier onlyPositionManager() {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (msg.sender != $.positionManager) {
            revert Errors.CallerNotPositionManager();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getManagedBasisStrategyStorage().positionManager = _positionManager;
    }

    function setEntryExitCosts(uint256 _entryCost, uint256 _exitCost) external onlyOperator {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
    }

    function setDepositLimits(uint256 userLimit, uint256 strategyLimit) external onlyOwner {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.userDepositLimit = userLimit;
        $.strategyDepostLimit = strategyLimit;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address receiver) public view virtual override returns (uint256 allowed) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if ($.userDepositLimit == type(uint256).max && $.strategyDepostLimit == type(uint256).max) {
            return type(uint256).max;
        } else {
            uint256 sharesBalance = balanceOf(receiver);
            uint256 sharesValue = convertToAssets(sharesBalance);
            uint256 availableDepositorLimit =
                $.userDepositLimit == type(uint256).max ? type(uint256).max : $.userDepositLimit - sharesValue;
            uint256 availableStrategyLimit =
                $.strategyDepostLimit == type(uint256).max ? type(uint256).max : $.strategyDepostLimit - totalAssets();
            uint256 userBalance = IERC20(asset()).balanceOf(address(receiver));
            allowed =
                availableDepositorLimit < availableStrategyLimit ? availableDepositorLimit : availableStrategyLimit;
            allowed = userBalance < allowed ? userBalance : allowed;
        }
    }

    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        return previewDeposit(maxAssets);
    }

    /**
     * @dev Deposit/mint common workflow.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        IERC20 _asset = IERC20(asset());
        _asset.safeTransferFrom(caller, address(this), assets);

        uint256 assetsToDeposit = _processWithdrawRequests(assets);

        if (assetsToDeposit > 0) {
            uint256 assetsToHedge = assetsToDeposit.mulDiv(PRECISION, PRECISION + $.targetLeverage);
            uint256 assetsToSpot = assetsToDeposit - assetsToHedge;
            $.pendingUtilization += assetsToSpot;
            $.pendingIncreaseCollateral += assetsToHedge;

            emit UpdatePendingUtilization($.pendingUtilization);
        }

        _checkStrategyStatus();
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
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

        uint256 idle = idleAssets();
        if (idle >= assets) {
            uint256 assetsWithdrawnFromSpot = assets.mulDiv($.targetLeverage, PRECISION + $.targetLeverage);
            uint256 assetsWithdrawnFromHedge = assets - assetsWithdrawnFromSpot;

            // update pending states, prevent underflow
            (, uint256 pendingUtilization_) = $.pendingUtilization.trySub(assetsWithdrawnFromSpot);
            (, uint256 pendingIncreaseCollateral_) = $.pendingIncreaseCollateral.trySub(assetsWithdrawnFromHedge);
            $.pendingUtilization = pendingUtilization_;
            $.pendingIncreaseCollateral = pendingIncreaseCollateral_;

            emit UpdatePendingUtilization(pendingUtilization_);

            IERC20(asset()).safeTransfer(receiver, assets);
        } else {
            // if all idle assets are withdrawn, set pending states to zero
            $.pendingUtilization = 0;
            $.pendingIncreaseCollateral = 0;
            $.assetsToClaim += idle;
            emit UpdatePendingUtilization(0);

            (, uint256 pendingWithdraw) = assets.trySub(idle);

            uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;
            _accRequestedWithdrawAssets += pendingWithdraw;
            $.accRequestedWithdrawAssets = _accRequestedWithdrawAssets;

            uint128 counter = $.requestCounter[owner];
            bytes32 withdrawId = getWithdrawKey(owner, counter);
            $.withdrawRequests[withdrawId] = WithdrawRequest({
                receiver: receiver,
                requestedAssets: assets,
                accRequestedWithdrawAssets: _accRequestedWithdrawAssets
            });

            uint256 pendingDeutilization_ = pendingDeutilization();
            // $.pendingDeutilization = pendingDeutilization_;
            // $.totalPendingWithdraw = totalPendingWithdraw_;
            // $.assetsToWithdraw += idle;
            // $.activeWithdrawRequests.push(withdrawId);

            $.requestCounter[owner]++;

            emit UpdatePendingDeutilization(pendingDeutilization_);

            emit WithdrawRequested(caller, receiver, owner, withdrawId, assets);
        }
        _checkStrategyStatus();

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestKey) external virtual {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        WithdrawRequest memory withdrawRequest = $.withdrawRequests[requestKey];

        // validate claim
        if (withdrawRequest.receiver == address(0)) {
            revert Errors.RequestAlreadyClaimed();
        }

        if (withdrawRequest.receiver != msg.sender) {
            revert Errors.UnauthorizedClaimer(msg.sender, withdrawRequest.receiver);
        }
        if (!_isClaimable(withdrawRequest)) {
            revert Errors.RequestNotExecuted();
        }

        $.assetsToClaim -= withdrawRequest.requestedAssets;
        IERC20(asset()).safeTransfer(msg.sender, withdrawRequest.requestedAssets);

        delete $.withdrawRequests[requestKey];

        emit Claim(msg.sender, requestKey, withdrawRequest.requestedAssets);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: account for pendings
    function totalAssets() public view virtual override returns (uint256 assets) {
        (, assets) = (utilizedAssets() + idleAssets()).trySub(totalPendingWithdraw());
    }

    function utilizedAssets() public view virtual returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        uint256 positionNetBalance = IOffChainPositionManager($.positionManager).positionNetBalance();
        uint256 productValueInAsset = $.oracle.convertTokenAmount(product(), asset(), productBalance);
        assets = productValueInAsset + positionNetBalance + $.assetsToWithdraw;
    }

    function idleAssets() public view virtual returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        (, assets) = assetBalance.trySub($.assetsToClaim + $.assetsToWithdraw);
    }

    // function withdrawingAssets() public view virtual returns (uint256 assets) {
    //     ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
    //     (, assets) = $.totalPendingWithdraw.trySub($.withdrawingFromHedge);
    // }

    function getWithdrawKey(address owner, uint128 counter) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (totalSupply() == 0) {
            return assets;
        }
        // calculate the amount of assets that will be utilized
        (, uint256 assetsToUtilize) = assets.trySub(totalPendingWithdraw());

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            uint256 feeAmount = assetsToUtilize.mulDiv($.entryCost, PRECISION, Math.Rounding.Ceil);
            assets -= feeAmount;
        }

        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (totalSupply() == 0) {
            return shares;
        }
        uint256 assets = _convertToAssets(shares, Math.Rounding.Ceil);

        // calculate the amount of assets that will be utilized
        (, uint256 assetsToUtilize) = assets.trySub(totalPendingWithdraw());

        // apply entry fee only to the portion of assets that will be utilized
        if (assetsToUtilize > 0) {
            // feeAmount / (assetsToUtilize + feeAmount) = entryCost
            // feeAmount = (assetsToUtilize * entryCost) / (1 - entryCost)
            uint256 _entryCost = $.entryCost;
            uint256 feeAmount = assetsToUtilize.mulDiv(_entryCost, PRECISION - _entryCost, Math.Rounding.Ceil);
            assets += feeAmount;
        }
        return assets;
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        // calc the amount of assets that can not be withdrawn via idle
        (, uint256 assetsToDeutilize) = assets.trySub(idleAssets());

        // apply exit fee to assets that should be deutilized and add exit fee amount the asset amount
        if (assetsToDeutilize > 0) {
            // feeAmount / assetsToDeutilize = exitCost
            uint256 feeAmount = assetsToDeutilize.mulDiv($.exitCost, PRECISION, Math.Rounding.Ceil);
            assets += feeAmount;
        }

        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);

        // calculate the amount of assets that will be deutilized
        (, uint256 assetsToDeutilize) = assets.trySub(idleAssets());

        // apply exit fee to the portion of assets that will be deutilized
        if (assetsToDeutilize > 0) {
            // feeAmount / (assetsToDeutilize - feeAmount) = exitCost
            // feeAmount = (assetsToDeutilize * exitCost) / (1 + exitCost)
            uint256 _exitCost = $.exitCost;
            uint256 feeAmount = assetsToDeutilize.mulDiv(_exitCost, PRECISION + _exitCost, Math.Rounding.Ceil);
            assets -= feeAmount;
        }

        return assets;
    }

    function isClaimable(bytes32 requestKey) public view returns (bool) {
        WithdrawRequest memory withdrawRequest = _getManagedBasisStrategyStorage().withdrawRequests[requestKey];
        return _isClaimable(withdrawRequest);
    }

    function _isClaimable(WithdrawRequest memory withdrawRequest) private view returns (bool) {
        return withdrawRequest.accRequestedWithdrawAssets <= _getManagedBasisStrategyStorage().proccessedWithdrawAssets;
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyOperator
        returns (bytes32 requestKey)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        // can only utilize when the strategy status is IDLE
        if ($.strategyStatus != StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8($.strategyStatus));
        }
        $.strategyStatus = StrategyStatus.DEPOSITING;
        emit UpdateStrategyStatus(StrategyStatus.DEPOSITING);

        // can only utilize when pending utilization is positive
        uint256 pendingUtilization_ = $.pendingUtilization;
        if (pendingUtilization_ == 0) {
            revert Errors.ZeroPendingUtilization();
        }

        // actual utilize amount is min of amount, idle assets and pending utilization
        uint256 idle = idleAssets();
        amount = amount > idle ? idle : amount;
        amount = amount > pendingUtilization_ ? pendingUtilization_ : amount;

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        bool success;
        if (swapType == SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), true, data);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = StrategyStatus.IDLE;
                emit UpdateStrategyStatus(StrategyStatus.IDLE);
                return bytes32(0);
            }
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        uint256 pendingIncreaseCollateral_ = $.pendingIncreaseCollateral;
        uint256 collateralDeltaAmount;
        if (pendingIncreaseCollateral_ > 0) {
            collateralDeltaAmount = pendingIncreaseCollateral_.mulDiv(amount, pendingUtilization_);
            IERC20(asset()).safeTransfer($.positionManager, collateralDeltaAmount);
            pendingIncreaseCollateral_ -= collateralDeltaAmount;
        }
        IOffChainPositionManager($.positionManager).adjustPosition(amountOut, collateralDeltaAmount, true);
        // $.spotExecutionPrice = amount.mulDiv(10 ** IERC20Metadata(product()).decimals(), amountOut, Math.Rounding.Ceil);
        $.pendingIncreaseCollateral = pendingIncreaseCollateral_;
        $.pendingUtilization = pendingUtilization_ - amount;

        emit UpdatePendingUtilization($.pendingUtilization);

        emit Utilize(msg.sender, amount, amountOut);
    }

    function deutilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyOperator
        returns (bytes32 requestKey)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        // can only deutilize when the strategy status is IDLE
        if ($.strategyStatus != StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8($.strategyStatus));
        }
        $.strategyStatus = StrategyStatus.WITHDRAWING;
        emit UpdateStrategyStatus(StrategyStatus.WITHDRAWING);

        uint256 productBalance = IERC20(product()).balanceOf(address(this));

        // actual deutilize amount is min of amount, product balance and pending deutilization
        uint256 _pendingDeutilization = pendingDeutilization();
        // @fixme don't need below one line
        amount = amount > productBalance ? productBalance : amount;
        amount = amount > _pendingDeutilization ? _pendingDeutilization : amount;

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        bool success;
        if (swapType == SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), false, data);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = StrategyStatus.IDLE;
                emit UpdateStrategyStatus(StrategyStatus.IDLE);
                return bytes32(0);
            }
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        // $.spotExecutionPrice = amountOut.mulDiv(10 ** IERC20Metadata(product()).decimals(), amount, Math.Rounding.Ceil);

        if ($.strategyStatus == StrategyStatus.WITHDRAWING) {
            $.assetsToWithdraw += amountOut;
        }

        IOffChainPositionManager($.positionManager).adjustPosition(amount, 0, false);

        emit Deutilize(msg.sender, amount, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION MANAGER CALLBACKS LOGIC
    //////////////////////////////////////////////////////////////*/

    // callback function dispatcher
    function afterAdjustPosition(PositionManagerCallbackParams memory params) external onlyPositionManager {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        StrategyStatus status = $.strategyStatus;
        if (status == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }
        if (params.isIncrease) {
            // TODO
            if (params.collateralDeltaAmount > 0) {
                // afterIncreasePositionCollateral callback
                if (params.isSuccess) {
                    _afterIncreasePositionCollateralSuccess(params, status);
                } else {
                    _afterIncreasePositionCollateralRevert(params, status);
                }
            }
            if (params.sizeDeltaInTokens > 0) {
                // afterIncreasePositionSize callback
                if (params.isSuccess) {
                    _afterIncreasePositionSizeSuccess(params, status);
                } else {
                    _afterIncreasePositionSizeRevert(params, status);
                }
            }
        } else {
            // TODO
            if (params.collateralDeltaAmount > 0) {
                // afterDecreasePositionCollateral callback
                if (params.isSuccess) {
                    _afterDecreasePositionCollateralSuccess(params, status);
                } else {
                    _afterDecreasePositionCollateralRevert(params, status);
                }
            }
            if (params.sizeDeltaInTokens > 0) {
                // afterDecreasePositionSize callback
                if (params.isSuccess) {
                    _afterDecreasePositionSizeSuccess(params, status);
                } else {
                    _afterDecreasePositionSizeRevert(params, status);
                }
            }
        }

        $.strategyStatus = StrategyStatus.IDLE;
        emit UpdateStrategyStatus(StrategyStatus.IDLE);

        _checkStrategyStatus();

        emit AfterAdjustPosition(
            params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease, params.isSuccess
        );
    }

    //TODO: accomodate for Chainlink interface
    function checkUpkeep(bytes calldata) public view virtual returns (bool upkeepNeeded, bytes memory performData) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        bool statusKeep;
        bool hedgeDeviation;
        bool decreaseCollateral;

        upkeepNeeded = _checkUpkeep();
        if ($.strategyStatus == StrategyStatus.NEED_KEEP) {
            statusKeep = true;
        }

        (uint256 hedgeDeviationInTokens, /* bool isIncrease */ ) = _checkHedgeDeviation();
        if (hedgeDeviationInTokens > 0) {
            hedgeDeviation = true;
        }

        uint256 pendingDecreaseCollateral_ = $.pendingDecreaseCollateral;
        if (pendingDecreaseCollateral_ > 0) {
            decreaseCollateral = true;
        }

        return (upkeepNeeded, abi.encode(statusKeep, hedgeDeviation, decreaseCollateral));
    }

    function _checkUpkeep() internal view virtual returns (bool upkeepNeeded) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        // when strategy is in operation, should return false
        if ($.strategyStatus != StrategyStatus.IDLE) {
            return false;
        }

        if ($.strategyStatus == StrategyStatus.NEED_KEEP) {
            return true;
        }

        (uint256 hedgeDeviationInTokens, /* bool isIncrease */ ) = _checkHedgeDeviation();
        if (hedgeDeviationInTokens > 0) {
            return true;
        }

        uint256 pendingDecreaseCollateral_ = $.pendingDecreaseCollateral;
        if (pendingDecreaseCollateral_ > 0) {
            return true;
        }

        return false;
    }

    //TODO: accomodate for Chainlink interface
    function performUpkeep(bytes calldata) public {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        StrategyStatus status = $.strategyStatus;

        if (status != StrategyStatus.NEED_KEEP && status != StrategyStatus.IDLE) {
            return;
        }

        // process withdraw requests with assetsToWithdraw first,
        // and then with idle assets
        $.assetsToWithdraw = _processWithdrawRequests($.assetsToWithdraw);
        _processWithdrawRequests(idleAssets());

        (uint256 hedgeDeviationInTokens, bool isIncrease) = _checkHedgeDeviation();
        uint256 pendingDecreaseCollateral_ = $.pendingDecreaseCollateral;
        if (hedgeDeviationInTokens > 0) {
            if (isIncrease) {
                IOffChainPositionManager($.positionManager).adjustPosition(hedgeDeviationInTokens, 0, true);
            } else {
                IOffChainPositionManager($.positionManager).adjustPosition(
                    hedgeDeviationInTokens, pendingDecreaseCollateral_, false
                );
            }
            $.strategyStatus = StrategyStatus.KEEPING;
            emit UpdateStrategyStatus(StrategyStatus.KEEPING);
        } else if (pendingDecreaseCollateral_ > 0) {
            IOffChainPositionManager($.positionManager).adjustPosition(0, pendingDecreaseCollateral_, false);
            $.strategyStatus = StrategyStatus.KEEPING;
            emit UpdateStrategyStatus(StrategyStatus.KEEPING);
        } else {
            _checkStrategyStatus();
        }
    }

    function _checkStrategyStatus() internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        bool upkeepNeeded = _checkUpkeep();
        if (upkeepNeeded) {
            $.strategyStatus = StrategyStatus.NEED_KEEP;
            emit UpdateStrategyStatus(StrategyStatus.NEED_KEEP);
        }
    }

    function _checkHedgeDeviation() internal view returns (uint256 hedgeDeviationInTokens, bool isIncrease) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 spotExposure = IERC20(product()).balanceOf(address(this));
        uint256 hedgeExposure = IOffChainPositionManager($.positionManager).positionSizeInTokens();
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return (0, false);
            } else {
                return (hedgeExposure, false);
            }
        }
        uint256 hedgeDeviation = hedgeExposure.mulDiv(PRECISION, spotExposure);
        if (hedgeDeviation > PRECISION + $.hedgeDeviationThreshold) {
            // strategy is overhedged, need to decrease position size
            isIncrease = false;
            hedgeDeviationInTokens = hedgeExposure - spotExposure;
        } else if (hedgeDeviation < PRECISION - $.hedgeDeviationThreshold) {
            // strategy is underhedged, need to increase position size
            isIncrease = true;
            hedgeDeviationInTokens = spotExposure - hedgeExposure;
        }
    }

    /// @dev process withdraw request
    /// Note: should be called whenever assets come to this vault
    /// including user's deposit and system's deutilizing
    ///
    /// @return remaining assets which goes to idle or assetsToWithdraw
    function _processWithdrawRequests(uint256 assets) private returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 _proccessedWithdrawAssets = $.proccessedWithdrawAssets;
        uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;

        // check if there is neccessarity to process withdraw requests
        if (_proccessedWithdrawAssets < _accRequestedWithdrawAssets) {
            uint256 remainingAssets;
            uint256 proccessedWithdrawAssetsAfter = _proccessedWithdrawAssets + assets;

            // if proccessedWithdrawAssets overshoots accRequestedWithdrawAssets,
            // then cap it by accRequestedWithdrawAssets
            // so that the remaining asset goes to idle
            if (proccessedWithdrawAssetsAfter > _accRequestedWithdrawAssets) {
                remainingAssets = proccessedWithdrawAssetsAfter - _accRequestedWithdrawAssets;
                proccessedWithdrawAssetsAfter = _accRequestedWithdrawAssets;
                assets = proccessedWithdrawAssetsAfter - _proccessedWithdrawAssets;
            }

            $.assetsToClaim += assets;
            $.proccessedWithdrawAssets = proccessedWithdrawAssetsAfter;

            return remainingAssets;
        }

        emit UpdatePendingDeutilization(pendingDeutilization());

        return assets;
    }

    function _afterIncreasePositionSizeSuccess(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal pure {
        // TODO: implement
    }

    function _afterIncreasePositionSizeRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal pure {
        // TODO: implement
    }

    function _afterDecreasePositionSizeSuccess(PositionManagerCallbackParams memory params, StrategyStatus status)
        internal
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if (status == StrategyStatus.WITHDRAWING) {
            uint256 indexPrecision = 10 ** uint256(IERC20Metadata(product()).decimals());
            uint256 sizeDeltaInAsset = params.executionPrice.mulDiv(params.sizeDeltaInTokens, indexPrecision);
            uint256 amountExecuted = sizeDeltaInAsset.mulDiv(PRECISION, $.targetLeverage);
            $.pendingDecreaseCollateral += amountExecuted;

            uint256 _assetsToWithdraw = $.assetsToWithdraw;
            // don't make remainingAssets go to idle because it has execution cost
            $.assetsToWithdraw = _processWithdrawRequests(_assetsToWithdraw);
        } else if (status == StrategyStatus.REBALANCING_DOWN) {
            //TODO: implement
            // processing rebalance request
        } else if (status == StrategyStatus.KEEPING) {
            // TODO: implement
            // processing keep request
        } else {
            revert Errors.InvalidStrategyStatus(uint8(status));
        }
    }

    function _afterDecreasePositionSizeRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal pure {
        // TODO: implement
    }

    function _afterIncreasePositionCollateralSuccess(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal pure {
        // TODO: implement
    }

    function _afterIncreasePositionCollateralRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal pure {
        // TODO: implement
    }

    function _afterDecreasePositionCollateralSuccess(PositionManagerCallbackParams memory params, StrategyStatus status)
        internal
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        IERC20(asset()).safeTransferFrom($.positionManager, address(this), params.collateralDeltaAmount);

        if (status == StrategyStatus.KEEPING) {
            // processing withdraw requests
            // don't increase idle asset by the remaining amount
            $.assetsToWithdraw += _processWithdrawRequests(params.collateralDeltaAmount);
            uint256 _pendingDecreaseCollateral = $.pendingDecreaseCollateral;
            (, $.pendingDecreaseCollateral) = _pendingDecreaseCollateral.trySub(params.collateralDeltaAmount);
        } else if (status == StrategyStatus.REBALANCING_DOWN) {
            // processing rebalance request
            // TODO:impelement
        } else {
            revert Errors.InvalidStrategyStatus(uint8(status));
        }
    }

    function _afterDecreasePositionCollateralRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal pure {
        // TODO implement
    }

    // function requestWipeStrategy(uint256 productAmount, SwapType swapType, bytes memory data) external onlyOwner {
    //     if (totalSupply() > 0) {
    //         revert();
    //     }

    //     ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

    //     if (swapType == SwapType.INCH_V6) {
    //         (, bool success) = InchAggregatorV6Logic.executeSwap(productAmount, product(), asset(), true, data);
    //         if (!success) {
    //             emit SwapFailed();
    //         }
    //     } else {
    //         // TODO: fallback swap
    //         revert Errors.UnsupportedSwapType();
    //     }
    //     uint256 positionSizeInTokens = IOffChainPositionManager($.positionManager).positionSizeInTokens();
    //     uint256 positionNetBalance = IOffChainPositionManager($.positionManager).positionNetBalance();
    //     IOffChainPositionManager($.positionManager).adjustPosition(positionSizeInTokens, positionNetBalance, false);
    // }

    // function wipeStrategy() external onlyOwner {
    //     ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
    //     address asset_ = asset();
    //     IERC20(asset_).safeTransferFrom($.positionManager, address(this), IERC20(asset_).balanceOf($.positionManager));
    //     IERC20(asset_).safeTransfer(msg.sender, IERC20(asset_).balanceOf(address(this)));
    // }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function oracle() external view returns (address) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return address($.oracle);
    }

    function positionManager() external view returns (address) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.positionManager;
    }

    function targetLeverage() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.targetLeverage;
    }

    function entryCost() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.entryCost;
    }

    function exitCost() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.exitCost;
    }

    function hedgeDeviationThreshold() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.hedgeDeviationThreshold;
    }

    function userDepositLimit() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.userDepositLimit;
    }

    function strategyDepositLimit() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.strategyDepostLimit;
    }

    function assetsToClaim() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.assetsToClaim;
    }

    function assetsToWithdraw() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.assetsToWithdraw;
    }

    function pendingUtilization() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingUtilization;
    }

    function pendingDeutilization() public view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 totalPendingWithdraw_ = totalPendingWithdraw();
        uint256 pendingDeutilizationInAsset_ =
            totalPendingWithdraw_.mulDiv($.targetLeverage, PRECISION + $.targetLeverage);
        uint256 pendingDeutilization_ = $.oracle.convertTokenAmount(asset(), product(), pendingDeutilizationInAsset_);
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        pendingDeutilization_ = pendingDeutilization_ > productBalance ? productBalance : pendingDeutilization_;
        return pendingDeutilization_;
    }

    function pendingIncreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingIncreaseCollateral;
    }

    function pendingDecreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingDecreaseCollateral;
    }

    function totalPendingWithdraw() public view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.accRequestedWithdrawAssets - $.proccessedWithdrawAssets;
    }

    function strategyStatus() external view returns (StrategyStatus) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.strategyStatus;
    }

    function requestCounter(address owner) external view returns (uint128) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.requestCounter[owner];
    }

    function withdrawRequests(bytes32 requestKey) external view returns (WithdrawRequest memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawRequests[requestKey];
    }

    function accRequestedWithdrawAssets() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().accRequestedWithdrawAssets;
    }

    function proccessedWithdrawAssets() external view returns (uint256) {
        return _getManagedBasisStrategyStorage().proccessedWithdrawAssets;
    }
}
