// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IManagedBasisCallbackReceiver} from "src/interfaces/IManagedBasisCallbackReceiver.sol";
import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {InchAggregatorV6Logic} from "src/libraries/logic/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/ManualSwapLogic.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";

import {IOracle} from "src/interfaces/IOracle.sol";

import {Errors} from "src/libraries/utils/Errors.sol";
import {FactoryDeployable} from "src/common/FactoryDeployable.sol";
import {LogBaseVaultUpgradeable} from "src/common/LogBaseVaultUpgradeable.sol";

import {console2 as console} from "forge-std/console2.sol";

contract AccumulatedBasisStrategy is UUPSUpgradeable, LogBaseVaultUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct WithdrawRequest {
        bool isClaimed;
        address receiver;
        uint256 requestedAssets;
        uint256 accRequestedWithdrawAssets;
    }

    struct ManagedBasisStrategyStorage {
        IOracle oracle;
        address operator;
        address forwarder;
        address positionManager;
        uint256 targetLeverage;
        uint256 safeMarginLeverage;
        uint256 maxLeverage;
        uint256 minLeverage;
        uint256 entryCost;
        uint256 exitCost;
        uint256 hedgeDeviationThreshold;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        uint256 assetsToClaim; // asset balance that is ready to claim
        uint256 assetsToWithdraw; // asset balance that is processed for withdrawals
        uint256 pendingUtilizedProducts;
        uint256 pendingDeutilizedAssets;
        // uint256 pendingUtilization;
        // uint256 pendingDeutilization;
        // uint256 pendingIncreaseCollateral;
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
        DataTypes.StrategyStatus strategyStatus;
        mapping(address => uint128) requestCounter;
        // mapping(bytes32 => WithdrawState) withdrawRequests;
        mapping(bytes32 => WithdrawRequest) withdrawRequests;
        // manual swap
        mapping(address => bool) isSwapPool;
        address[] productToAssetSwapPath;
        address[] assetToProductSwapPath;
        DataTypes.PositionManagerPayload adjustmentRequest;
    }
    // mapping(bytes32 => DataTypes.PositionManagerPayload) positionRequests;

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
        string memory name,
        string memory symbol,
        address _asset,
        address _product,
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage,
        uint256 _entryCost,
        uint256 _exitCost,
        address[] calldata _assetToProductSwapPath
    ) external initializer {
        __LogBaseVault_init(IERC20(_asset), IERC20(_product), name, symbol);
        __Ownable_init(msg.sender);
        __ManagedBasisStrategy_init(
            _asset,
            _product,
            _oracle,
            _operator,
            _targetLeverage,
            _minLeverage,
            _maxLeverage,
            _safeMarginLeverage,
            _entryCost,
            _exitCost,
            _assetToProductSwapPath
        );
    }

    function __ManagedBasisStrategy_init(
        address _asset,
        address _product,
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage,
        uint256 _entryCost,
        uint256 _exitCost,
        address[] calldata _assetToProductSwapPath
    ) public initializer {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        // validation oracle
        if (IOracle(_oracle).getAssetPrice(_asset) == 0 || IOracle(_oracle).getAssetPrice(_product) == 0) revert();
        $.oracle = IOracle(_oracle);
        $.operator = _operator;
        $.entryCost = _entryCost;
        $.exitCost = _exitCost;
        $.targetLeverage = _targetLeverage;
        $.minLeverage = _minLeverage;
        $.maxLeverage = _maxLeverage;
        $.safeMarginLeverage = _safeMarginLeverage;
        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        $.hedgeDeviationThreshold = 1e16; // 1%
        _setManualSwapPath(_assetToProductSwapPath);
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

    event AfterAdjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    event UpdateStrategyStatus(DataTypes.StrategyStatus status);

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

    function setForwarder(address _forwarder) external onlyOwner {
        if (_forwarder == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getManagedBasisStrategyStorage().forwarder = _forwarder;
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
        IERC20 _asset = IERC20(asset());
        _asset.safeTransferFrom(caller, address(this), assets);

        _processWithdrawRequests(idleAssets());

        emit UpdatePendingUtilization(
            _pendingUtilization(idleAssets(), _getManagedBasisStrategyStorage().targetLeverage)
        );

        // _checkStrategyStatus();
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    // @review Numa:
    // in withdraw workflow we should try to accomodate for the specifi workflow of priority withdraws
    // the idea is that for our meta strategies (notional reversion strategies with aave, portfolio strategies that
    // rebalance their capital between different base strategies, etc) we should be able to prioritize their withdrawals
    // and put them in the begining of the queue.
    //
    // I was thinking that it can be done via specifi priorityWithdraw() / priorityRedeem() functions that would have
    // a different logic then a common withdraw() / redeem(). Only contracts, that a registeres in some sort of factory contract
    // as Logarithm contracts can access the priorityWithdraw workflow.
    //
    // In your accum withdraw workflow this can potentially be done by creating a separate accumulator for priority withdraws.
    // When processWithdrawRequests happen we can first try to fill in priority witdraw requests and only switch to regular
    // withdraw requests only when all priority withdraws are completed

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
            IERC20(asset()).safeTransfer(receiver, assets);

            emit UpdatePendingUtilization(_pendingUtilization(idle - assets, $.targetLeverage));
        } else {
            $.assetsToClaim += idle;
            emit UpdatePendingUtilization(0);

            uint256 pendingWithdraw = assets - idle;

            uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;
            _accRequestedWithdrawAssets += pendingWithdraw;
            $.accRequestedWithdrawAssets = _accRequestedWithdrawAssets;

            uint128 counter = $.requestCounter[owner];
            bytes32 withdrawId = getWithdrawKey(owner, counter);
            $.withdrawRequests[withdrawId] = WithdrawRequest({
                isClaimed: false,
                receiver: receiver,
                requestedAssets: assets,
                accRequestedWithdrawAssets: _accRequestedWithdrawAssets
            });

            $.requestCounter[owner]++;

            emit UpdatePendingDeutilization(pendingDeutilization());

            emit WithdrawRequested(caller, receiver, owner, withdrawId, assets);
        }
        // _checkStrategyStatus();

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function claim(bytes32 requestKey) external virtual {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        WithdrawRequest memory withdrawRequest = $.withdrawRequests[requestKey];

        // @review Numa:
        // I would prefer to keep all hisotrical withdraw Ids in storage without deleting them for transparrency purposes
        // We can validate if the withdrawId was claime by adding isClaimed variable to the WithdrawRequest struct
        // and chage it to true if the withdraw was claimed

        // validate claim
        if (withdrawRequest.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }
        if (withdrawRequest.receiver != msg.sender) {
            revert Errors.UnauthorizedClaimer(msg.sender, withdrawRequest.receiver);
        }
        (bool claimbale, bool isLast) = _isWithdrawRequestExecuted(withdrawRequest);
        if (!claimbale) {
            revert Errors.RequestNotExecuted();
        }

        withdrawRequest.isClaimed = true;

        // separate workflow for last redeem
        uint256 executedAmount;
        if (isLast) {
            executedAmount = withdrawRequest.requestedAssets
                - (withdrawRequest.accRequestedWithdrawAssets - $.proccessedWithdrawAssets);
            $.proccessedWithdrawAssets = $.accRequestedWithdrawAssets;
            $.pendingDecreaseCollateral = 0;
        } else {
            executedAmount = withdrawRequest.requestedAssets;
        }

        $.assetsToClaim -= executedAmount;
        IERC20(asset()).safeTransfer(msg.sender, executedAmount);

        $.withdrawRequests[requestKey] = withdrawRequest;

        emit Claim(msg.sender, requestKey, executedAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNTING LOGIC
    //////////////////////////////////////////////////////////////*/

    // @review Numa. When during processWithdrawRequests() we convert $.assetsToWithdraw to $.assetsToClaim totalAssets()
    // will stay the same.
    // idleAssets() will stay the same as $.assetsToWithdraw just migrates to $.assetsToClaim
    // totalPendingWithdaw() will stay the same as $.totalPendingWithdraw would be set to zero and $.proccessedWithdrawAssets
    // would be increase by $.totalAssetsToWithdraw
    function totalAssets() public view virtual override returns (uint256 assets) {
        (, assets) = (utilizedAssets() + idleAssets()).trySub(totalPendingWithdraw());
    }

    // @review Numa: why do we have $.assetsToWithdraw in utilizedAssets?
    function utilizedAssets() public view virtual returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        uint256 positionNetBalance = IPositionManager($.positionManager).positionNetBalance();
        uint256 productValueInAsset = $.oracle.convertTokenAmount(product(), asset(), productBalance);
        assets = productValueInAsset + positionNetBalance; /*  + $.assetsToWithdraw */
    }

    // @review Numa: there should be no scenarios where ($.assetsToClaim + $.assetsToWithdraw) > assetBalance
    // as we only increase this state variables where asset hits the strategy address, thus should remove trySub
    function idleAssets() public view virtual returns (uint256 assets) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 assetBalance = IERC20(asset()).balanceOf(address(this));
        assets = assetBalance - ($.assetsToClaim + $.assetsToWithdraw);
    }

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
        (bool claimable,) = _isWithdrawRequestExecuted(withdrawRequest);
        return claimable && !withdrawRequest.isClaimed;
    }

    function _isWithdrawRequestExecuted(WithdrawRequest memory withdrawRequest)
        private
        view
        returns (bool claimable, bool isLast)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 _proccessedWithdrawAssets = $.proccessedWithdrawAssets;

        // separate worflow for last withdraw
        // check if current withdrawRequest is last withdraw
        if (totalSupply() == 0 && withdrawRequest.accRequestedWithdrawAssets == $.accRequestedWithdrawAssets) {
            isLast = true;
        }
        if (isLast) {
            // last withdraw is claimable when deutilization is complete
            claimable = pendingDeutilization() == 0 && $.strategyStatus == DataTypes.StrategyStatus.IDLE;
        } else {
            claimable = withdrawRequest.accRequestedWithdrawAssets <= _proccessedWithdrawAssets;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev utilize asset
    /// Note: should be called when upkeep is not needed
    ///
    /// @param amount is the asset value to be utilized
    /// @param swapType is the swap type of inch or manual
    /// @param data is the data used in inch
    function utilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata data) public virtual onlyOperator {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        (bool upkeepNeeded, bytes memory performData) = checkUpkeep(bytes(""));
        if (upkeepNeeded) {
            _performUpkeep(performData);
            return;
        }

        DataTypes.StrategyStatus strategyStatus_ = $.strategyStatus;

        // can only utilize when the strategy status is IDLE
        if (strategyStatus_ != DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(strategyStatus_));
        }

        uint256 idle = idleAssets();
        uint256 _targetLeverage = $.targetLeverage;

        // actual utilize amount is min of amount, idle assets and pending utilization
        uint256 pendingUtilization_ = _pendingUtilization(idle, _targetLeverage);
        if (pendingUtilization_ == 0) {
            revert Errors.ZeroPendingUtilization();
        }
        // @note dont need to check because always pendingUtilization_ < idle
        // amount = amount > idle ? idle : amount;
        amount = amount > pendingUtilization_ ? pendingUtilization_ : amount;

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        bool success;
        if (swapType == DataTypes.SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), true, data);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = DataTypes.StrategyStatus.IDLE;
                emit UpdateStrategyStatus(DataTypes.StrategyStatus.IDLE);
                return;
            }
            $.pendingUtilizedProducts = amountOut;
        } else if (swapType == DataTypes.SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, $.assetToProductSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        uint256 pendingIncreaseCollateral_ = _pendingIncreaseCollateral(idle, _targetLeverage);
        uint256 collateralDeltaAmount;
        if (pendingIncreaseCollateral_ > 0) {
            collateralDeltaAmount = pendingIncreaseCollateral_.mulDiv(amount, pendingUtilization_);
            IERC20(asset()).safeTransfer($.positionManager, collateralDeltaAmount);
        }
        _adjustPosition($.positionManager, amountOut, collateralDeltaAmount, true);

        // @issue by Hunter
        // should be called within the callback func after utilizing is successful
        // emit UpdatePendingUtilization(pendingUtilization());

        $.strategyStatus = DataTypes.StrategyStatus.DEPOSITING;
        emit UpdateStrategyStatus(DataTypes.StrategyStatus.DEPOSITING);

        emit Utilize(msg.sender, amount, amountOut);
    }

    /// @dev deutilize product
    /// Note: should be called when upkeep is not needed
    ///
    /// @param amount is the product value to be deutilized
    /// @param swapType is the swap type of inch or manual
    /// @param data is the data used in inch
    function deutilize(uint256 amount, DataTypes.SwapType swapType, bytes calldata data) public virtual onlyOperator {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        (bool upkeepNeeded, bytes memory performData) = checkUpkeep("");
        if (upkeepNeeded) {
            _performUpkeep(performData);
            return;
        }

        DataTypes.StrategyStatus strategyStatus_ = $.strategyStatus;

        bool needRebalanceDown = strategyStatus_ == DataTypes.StrategyStatus.NEED_REBLANCE_DOWN;

        // can only deutilize when the strategy status is IDLE or NEED_REBLANCE_DOWN
        if (!needRebalanceDown && strategyStatus_ != DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(strategyStatus_));
        }

        // uint256 productBalance = IERC20(product()).balanceOf(address(this));

        // actual deutilize amount is min of amount, product balance and pending deutilization
        uint256 pendingDeutilization_ = _pendingDeutilization(needRebalanceDown);
        // @note productBalance is already checked within _pendingDeutilization()
        // amount = amount > productBalance ? productBalance : amount;
        amount = amount > pendingDeutilization_ ? pendingDeutilization_ : amount;

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        bool success;
        if (swapType == DataTypes.SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), false, data);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = DataTypes.StrategyStatus.IDLE;
                emit UpdateStrategyStatus(DataTypes.StrategyStatus.IDLE);
                return;
            }
            $.pendingDeutilizedAssets = amountOut;
        } else if (swapType == DataTypes.SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, $.productToAssetSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        // $.spotExecutionPrice = amountOut.mulDiv(10 ** IERC20Metadata(product()).decimals(), amount, Math.Rounding.Ceil);
        address _positionManager = $.positionManager;
        uint256 collateralDeltaAmount;
        if (!needRebalanceDown) {
            $.assetsToWithdraw += amountOut;
            if (amount == pendingDeutilization_) {
                (, collateralDeltaAmount) = $.accRequestedWithdrawAssets.trySub($.proccessedWithdrawAssets + amountOut);
                $.pendingDecreaseCollateral = collateralDeltaAmount;
            } else {
                uint256 positionNetBalance = IPositionManager(_positionManager).positionNetBalance();
                uint256 positionSizeInTokens = IPositionManager(_positionManager).positionSizeInTokens();
                uint256 collateralDeltaToDecrease = positionNetBalance.mulDiv(amount, positionSizeInTokens);
                $.pendingDecreaseCollateral += collateralDeltaToDecrease;
            }
        }
        _adjustPosition(_positionManager, amount, collateralDeltaAmount, false);

        $.strategyStatus = DataTypes.StrategyStatus.WITHDRAWING;
        emit UpdateStrategyStatus(DataTypes.StrategyStatus.WITHDRAWING);

        emit Deutilize(msg.sender, amount, amountOut);
    }

    // note: for testing
    function forcedDecreaseCollateral() external onlyOperator {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if ($.strategyStatus != DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8($.strategyStatus));
        }
        $.strategyStatus = DataTypes.StrategyStatus.WITHDRAWING;
        emit UpdateStrategyStatus(DataTypes.StrategyStatus.WITHDRAWING);

        _adjustPosition($.positionManager, 0, $.pendingDecreaseCollateral, false);
    }

    /*//////////////////////////////////////////////////////////////
                    POSITION MANAGER CALLBACKS LOGIC
    //////////////////////////////////////////////////////////////*/

    // callback function dispatcher
    function afterAdjustPosition(DataTypes.PositionManagerPayload memory params) external onlyPositionManager {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStatus status = $.strategyStatus;
        if (status == DataTypes.StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }
        if (params.isIncrease) {
            _afterIncreasePosition(params.sizeDeltaInTokens, params.collateralDeltaAmount);
        } else {
            _afterDecreasePosition(params.sizeDeltaInTokens, params.collateralDeltaAmount);
        }

        $.strategyStatus = DataTypes.StrategyStatus.IDLE;
        emit UpdateStrategyStatus(DataTypes.StrategyStatus.IDLE);

        // _checkStrategyStatus();

        emit AfterAdjustPosition(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    /*//////////////////////////////////////////////////////////////
                            REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// RELBALANCE DOWN && idle = 0
    ///
    /// currentLeverage = positionSizeUsd / collateralUsd
    /// collateralUsd = positionSizeUsd / currentLeverage
    ///
    /// targetLeverage = targetPositionSizeUsd / collateralUsd
    /// targetPositionSizeUsd = targetLeverage * collateralUsd
    /// targetPositionSize = targetLeverage * positionSize / currentLeverage
    /// deltaSizeToDecrease =  positionSize - targetLeverage * positionSize / currentLeverage
    ///
    /// RELBALANCE DOWN && idle != 0
    ///
    /// targetLeverage = positionSizeUsd / (collateralUsd + deltaCollateralUsdToIncrease)
    /// deltaCollateralUsdToIncrease = positionSizeUsd / targetLeverage - collateralUsd
    ///
    /// REBALANCE UP
    /// currentLeverage = positionSizeUsd / collateralUsd
    /// collateralUsd = positionSizeUsd / currentLeverage
    ///
    /// targetLeverage = positionSizeUsd / targetCollateralUsd
    /// targetCollateralUsd = positionSizeUsd / targetLeverage
    ///
    /// collateralDeltaUsd = positionSizeUsd / targetLeverage - positionSizeUsd / currentLeverage

    function _checkRebalance()
        private
        view
        returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool liquidatable)
    {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 currentLeverage = IPositionManager($.positionManager).currentLeverage();

        if (currentLeverage > $.maxLeverage) {
            rebalanceDownNeeded = true;
            if (currentLeverage > $.safeMarginLeverage) {
                liquidatable = true;
            }
        }

        if (currentLeverage != 0 && currentLeverage < $.minLeverage) {
            rebalanceUpNeeded = true;
        }

        return (rebalanceUpNeeded, rebalanceDownNeeded, liquidatable);
    }

    /*//////////////////////////////////////////////////////////////
                            UPKEEP
    //////////////////////////////////////////////////////////////*/

    //TODO: accomodate for Chainlink interface
    function checkUpkeep(bytes memory) public view virtual returns (bool upkeepNeeded, bytes memory performData) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        if ($.strategyStatus != DataTypes.StrategyStatus.IDLE) {
            return (upkeepNeeded, performData);
        }

        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool liquidatable;
        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;

        (rebalanceUpNeeded, rebalanceDownNeeded, liquidatable) = _checkRebalance();

        if (rebalanceUpNeeded || rebalanceDownNeeded) {
            upkeepNeeded = true;
        } else {
            hedgeDeviationInTokens = _checkHedgeDeviation();
            if (hedgeDeviationInTokens != 0) {
                upkeepNeeded = true;
            } else {
                positionManagerNeedKeep = IPositionManager($.positionManager).needKeep();
                if (positionManagerNeedKeep) {
                    upkeepNeeded = true;
                } else {
                    // @TODO add minimum amount restriction to decrease
                    if ($.pendingDecreaseCollateral > 0) {
                        upkeepNeeded = true;
                    }
                }
            }
        }

        performData = abi.encode(
            rebalanceUpNeeded, rebalanceDownNeeded, liquidatable, hedgeDeviationInTokens, positionManagerNeedKeep
        );

        return (upkeepNeeded, performData);
    }

    //TODO: accomodate for Chainlink interface
    function performUpkeep(bytes calldata performData) external {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.StrategyStatus status = $.strategyStatus;

        if (msg.sender != $.forwarder) {
            revert Errors.UnauthorizedForwarder(msg.sender);
        }

        if (status != DataTypes.StrategyStatus.IDLE) {
            return;
        }

        _performUpkeep(performData);
    }

    function _performUpkeep(bytes memory performData) private {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();

        (
            bool rebalanceUpNeeded,
            bool rebalanceDownNeeded,
            bool liquidatable,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep
        ) = abi.decode(performData, (bool, bool, bool, int256, bool));

        address positionManager_ = $.positionManager;
        if (rebalanceUpNeeded) {
            $.strategyStatus = DataTypes.StrategyStatus.REBALANCING_UP;
            uint256 positionSizeInAssets = $.oracle.convertTokenAmount(
                product(), asset(), IPositionManager(positionManager_).positionSizeInTokens()
            );
            uint256 targetCollateral = positionSizeInAssets / $.targetLeverage;
            (, uint256 deltaCollateralToDecrease) =
                IPositionManager(positionManager_).positionNetBalance().trySub(targetCollateral);
            _adjustPosition(positionManager_, 0, deltaCollateralToDecrease, false);
        } else if (rebalanceDownNeeded) {
            uint256 idle = idleAssets();
            uint256 positionSizeInAssets = $.oracle.convertTokenAmount(
                product(), asset(), IPositionManager(positionManager_).positionSizeInTokens()
            );
            uint256 targetCollateral = positionSizeInAssets / $.targetLeverage;
            (, uint256 deltaCollateralToIncrease) =
                targetCollateral.trySub(IPositionManager(positionManager_).positionNetBalance());

            if (liquidatable && deltaCollateralToIncrease > idle) {
                uint256 amount = _pendingDeutilization(true);
                _manualSwap(amount, false);
                _adjustPosition(positionManager_, amount, 0, false);
            } else if (!liquidatable && idle == 0) {
                $.strategyStatus = DataTypes.StrategyStatus.NEED_REBLANCE_DOWN;
                emit UpdateStrategyStatus(DataTypes.StrategyStatus.NEED_REBLANCE_DOWN);
                emit UpdatePendingDeutilization(_pendingDeutilization(true));
                return;
            } else {
                _adjustPosition(
                    positionManager_, 0, idle > deltaCollateralToIncrease ? deltaCollateralToIncrease : idle, true
                );
            }
        } else if (hedgeDeviationInTokens != 0) {
            if (hedgeDeviationInTokens > 0) {
                _adjustPosition(positionManager_, uint256(hedgeDeviationInTokens), 0, true);
            } else {
                _adjustPosition(positionManager_, uint256(-hedgeDeviationInTokens), 0, false);
            }
        } else if (positionManagerNeedKeep) {
            IPositionManager(positionManager_).keep();
        } else if ($.pendingDecreaseCollateral > 0) {
            // @TODO set threshold for decrease collateral amount
            _adjustPosition(positionManager_, 0, $.pendingDecreaseCollateral, false);
        }

        $.strategyStatus = DataTypes.StrategyStatus.KEEPING;
        emit UpdateStrategyStatus(DataTypes.StrategyStatus.KEEPING);
    }

    // @note strategy's need keep status keeps changing upon a time, that's why
    // to store need_keep to storage is not valid
    //
    // function _checkStrategyStatus() internal {
    //     ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
    //     bool upkeepNeeded = _checkUpkeep($.strategyStatus);
    //     if (upkeepNeeded) {
    //         $.strategyStatus = DataTypes.StrategyStatus.NEED_KEEP;
    //         emit UpdateStrategyStatus(StrategyStatus.NEED_KEEP);
    //     }
    // }

    /// @dev positive means to increase hedge, negative means to decrease
    /// 0 means no need
    function _checkHedgeDeviation() internal view returns (int256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 spotExposure = IERC20(product()).balanceOf(address(this));
        uint256 hedgeExposure = IPositionManager($.positionManager).positionSizeInTokens();
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return 0;
            } else {
                return -hedgeExposure.toInt256();
            }
        }
        uint256 hedgeDeviation = hedgeExposure.mulDiv(PRECISION, spotExposure);
        uint256 threshold = $.hedgeDeviationThreshold;
        if (hedgeDeviation > PRECISION + threshold || hedgeDeviation < PRECISION - threshold) {
            return spotExposure.toInt256() - hedgeExposure.toInt256();
        }
        return 0;
    }

    /// @dev process withdraw request
    /// Note: should be called whenever assets come to this vault
    /// including user's deposit and system's deutilizing
    ///
    /// @return remaining assets which goes to idle or assetsToWithdraw
    function _processWithdrawRequests(uint256 assets) private returns (uint256) {
        if (assets == 0) return 0;
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

    function _afterIncreasePosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount) internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.PositionManagerPayload memory adjustmentRequest = $.adjustmentRequest;

        if (adjustmentRequest.sizeDeltaInTokens > sizeDeltaInTokens) {
            // revert spot to make hedge size the same as spot
            _manualSwap(adjustmentRequest.sizeDeltaInTokens - sizeDeltaInTokens, false);
        }

        (, uint256 revertCollateralDeltaAmount) = adjustmentRequest.collateralDeltaAmount.trySub(collateralDeltaAmount);
        if (revertCollateralDeltaAmount > 0) {
            IERC20(asset()).safeTransferFrom($.positionManager, address(this), revertCollateralDeltaAmount);
        }

        emit UpdatePendingUtilization(
            _pendingUtilization(idleAssets(), _getManagedBasisStrategyStorage().targetLeverage)
        );
    }

    function _afterDecreasePosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount) internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.PositionManagerPayload memory adjustmentRequest = $.adjustmentRequest;

        if (adjustmentRequest.sizeDeltaInTokens > 0) {
            if (sizeDeltaInTokens == 0) {
                uint256 pendingDeutilizedAssets_ = $.pendingDeutilizedAssets;
                _manualSwap(pendingDeutilizedAssets_, true);
                delete $.pendingDeutilizedAssets;
                $.assetsToWithdraw -= pendingDeutilizedAssets_;
            } else {
                $.assetsToWithdraw = _processWithdrawRequests($.assetsToWithdraw);
                _processWithdrawRequests(idleAssets());
            }
        }
        if (collateralDeltaAmount > 0) {
            IERC20(asset()).safeTransferFrom($.positionManager, address(this), collateralDeltaAmount);
            $.assetsToWithdraw += _processWithdrawRequests(collateralDeltaAmount);
            (, $.pendingDecreaseCollateral) = $.pendingDecreaseCollateral.trySub(collateralDeltaAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MANUAL SWAP
    //////////////////////////////////////////////////////////////*/

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        if (data.length != 96) {
            revert Errors.InvalidCallback();
        }
        _verifyCallback();
        (address tokenIn,, address payer) = abi.decode(data, (address, address, address));
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        if (payer == address(this)) {
            IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
        } else {
            IERC20(tokenIn).safeTransferFrom(payer, msg.sender, amountToPay);
        }
    }

    function _verifyCallback() internal view {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (!$.isSwapPool[msg.sender]) {
            revert Errors.InvalidCallback();
        }
    }

    function _manualSwap(uint256 amountIn, bool isAssetToProduct) internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        if (isAssetToProduct) {
            ManualSwapLogic.swap(amountIn, $.assetToProductSwapPath);
        } else {
            ManualSwapLogic.swap(amountIn, $.productToAssetSwapPath);
        }
    }

    function _setManualSwapPath(address[] calldata _assetToProductSwapPath) private {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        uint256 length = _assetToProductSwapPath.length;
        if (
            length % 2 == 0 || _assetToProductSwapPath[0] != asset() || _assetToProductSwapPath[length - 1] != product()
        ) {
            // length should be odd
            // the first element should be asset
            // the last element should be product
            revert Errors.InvalidPath();
        }

        address[] memory _productToAssetSwapPath = new address[](length);
        for (uint256 i; i < length; i++) {
            _productToAssetSwapPath[i] = _assetToProductSwapPath[length - i - 1];
            if (i % 2 != 0) {
                // odd index element of path should be swap pool address
                address pool = _assetToProductSwapPath[i];
                address tokenIn = _assetToProductSwapPath[i - 1];
                address tokenOut = _assetToProductSwapPath[i + 1];
                address token0 = IUniswapV3Pool(pool).token0();
                address token1 = IUniswapV3Pool(pool).token1();
                if ((tokenIn != token0 || tokenOut != token1) && (tokenOut != token0 || tokenIn != token1)) {
                    revert Errors.InvalidPath();
                }
                $.isSwapPool[pool] = true;
            }
        }
        $.assetToProductSwapPath = _assetToProductSwapPath;
        $.productToAssetSwapPath = _productToAssetSwapPath;
    }

    function _pendingUtilization(uint256 _idleAssets, uint256 _targetLeverage) private pure returns (uint256) {
        return _idleAssets.mulDiv(_targetLeverage, PRECISION + _targetLeverage);
    }

    function _pendingIncreaseCollateral(uint256 _idleAssets, uint256 _targetLeverage) private pure returns (uint256) {
        return _idleAssets.mulDiv(PRECISION, PRECISION + _targetLeverage, Math.Rounding.Ceil);
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
    //     uint256 positionSizeInTokens = IPositionManager($.positionManager).positionSizeInTokens();
    //     uint256 positionNetBalance = IPositionManager($.positionManager).positionNetBalance();
    //     IPositionManager($.positionManager).adjustPosition(positionSizeInTokens, positionNetBalance, false);
    // }

    // function wipeStrategy() external onlyOwner {
    //     ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
    //     address asset_ = asset();
    //     IERC20(asset_).safeTransferFrom($.positionManager, address(this), IERC20(asset_).balanceOf($.positionManager));
    //     IERC20(asset_).safeTransfer(msg.sender, IERC20(asset_).balanceOf(address(this)));
    // }

    function _adjustPosition(
        address _positionManager,
        uint256 sizeDeltaInTokens,
        uint256 collateralDeltaAmount,
        bool isIncrease
    ) internal {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        DataTypes.PositionManagerPayload memory params = DataTypes.PositionManagerPayload({
            sizeDeltaInTokens: sizeDeltaInTokens,
            collateralDeltaAmount: collateralDeltaAmount,
            isIncrease: isIncrease
        });
        $.adjustmentRequest = params;
        IPositionManager(_positionManager).adjustPosition(params);
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
        return _pendingUtilization(idleAssets(), _getManagedBasisStrategyStorage().targetLeverage);
    }

    function pendingDeutilization() public view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return _pendingDeutilization($.strategyStatus == DataTypes.StrategyStatus.NEED_REBLANCE_DOWN);
    }

    // @review Numa:
    // I was thinking that we can also switch pendingUtilization from state variable to function as you proposed earlier.
    // My initial thinking that we need to manage pendingUtilization a little bit different then just simply utilizing all idel.
    // The reason for that was the strategy capacity and the idea that in some cases we don't want to utilize all the idle assets
    // if we reach strategy capacity. We can actually manage it by $.strategyCapacity state variable. When we check for
    // pendingUtilization() we calculate remainingCapacity as ($.strategyCapaccity - utilizedAssets()) and set pedingUtilizaton
    // equal to remainingCapacity

    /// @notice product amount to be deutilized to process the totalPendingWithdraw amount
    ///
    /// @dev the following equations are guaranteed when deutilizing to withdraw
    /// pendingDeutilizationInAsset + collateralDeltaToDecrease = totalPendingWithdraw
    /// collateralDeltaToDecrease = positionNetBalance * pendingDeutilization / positionSizeInTokens
    /// pendingDeutilizationInAsset + positionNetBalance * pendingDeutilization / positionSizeInTokens = totalPendingWithdraw
    /// pendingDeutilizationInAsset = pendingDeutilization * productPrice / assetPrice
    /// pendingDeutilization * productPrice / assetPrice + positionNetBalance * pendingDeutilization / positionSizeInTokens =
    /// = totalPendingWithdraw
    /// pendingDeutilization * (productPrice / assetPrice + positionNetBalance / positionSizeInTokens) = totalPendingWithdraw
    /// pendingDeutilization * (productPrice * positionSizeInTokens + assetPrice * positionNetBalance) /
    /// / (assetPrice * positionSizeInTokens) = totalPendingWithdraw
    /// pendingDeutilization * (positionSizeUsd + positionNetBalanceUsd) / (assetPrice * positionSizeInTokens) = totalPendingWithdraw
    /// pendingDeutilization = totalPendingWithdraw * assetPrice * positionSizeInTokens / (positionSizeUsd + positionNetBalanceUsd)
    /// pendingDeutilization = positionSizeInTokens * totalPendingWithdrawUsd / (positionSizeUsd + positionNetBalanceUsd)
    /// pendingDeutilization = positionSizeInTokens *
    /// * (totalPendingWithdrawUsd/assetPrice) / (positionSizeUsd/assetPrice + positionNetBalanceUsd/assetPrice)
    /// pendingDeutilization = positionSizeInTokens * totalPendingWithdraw / (positionSizeInAssets + positionNetBalance)
    function _pendingDeutilization(bool needRebalanceDownWithDeutilizing)
        private
        view
        returns (uint256 deutilization)
    {
        // if we need to redeem last shares we should deutilize all product balance
        uint256 productBalance = IERC20(product()).balanceOf(address(this));
        if (totalSupply() == 0) return productBalance;

        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        IOracle _oracle = $.oracle;
        address positionManager_ = $.positionManager;

        uint256 positionSizeInTokens = IPositionManager(positionManager_).positionSizeInTokens();

        if (needRebalanceDownWithDeutilizing) {
            // currentLeverage > maxLeverage is guarranteed, so there is no math error
            // deltaSizeToDecrease =  positionSize - maxLeverage * positionSize / currentLeverage
            deutilization = positionSizeInTokens
                - positionSizeInTokens.mulDiv($.maxLeverage, IPositionManager(positionManager_).currentLeverage());
        } else {
            uint256 positionNetBalance = IPositionManager(positionManager_).positionNetBalance();
            uint256 positionSizeInAssets = _oracle.convertTokenAmount(product(), asset(), positionSizeInTokens);
            if (positionSizeInAssets == 0 && positionNetBalance == 0) return 0;
            uint256 _pendingDecreaseCollateral = $.pendingDecreaseCollateral;
            uint256 _totalPendingWithdraw = totalPendingWithdraw();

            // prevents underflow
            if (
                _pendingDecreaseCollateral > _totalPendingWithdraw
                    || _pendingDecreaseCollateral >= (positionSizeInAssets + positionNetBalance)
            ) {
                return 0;
            }

            // note: if we do not decrease collateral after every deutilization and do not adjust totalPendingWithdraw and
            // position net balance for $.pendingDecreaseCollateral the return value for pendingDeutilization would be invalid
            deutilization = positionSizeInTokens.mulDiv(
                _totalPendingWithdraw - _pendingDecreaseCollateral,
                positionSizeInAssets + positionNetBalance - _pendingDecreaseCollateral
            );
        }

        deutilization = deutilization > productBalance ? productBalance : deutilization;
        return deutilization;
    }

    function pendingIncreaseCollateral() external view returns (uint256) {
        return _pendingIncreaseCollateral(idleAssets(), _getManagedBasisStrategyStorage().targetLeverage);
    }

    function pendingDecreaseCollateral() external view returns (uint256) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        return $.pendingDecreaseCollateral;
    }

    // review Numa: totalPendingWithdraw is used in preview functions. When we sell product for asset during deutilize
    // amountOut is translated to $.assetsToWithdraw, but it is only accounted in $.proccessedWithdrawAssets after
    // we call _processWithdrawRequests(). This creates a situation where if user call preview function before strategy
    // receives callback, he will get a different number when comparing to calling function after callback.
    // Thus $.assetsToWithdraw should decrease totalPendingWithdraw()
    function totalPendingWithdraw() public view returns (uint256 pendingWithdraw) {
        ManagedBasisStrategyStorage storage $ = _getManagedBasisStrategyStorage();
        (, pendingWithdraw) = $.accRequestedWithdrawAssets.trySub($.proccessedWithdrawAssets + $.assetsToWithdraw);
    }

    function strategyStatus() external view returns (DataTypes.StrategyStatus) {
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
