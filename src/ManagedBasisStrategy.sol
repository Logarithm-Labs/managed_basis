// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOffChainPositionManager} from "src/interfaces/IOffChainPositionManager.sol";
import "src/interfaces/IManagedBasisStrategy.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAggregationRouterV6} from "src/externals/1inch/interfaces/IAggregationRouterV6.sol";

import {InchAggregatorV6Logic} from "src/libraries/InchAggregatorV6Logic.sol";

import {IOracle} from "src/interfaces/IOracle.sol";

import {Errors} from "src/libraries/Errors.sol";
import {FactoryDeployable} from "src/common/FactoryDeployable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";

import {console2 as console} from "forge-std/console2.sol";

contract ManagedBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
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

    struct WithdrawState {
        uint256 requestTimestamp;
        uint256 requestedAmount;
        uint256 executedFromSpot;
        uint256 executedFromIdle;
        uint256 executedFromHedge;
        uint256 executionCost;
        address receiver;
        bool isExecuted;
        bool isClaimed;
    }

    struct ManagedBasisStrategyStorage {
        IOracle oracle;
        address operator;
        address positionManager;
        uint256 targetLeverage;
        uint256 entryCost;
        uint256 exitCost;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        uint256 assetsToClaim; // asset balance that is ready to claim
        uint256 assetsToWithdraw; // asset balance that is processed for withdrawals
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 totalPendingWithdraw; // total amount of asset that remains to be withdrawn
        uint256 withdrawnFromSpot; // asset amount withdrawn from spot that is not yet processed
        uint256 withdrawnFromIdle; // asset amount withdrawn from idle that is not yet processed
        uint256 withdrawingFromHedge; // asset amount that is ready to be withdrawn from hedge
        uint256 idleImbalance; // imbalance in idle assets between spot and hedge due to withdraws from idle
        uint256 spotExecutionPrice;
        bytes32[] activeWithdrawRequests;
        bytes32[] closedWithdrawRequests;
        StrategyStatus strategyStatus;
        mapping(address => uint128) requestCounter;
        mapping(bytes32 => WithdrawState) withdrawRequests;
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
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequest(
        address indexed caller, address indexed receiver, address indexed owner, bytes32 withdrawId, uint256 amount
    );

    event ExecuteWithdraw(bytes32 requestId, uint256 requestedAmount, uint256 executedAmount);

    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    event UpdatePendingUtilization(uint256 amount);

    event UpdatePendingDeutilization(uint256 amount);

    event Utilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    event Deutilize(address indexed caller, uint256 amountIn, uint256 amountOut);

    event AfterAdjustPosition(
        uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease, bool isSuccess
    );

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

        uint256 totalPendingWithdraw_ = $.totalPendingWithdraw;
        if (totalPendingWithdraw_ >= assets) {
            // if total pending withdraw is greater than assets we reallocate all deposited assets for withdrawal
            totalPendingWithdraw_ -= assets;

            uint256 pendingDeutilizationInAsset_ =
                totalPendingWithdraw_.mulDiv($.targetLeverage, PRECISION + $.targetLeverage);
            $.pendingDeutilization = $.oracle.convertTokenAmount(asset(), product(), pendingDeutilizationInAsset_);
            $.assetsToWithdraw += assets;

            emit UpdatePendingDeutilization($.pendingDeutilization);
        } else {
            uint256 assetsToDeposit = assets - totalPendingWithdraw_;
            uint256 assetsToHedge = assetsToDeposit.mulDiv(PRECISION, PRECISION + $.targetLeverage);
            uint256 assetsToSpot = assetsToDeposit - assetsToHedge;
            if (totalPendingWithdraw_ > 0) {
                // if there are some pending withdrawals which are less then deposited assets we reallocate assets
                // to cover pending withdrawals and increase pending utilization for remaining assets
                $.assetsToWithdraw += totalPendingWithdraw_;
                $.totalPendingWithdraw = 0;
                $.pendingDeutilization = 0;
                emit UpdatePendingDeutilization(0);
            }
            $.pendingUtilization += assetsToSpot;
            $.pendingIncreaseCollateral += assetsToHedge;

            emit UpdatePendingUtilization($.pendingUtilization);
        }

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

            IERC20(asset()).safeTransfer(receiver, assets);
        } else {
            uint128 counter = $.requestCounter[owner];

            bytes32 withdrawId = getWithdrawId(owner, counter);
            $.withdrawRequests[withdrawId] = WithdrawState({
                requestTimestamp: uint128(block.timestamp),
                requestedAmount: assets,
                executedFromSpot: 0,
                executedFromIdle: 0,
                executedFromHedge: 0,
                executionCost: 0,
                receiver: receiver,
                isExecuted: false,
                isClaimed: false
            });

            // if all idle assets are withdrawn, set pending states to zero
            $.pendingUtilization = 0;
            $.pendingIncreaseCollateral = 0;
            $.withdrawnFromIdle += idle;
            emit UpdatePendingUtilization(0);

            uint256 totalPendingWithdraw_ = $.totalPendingWithdraw + (assets - idle);
            uint256 pendingDeutilizationInAsset_ =
                totalPendingWithdraw_.mulDiv($.targetLeverage, PRECISION + $.targetLeverage);
            $.pendingDeutilization = $.oracle.convertTokenAmount(asset(), product(), pendingDeutilizationInAsset_);
            $.totalPendingWithdraw = totalPendingWithdraw_;
            $.assetsToWithdraw += idle;
            $.activeWithdrawRequests.push(withdrawId);
            $.requestCounter[owner]++;

            emit WithdrawRequest(caller, receiver, owner, withdrawId, assets);
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestId) external virtual {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        WithdrawState memory requestData = $.withdrawRequests[requestId];

        // validate claim
        if (requestData.receiver != msg.sender) {
            revert Errors.UnauthorizedClaimer(msg.sender, requestData.receiver);
        }
        if (!requestData.isExecuted) {
            revert Errors.RequestNotExecuted();
        }
        if (requestData.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        uint256 totalExecuted =
            requestData.executedFromSpot + requestData.executedFromIdle + requestData.executedFromHedge;
        $.assetsToClaim -= totalExecuted;
        $.withdrawRequests[requestId].isClaimed = true;
        IERC20 asset_ = IERC20(asset());
        asset_.safeTransfer(msg.sender, totalExecuted);

        delete $.withdrawRequests[requestId];

        emit Claim(msg.sender, requestId, totalExecuted);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // TODO: account for pendings
    function totalAssets() public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return utilizedAssets() + idleAssets() - ($.totalPendingWithdraw + $.withdrawingFromHedge);
    }

    function utilizedAssets() public view virtual returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        uint256 positionNetBalance = IOffChainPositionManager($.positionManager).positionNetBalance();
        uint256 productValueInAsset = $.oracle.convertTokenAmount(product(), asset(), productBalance);
        return productValueInAsset + positionNetBalance;
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

    function getWithdrawId(address owner, uint128 counter) public view virtual returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (totalSupply() == 0) {
            return assets;
        }
        uint256 baseShares = convertToShares(assets);
        return baseShares.mulDiv(PRECISION - $.entryCost, PRECISION);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (totalSupply() == 0) {
            return shares;
        }
        uint256 baseAssets = convertToAssets(shares);
        return baseAssets.mulDiv(PRECISION, PRECISION - $.entryCost);
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyOperator
        returns (bytes32 requestId)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        // can only utilize when the strategy status is IDLE
        if ($.strategyStatus != StrategyStatus.IDLE) {
            revert Errors.StatusNotIdle();
        }
        $.strategyStatus = StrategyStatus.DEPOSITING;

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
        $.spotExecutionPrice = amount.mulDiv(10 ** IERC20Metadata(product()).decimals(), amountOut, Math.Rounding.Ceil);
        $.pendingIncreaseCollateral = pendingIncreaseCollateral_;
        $.pendingUtilization = pendingUtilization_ - amount;

        emit Utilize(msg.sender, amount, amountOut);
    }

    function deutilize(uint256 amount, SwapType swapType, bytes calldata data)
        public
        virtual
        onlyOperator
        returns (bytes32 requestId)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        // can only deutilize when the strategy status is IDLE
        if ($.strategyStatus != StrategyStatus.IDLE) {
            revert Errors.StatusNotIdle();
        }
        $.strategyStatus = StrategyStatus.WITHDRAWING;
        uint256 productBalance = IERC20(product()).balanceOf(address(this));

        // actual deutilize amount is min of amount, product balance and pending deutilization
        amount = amount > productBalance ? productBalance : amount;
        amount = amount > $.pendingDeutilization ? $.pendingDeutilization : amount;

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
                return bytes32(0);
            }
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        $.spotExecutionPrice = amountOut.mulDiv(10 ** IERC20Metadata(product()).decimals(), amount, Math.Rounding.Ceil);

        if ($.strategyStatus == StrategyStatus.WITHDRAWING) {
            // processing withdraw requests
            $.assetsToWithdraw += amountOut;
            $.totalPendingWithdraw -= amountOut;
            $.withdrawnFromSpot += amountOut;
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
        if (status == StrategyStatus.KEEPING) {
            // TODO
        } else {
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
            // TODO: check hedge deviation
            // checkUpkeep();
            // if true set status to NEED_KEEP
            // put it in separate function performUpkeep()
            //
            // if (hedgeDeviation > theshold) positionManager.adjustPosition(hedgeDeviation, 0, false)
            // else if () ositionManager.adjustPosition(hedgeDeviation, 0, true)
            // else $.strategyStatus = StrategyStatus.IDLE;
            // $.strategyStatus = StrategyStatus.IDLE;
        }

        emit AfterAdjustPosition(
            params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease, params.isSuccess
        );
    }

    //TODO: accomodate for Chainlink interface
    function checkUpkeep() public view returns (bool) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if ($.strategyStatus == StrategyStatus.NEED_KEEP) {
            return true;
        } else {
            return false;
        }
    }

    //TODO: accomodate for Chainlink interface
    function perfromUpkeep() public {
        // TODO: implement
    }

    function _afterIncreasePositionSizeSuccess(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal {
        // TODO: implement
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.strategyStatus = StrategyStatus.IDLE;
    }

    function _afterIncreasePositionSizeRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal {
        // TODO: implement
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.strategyStatus = StrategyStatus.IDLE;
    }

    function _afterDecreasePositionSizeSuccess(PositionManagerCallbackParams memory params, StrategyStatus status)
        internal
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if (status == StrategyStatus.WITHDRAWING) {
            // processing withdraw requests
            // uint256 calculatedLeverage = ...
            // uint256 withdrawLeverage;
            // if (calculatedLeverage > $.maxLeverage) {
            //     withdrawLeverage = $.maxLeverage;
            // } else if (calculatedLeverage < $.minLeverage) {
            //     withdrawLeverage = $.minLeverage;
            // } else {
            //     withdrawLeverage = calculatedLeverage;
            // }
            uint256 indexPrecision = 10 ** uint256(IERC20Metadata(product()).decimals());
            uint256 sizeDeltaInAsset = params.executionPrice.mulDiv(params.sizeDeltaInTokens, indexPrecision);
            uint256 amountExecuted = sizeDeltaInAsset.mulDiv(PRECISION, $.targetLeverage);
            // amountExecuted = amountExecuted > totalPendingWithdraw_ ? totalPendingWithdraw_ : amountExecuted;

            // calculate exit cost
            uint256 executionCost;
            if ($.exitCost == 0) {
                // if no exit cost use manual calculation
                int256 executionSpread = int256(params.executionPrice) - int256($.spotExecutionPrice);
                int256 executionCost_ = executionSpread > 0
                    ? (uint256(executionSpread).mulDiv(params.sizeDeltaInTokens, indexPrecision)).toInt256()
                    : -(uint256(-executionSpread).mulDiv(params.sizeDeltaInTokens, indexPrecision)).toInt256();
                executionCost_ += params.executionCost.toInt256();
                executionCost = executionCost_ > int256(0) ? uint256(executionCost_) : uint256(0);
            } else {
                executionCost = sizeDeltaInAsset.mulDiv($.exitCost, PRECISION);
            }
            // totalPendingWithdraw_ -= executionCost;
            // uint256 withdrawingFromHedge_ = $.withdrawingFromHedge;
            // (, uint256 withdrawingAssets_) = totalPendingWithdraw_.trySub(withdrawingFromHedge_);

            uint256 totalPendingWithdraw_ = $.totalPendingWithdraw;
            uint256 withdrawnFromSpot_ = $.withdrawnFromSpot;
            uint256 withdrawnFromIdle_ = $.withdrawnFromIdle;
            uint256 withdrawingFromHedge_ = $.withdrawingFromHedge;
            uint256 pendingDecreaseCollateral_ = $.pendingDecreaseCollateral;
            if (amountExecuted + executionCost > totalPendingWithdraw_) {
                // if we overshoot with amount executed, reduce amount executed and execution cost proportionally
                uint256 executionDelta = amountExecuted + executionCost - totalPendingWithdraw_;
                uint256 deltaShare = executionDelta.mulDiv(PRECISION, amountExecuted + executionCost);
                amountExecuted = amountExecuted.mulDiv(PRECISION - deltaShare, PRECISION);
                executionCost = executionCost.mulDiv(PRECISION - deltaShare, PRECISION);

                // dust goes to costs
                executionCost = totalPendingWithdraw_ - amountExecuted;
            }
            uint256 amountAvailable = withdrawnFromSpot_ + withdrawnFromIdle_ + amountExecuted + executionCost;
            // as all amountAvailable will be processed, we can update the totalPendingWithdrawState
            // uint256 totalWithdraw = $.totalPendingWithdraw;
            // (, totalWithdraw) = totalWithdraw.trySub(amountExecuted + executionCost);
            // $.totalPendingWithdraw = totalWithdraw;
            // console.log("totalPendingWithdraw: ", $.totalPendingWithdraw);

            uint256 index;

            while (amountAvailable > 0 && index < $.activeWithdrawRequests.length) {
                bytes32 requestId0 = $.activeWithdrawRequests[index];
                WithdrawState memory request0 = $.withdrawRequests[requestId0];
                uint256 executedAmount = request0.executedFromSpot + request0.executedFromIdle
                    + request0.executedFromHedge + request0.executionCost;
                uint256 remainingAmount = request0.requestedAmount - executedAmount;
                if (amountAvailable >= remainingAmount) {
                    // remaining amount is enough fully cover current request

                    // allocation of withdrawn assets rounded to floor
                    uint256 allocationOfSpot = withdrawnFromSpot_.mulDiv(remainingAmount, amountAvailable);
                    uint256 allocationOfIdle = withdrawnFromIdle_.mulDiv(remainingAmount, amountAvailable);
                    uint256 allocationOfHedge = amountExecuted.mulDiv(remainingAmount, amountAvailable);
                    uint256 allocationOfCost = executionCost.mulDiv(remainingAmount, amountAvailable);
                    // dust goes to costs
                    uint256 dust =
                        remainingAmount - (allocationOfSpot + allocationOfIdle + allocationOfHedge + allocationOfCost);

                    request0.executedFromSpot += allocationOfSpot;
                    request0.executedFromIdle += allocationOfIdle;
                    request0.executedFromHedge += allocationOfHedge;
                    request0.executionCost += (allocationOfCost + dust);

                    amountAvailable -= (remainingAmount - dust);
                    pendingDecreaseCollateral_ += request0.executedFromHedge;

                    withdrawnFromSpot_ -= allocationOfSpot;
                    withdrawnFromIdle_ -= allocationOfIdle;
                    amountExecuted -= allocationOfHedge;
                    executionCost -= allocationOfCost;

                    totalPendingWithdraw_ -= (allocationOfHedge + allocationOfCost);
                    withdrawingFromHedge_ += allocationOfHedge;
                    // if requested amount is fulfilled push to it closed
                    $.closedWithdrawRequests.push(requestId0);

                    index++;
                } else {
                    // redistribute remaining allocations

                    request0.executedFromSpot += withdrawnFromSpot_;
                    request0.executedFromIdle += withdrawnFromIdle_;
                    request0.executedFromHedge += amountExecuted;
                    request0.executionCost += executionCost;

                    totalPendingWithdraw_ -= (amountExecuted + executionCost);
                    withdrawingFromHedge_ += amountExecuted;

                    amountAvailable = 0;
                }

                // update request storage state
                $.withdrawRequests[requestId0] = request0;
            }

            // recalculate pendingDeutilization based on the new oracle price
            uint256 pendingDeutilizationInAsset_ =
                totalPendingWithdraw_.mulDiv($.targetLeverage, PRECISION + $.targetLeverage);
            $.pendingDeutilization = $.oracle.convertTokenAmount(asset(), product(), pendingDeutilizationInAsset_);

            // update global state
            $.withdrawnFromSpot = 0;
            $.withdrawnFromIdle = 0;
            $.pendingDecreaseCollateral = pendingDecreaseCollateral_;
            $.withdrawingFromHedge = withdrawingFromHedge_;
            $.totalPendingWithdraw = totalPendingWithdraw_;

            // remove fulfilled requests from activeWithdrawRequests based on index
            if (index > 0) {
                if (index < $.activeWithdrawRequests.length) {
                    for (uint256 i = 0; i < $.activeWithdrawRequests.length - index; i++) {
                        $.activeWithdrawRequests[i] = $.activeWithdrawRequests[i + index];
                    }
                    for (uint256 j = 0; j < index; j++) {
                        $.activeWithdrawRequests.pop();
                    }
                } else {
                    delete $.activeWithdrawRequests;
                }

                // request decrease collateral from position manager if there are any fulfilled requests
                IOffChainPositionManager($.positionManager).adjustPosition(0, pendingDecreaseCollateral_, false);
            } else {
                $.strategyStatus = StrategyStatus.IDLE;
            }
        } else if (status == StrategyStatus.REBALANCING_DOWN) {
            // processing rebalance request
            $.strategyStatus = StrategyStatus.IDLE;
        } else {
            revert Errors.NotDeutilizing();
        }
    }

    function _afterDecreasePositionSizeRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal {
        // TODO: implement
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.strategyStatus = StrategyStatus.IDLE;
    }

    function _afterIncreasePositionCollateralSuccess(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal {
        // TODO implement
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.strategyStatus = StrategyStatus.IDLE;
    }

    function _afterIncreasePositionCollateralRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal {
        // TODO implement
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.strategyStatus = StrategyStatus.IDLE;
    }

    function _afterDecreasePositionCollateralSuccess(PositionManagerCallbackParams memory params, StrategyStatus status)
        internal
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if (status == StrategyStatus.WITHDRAWING) {
            // processing withdraw requests
            uint256 assetsToWithdraw_ = $.assetsToWithdraw + params.collateralDeltaAmount;
            IERC20(asset()).safeTransferFrom($.positionManager, address(this), params.collateralDeltaAmount);
            uint256 totalAvailableAmount = $.assetsToWithdraw + params.collateralDeltaAmount;
            uint256 processedAssetAmount;
            uint256 index;
            while (totalAvailableAmount > 0 && index < $.closedWithdrawRequests.length) {
                // process closed requests one by one
                bytes32 withdrawId = $.closedWithdrawRequests[index];
                WithdrawState storage request0 = $.withdrawRequests[withdrawId];

                uint256 executionAmount = request0.requestedAmount - request0.executionCost;
                if (executionAmount <= totalAvailableAmount) {
                    // if there is enough processed asset to cover requested amount minus execution cost,  mark as executed
                    request0.isExecuted = true;
                    processedAssetAmount += executionAmount;

                    index++;
                    totalAvailableAmount -= executionAmount;

                    emit ExecuteWithdraw(withdrawId, request0.requestedAmount, executionAmount);
                } else {
                    // if there is not enough asset to process withdraw exit the loop
                    totalAvailableAmount = 0;
                }
            }

            // update global state

            $.assetsToClaim += processedAssetAmount;
            $.assetsToWithdraw = assetsToWithdraw_ - processedAssetAmount;
            $.pendingDecreaseCollateral -= params.collateralDeltaAmount;
            $.withdrawingFromHedge -= params.collateralDeltaAmount;

            // remove executed requests from closedWithdrawRequests based on index
            if (index > 0) {
                for (uint256 i = 0; i < $.closedWithdrawRequests.length - index; i++) {
                    $.closedWithdrawRequests[i] = $.closedWithdrawRequests[i + index];
                }
                for (uint256 j = 0; j < index; j++) {
                    $.closedWithdrawRequests.pop();
                }
            }
            $.strategyStatus = StrategyStatus.IDLE;
        } else if (status == StrategyStatus.REBALANCING_DOWN) {
            // processing rebalance request
            // TODO
            $.strategyStatus = StrategyStatus.IDLE;
        } else {
            revert Errors.NotDeutilizing();
        }
    }

    function _afterDecreasePositionCollateralRevert(
        PositionManagerCallbackParams memory, /* params */
        StrategyStatus /* status */
    ) internal {
        // TODO implement
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        $.strategyStatus = StrategyStatus.IDLE;
    }

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

    function pendingDeutilization() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingDeutilization;
    }

    function pendingIncreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingIncreaseCollateral;
    }

    function pendingDecreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingDecreaseCollateral;
    }

    function totalPendingWithdraw() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.totalPendingWithdraw;
    }

    function withdrawingFromHedge() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawingFromHedge;
    }

    function withdrawnFromSpot() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawnFromSpot;
    }

    function withdrawnFromIdle() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawnFromIdle;
    }

    function activeWithdrawRequests() external view returns (bytes32[] memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.activeWithdrawRequests;
    }

    function activeWithdrawRequests(uint256 index) external view returns (bytes32) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.activeWithdrawRequests[index];
    }

    function closedWithdrawRequests() external view returns (bytes32[] memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.closedWithdrawRequests;
    }

    function closedWithdrawRequests(uint256 index) external view returns (bytes32) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.closedWithdrawRequests[index];
    }

    function strategyStatus() external view returns (StrategyStatus) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.strategyStatus;
    }

    function requestCounter(address owner) external view returns (uint128) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.requestCounter[owner];
    }

    function withdrawRequests(bytes32 requestId) external view returns (WithdrawState memory) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.withdrawRequests[requestId];
    }
}
