// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IBasisVault} from "src/interfaces/IBasisVault.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

import {InchAggregatorV6Logic} from "src/libraries/logic/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/ManualSwapLogic.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title A basis strategy
/// @author Logarithm Labs
contract BasisStrategy is Initializable, OwnableUpgradeable, IBasisStrategy {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                ENUMS   
    //////////////////////////////////////////////////////////////*/

    enum SwapType {
        MANUAL,
        INCH_V6
    }

    enum StrategyStatus {
        IDLE,
        KEEPING,
        UTILIZING,
        DEUTILIZING,
        PAUSE
    }

    struct WithdrawRequestState {
        uint256 requestedAmount;
        uint256 accRequestedWithdrawAssets;
        uint256 requestTimestamp;
        address receiver;
        bool isClaimed;
    }

    struct InternalPendingDeutilization {
        IOracle oracle;
        IPositionManager positionManager;
        address asset;
        address product;
        uint256 pendingDecreaseCollateral;
        uint256 productBalance;
        uint256 totalSupply;
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        uint256 currentLeverage;
        uint256 targetLeverage;
        bool processingRebalanceDown;
    }

    struct InternalCheckUpkeep {
        IOracle oracle;
        IPositionManager positionManager;
        address asset;
        address product;
        StrategyStatus status;
        bool processingRebalanceDown;
        Leverages leverages;
        uint256 idleAssets;
        uint256 pendingDecreaseCollateral;
        uint256 hedgeDeviationThreshold;
        uint256 rebalanceDeviationThreshold;
    }

    struct Leverages {
        uint256 currentLeverage;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.BasisStrategy
    struct BasisStrategyStorage {
        // addresses
        IERC20 product;
        IBasisVault vault;
        IPositionManager positionManager;
        IOracle oracle;
        address operator;
        address forwarder;
        // leverage state
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        // strategy configuration
        uint256 rebalanceDeviationThreshold;
        uint256 hedgeDeviationThreshold;
        uint256 userDepositLimit;
        uint256 strategyDepostLimit;
        // asset state
        uint256 assetsToClaim; // asset balance of vault that is ready to claim
        // pending state
        uint256 pendingDeutilizedAssets;
        uint256 pendingDecreaseCollateral;
        // status state
        StrategyStatus strategyStatus;
        bool processingRebalanceDown;
        // withdraw state
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        uint256 requestCounter;
        mapping(bytes32 => WithdrawRequestState) withdrawRequests;
        // manual swap state
        mapping(address => bool) isSwapPool;
        address[] productToAssetSwapPath;
        address[] assetToProductSwapPath;
        // adjust position
        IPositionManager.PositionManagerPayload requestParams;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BasisStrategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BasisStrategyStorageLocation =
        0x3176332e209c21f110843843692adc742ac2f78c16c19930ebc0f9f8747e5200;

    function _getBasisStrategyStorage() private pure returns (BasisStrategyStorage storage $) {
        assembly {
            $.slot := BasisStrategyStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event WithdrawRequest(address indexed receiver, bytes32 indexed withdrawKey, uint256 amount);

    event Claim(address indexed claimer, bytes32 requestId, uint256 amount);

    event UpdatePendingUtilization();

    event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event Deutilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event SwapFailed();

    event UpdateStrategyStatus(StrategyStatus status);

    event AfterAdjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        if (msg.sender != address(_getBasisStrategyStorage().vault)) {
            revert Errors.CallerNotVault();
        }
        _;
    }

    modifier onlyPositionManager() {
        if (msg.sender != address(_getBasisStrategyStorage().positionManager)) {
            revert Errors.CallerNotPositionManager();
        }
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != _getBasisStrategyStorage().operator) {
            revert Errors.CallerNotOperator();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _product,
        address _vault,
        address _oracle,
        address _operator,
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage,
        address[] calldata _assetToProductSwapPath
    ) external initializer {
        __Ownable_init(msg.sender);

        address _asset = IBasisVault(_vault).asset();

        // validation oracle
        if (IOracle(_oracle).getAssetPrice(_asset) == 0 || IOracle(_oracle).getAssetPrice(_product) == 0) revert();

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        $.product = IERC20(_product);
        $.vault = IBasisVault(_vault);
        $.oracle = IOracle(_oracle);
        $.operator = _operator;

        if (_targetLeverage == 0) revert();
        $.targetLeverage = _targetLeverage;
        if (_minLeverage >= _targetLeverage) revert();
        $.minLeverage = _minLeverage;
        if (_maxLeverage <= _targetLeverage) revert();
        $.maxLeverage = _maxLeverage;
        if (_safeMarginLeverage <= _maxLeverage) revert();
        $.safeMarginLeverage = _safeMarginLeverage;

        $.userDepositLimit = type(uint256).max;
        $.strategyDepostLimit = type(uint256).max;
        $.hedgeDeviationThreshold = 1e16; // 1%
        $.rebalanceDeviationThreshold = 1e16; // 1%
        _setManualSwapPath(_assetToProductSwapPath, _asset, _product);
    }

    function _setManualSwapPath(address[] calldata _assetToProductSwapPath, address _asset, address _product) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        uint256 length = _assetToProductSwapPath.length;
        if (length % 2 == 0 || _assetToProductSwapPath[0] != _asset || _assetToProductSwapPath[length - 1] != _product)
        {
            // length should be odd
            // the first element should be asset
            // the last element should be product
            revert();
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
                    revert();
                }
                $.isSwapPool[pool] = true;
            }
        }
        $.assetToProductSwapPath = _assetToProductSwapPath;
        $.productToAssetSwapPath = _productToAssetSwapPath;
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION   
    //////////////////////////////////////////////////////////////*/

    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getBasisStrategyStorage().positionManager = IPositionManager(_positionManager);
    }

    function setForwarder(address _forwarder) external onlyOwner {
        if (_forwarder == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getBasisStrategyStorage().forwarder = _forwarder;
    }

    function setDepositLimits(uint256 userLimit, uint256 strategyLimit) external onlyOwner {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        $.userDepositLimit = userLimit;
        $.strategyDepostLimit = strategyLimit;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACES FOR VAULT   
    //////////////////////////////////////////////////////////////*/

    // callable only by vault
    function processPendingWithdrawRequests() public onlyVault {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IBasisVault _vault = $.vault;

        uint256 idleAssets_ = _idleAssets(_vault.asset(), address(_vault), $.assetsToClaim);

        _processPendingWithdrawRequests(idleAssets_);
    }

    /// @dev request withdraw
    /// Note: if idle assets is greater than the requested amount,
    /// then process the request directly, otherwise will be processed by deutilizing
    ///
    /// @param receiver address to receive asset
    /// @param assets amount to be received
    function requestWithdraw(address receiver, uint256 assets) external onlyVault {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IBasisVault _vault = $.vault;

        uint256 idleAssets_ = _idleAssets(_vault.asset(), address(_vault), $.assetsToClaim);

        if (idleAssets_ >= assets) {
            IERC20(_vault.asset()).safeTransferFrom(address(_vault), receiver, assets);
        } else {
            $.assetsToClaim += idleAssets_;

            uint256 pendingWithdraw = assets - idleAssets_;

            uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets + pendingWithdraw;
            $.accRequestedWithdrawAssets = _accRequestedWithdrawAssets;

            uint256 counter = $.requestCounter;
            bytes32 withdrawKey = getWithdrawKey(counter);
            $.withdrawRequests[withdrawKey] = WithdrawRequestState({
                requestedAmount: assets,
                accRequestedWithdrawAssets: _accRequestedWithdrawAssets,
                requestTimestamp: block.timestamp,
                receiver: receiver,
                isClaimed: false
            });

            $.requestCounter++;

            emit WithdrawRequest(receiver, withdrawKey, assets);
        }

        emit UpdatePendingUtilization();
    }

    function claim(bytes32 withdrawRequestKey) external onlyVault {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        WithdrawRequestState memory withdrawState = $.withdrawRequests[withdrawRequestKey];

        if (withdrawState.isClaimed) {
            revert Errors.RequestAlreadyClaimed();
        }

        bool _processingRebalanceDown = $.processingRebalanceDown;
        IBasisVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 productBalance = IERC20(_product).balanceOf(address(this));
        uint256 totalSupply = _vault.totalSupply();
        uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;
        uint256 _proccessedWithdrawAssets = $.proccessedWithdrawAssets;

        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                oracle: $.oracle,
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                productBalance: productBalance,
                totalSupply: totalSupply,
                accRequestedWithdrawAssets: _accRequestedWithdrawAssets,
                proccessedWithdrawAssets: _proccessedWithdrawAssets,
                currentLeverage: _positionManager.currentLeverage(),
                targetLeverage: $.targetLeverage,
                processingRebalanceDown: _processingRebalanceDown
            })
        );

        (bool isExecuted, bool isLast) = _isWithdrawRequestExecuted(
            withdrawState,
            pendingDeutilization_,
            totalSupply,
            _accRequestedWithdrawAssets,
            _proccessedWithdrawAssets,
            $.strategyStatus
        );

        if (!isExecuted) {
            revert Errors.RequestNotExecuted();
        }

        withdrawState.isClaimed = true;

        $.withdrawRequests[withdrawRequestKey] = withdrawState;

        uint256 executedAmount;
        // separate workflow for last redeem
        if (isLast) {
            executedAmount =
                withdrawState.requestedAmount - (withdrawState.accRequestedWithdrawAssets - _proccessedWithdrawAssets);
            $.proccessedWithdrawAssets = _accRequestedWithdrawAssets;
            $.pendingDecreaseCollateral = 0;
        } else {
            executedAmount = withdrawState.requestedAmount;
        }

        $.assetsToClaim -= executedAmount;

        IERC20(_asset).safeTransferFrom(address(_vault), withdrawState.receiver, executedAmount);

        emit Claim(withdrawState.receiver, withdrawRequestKey, executedAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE/DEUTILZE   
    //////////////////////////////////////////////////////////////*/

    /// @dev utilize asset
    ///
    /// @param amount is the asset value to be utilized
    /// @param swapType is the swap type of inch or manual
    /// @param swapData is the data used in inch
    function utilize(uint256 amount, SwapType swapType, bytes calldata swapData) external virtual onlyOperator {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        StrategyStatus strategyStatus_ = $.strategyStatus;

        // can only utilize when the strategy status is IDLE
        if (strategyStatus_ != StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(strategyStatus_));
        }

        IBasisVault _vault = $.vault;
        address _asset = _vault.asset();
        address _product = address($.product);

        uint256 idle = _idleAssets(_asset, address(_vault), $.assetsToClaim);
        uint256 _targetLeverage = $.targetLeverage;

        // actual utilize amount is min of amount, idle assets and pending utilization
        uint256 pendingUtilization_ = _pendingUtilization(idle, _targetLeverage, $.processingRebalanceDown);
        if (pendingUtilization_ == 0) {
            revert Errors.ZeroPendingUtilization();
        }

        amount = amount > pendingUtilization_ ? pendingUtilization_ : amount;

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        bool success;
        IERC20(_asset).safeTransferFrom(address(_vault), address(this), amount);
        if (swapType == SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, _asset, _product, true, swapData);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = StrategyStatus.IDLE;
                emit UpdateStrategyStatus(StrategyStatus.IDLE);
                return;
            }
        } else if (swapType == SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, $.assetToProductSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        uint256 pendingIncreaseCollateral_ = _pendingIncreaseCollateral(idle, _targetLeverage);
        uint256 collateralDeltaAmount;
        if (pendingIncreaseCollateral_ > 0) {
            collateralDeltaAmount = pendingIncreaseCollateral_.mulDiv(amount, pendingUtilization_);
            (uint256 min, uint256 max) = $.positionManager.increaseCollateralMinMax();
            collateralDeltaAmount = _clamp(min, collateralDeltaAmount, max);
        }
        _adjustPosition(amountOut, collateralDeltaAmount, true);

        $.strategyStatus = StrategyStatus.UTILIZING;
        emit UpdateStrategyStatus(StrategyStatus.UTILIZING);

        emit Utilize(msg.sender, amount, amountOut);
    }

    /// @dev deutilize product
    ///
    /// @param amount is the product value to be deutilized
    /// @param swapType is the swap type of inch or manual
    /// @param swapData is the data used in inch
    function deutilize(uint256 amount, SwapType swapType, bytes calldata swapData) public virtual onlyOperator {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        StrategyStatus strategyStatus_ = $.strategyStatus;

        // can only deutilize when the strategy status is IDLE
        if (strategyStatus_ != StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(strategyStatus_));
        }

        bool _processingRebalanceDown = $.processingRebalanceDown;
        IBasisVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 productBalance = IERC20(_product).balanceOf(address(this));
        uint256 totalSupply = _vault.totalSupply();

        // actual deutilize amount is min of amount, product balance and pending deutilization
        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                oracle: $.oracle,
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                productBalance: productBalance,
                totalSupply: totalSupply,
                accRequestedWithdrawAssets: $.accRequestedWithdrawAssets,
                proccessedWithdrawAssets: $.proccessedWithdrawAssets,
                currentLeverage: _positionManager.currentLeverage(),
                targetLeverage: $.targetLeverage,
                processingRebalanceDown: _processingRebalanceDown
            })
        );

        amount = amount > pendingDeutilization_ ? pendingDeutilization_ : amount;

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        bool success;
        if (swapType == SwapType.INCH_V6) {
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, _asset, _product, false, swapData);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = StrategyStatus.IDLE;
                emit UpdateStrategyStatus(StrategyStatus.IDLE);
                return;
            }
            $.pendingDeutilizedAssets = amountOut;
        } else if (swapType == SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, $.productToAssetSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        $.pendingDeutilizedAssets = amountOut;

        uint256 collateralDeltaAmount;
        if (!_processingRebalanceDown) {
            if (amount == pendingDeutilization_ && totalSupply == 0) {
                (, collateralDeltaAmount) = $.accRequestedWithdrawAssets.trySub($.proccessedWithdrawAssets + amountOut);
                $.pendingDecreaseCollateral = collateralDeltaAmount;
            } else {
                uint256 positionNetBalance = _positionManager.positionNetBalance();
                (, positionNetBalance) = positionNetBalance.trySub($.pendingDecreaseCollateral);
                uint256 positionSizeInTokens = _positionManager.positionSizeInTokens();
                uint256 collateralDeltaToDecrease = positionNetBalance.mulDiv(amount, positionSizeInTokens);
                $.pendingDecreaseCollateral += collateralDeltaToDecrease;
            }
        }
        _adjustPosition(amount, collateralDeltaAmount, false);

        $.strategyStatus = StrategyStatus.DEUTILIZING;
        emit UpdateStrategyStatus(StrategyStatus.DEUTILIZING);

        emit Deutilize(msg.sender, amount, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    function checkUpkeep(bytes memory) public view virtual returns (bool upkeepNeeded, bytes memory performData) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        IBasisVault _vault = $.vault;
        address _asset = _vault.asset();
        uint256 idleAssets_ = _idleAssets(_asset, address(_vault), $.assetsToClaim);
        uint256 currentLeverage = $.positionManager.currentLeverage();

        (upkeepNeeded, performData) = _checkUpkeep(
            InternalCheckUpkeep({
                oracle: $.oracle,
                positionManager: $.positionManager,
                asset: _asset,
                product: address($.product),
                status: $.strategyStatus,
                processingRebalanceDown: $.processingRebalanceDown,
                leverages: Leverages({
                    currentLeverage: currentLeverage,
                    targetLeverage: $.targetLeverage,
                    minLeverage: $.minLeverage,
                    maxLeverage: $.maxLeverage,
                    safeMarginLeverage: $.safeMarginLeverage
                }),
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                idleAssets: idleAssets_,
                hedgeDeviationThreshold: $.hedgeDeviationThreshold,
                rebalanceDeviationThreshold: $.rebalanceDeviationThreshold
            })
        );

        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (msg.sender != $.forwarder) {
            revert Errors.UnauthorizedForwarder(msg.sender);
        }

        if ($.strategyStatus != StrategyStatus.IDLE) {
            return;
        }

        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool));

        $.strategyStatus = StrategyStatus.KEEPING;

        if (rebalanceDownNeeded) {
            // if reblance down is needed, we have to break normal deutilization of decreasing collateral
            $.pendingDecreaseCollateral = 0;
            IPositionManager _positionManager = $.positionManager;
            IBasisVault _vault = $.vault;
            address _asset = _vault.asset();
            uint256 idleAssets_ = _idleAssets(_asset, address(_vault), $.assetsToClaim);
            uint256 currentLeverage = _positionManager.currentLeverage();
            uint256 targetLeverage = $.targetLeverage;
            uint256 deltaCollateralToIncrease =
                _calculateDeltaCollateralForRebalance(_positionManager, currentLeverage, targetLeverage);
            (uint256 minIncreaseCollateral,) = _positionManager.increaseCollateralMinMax();

            if (deleverageNeeded && (deltaCollateralToIncrease > idleAssets_ || minIncreaseCollateral > idleAssets_)) {
                address _product = address($.product);
                uint256 amount = _pendingDeutilization(
                    InternalPendingDeutilization({
                        oracle: $.oracle,
                        positionManager: _positionManager,
                        asset: _asset,
                        product: _product,
                        pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                        productBalance: IERC20(_product).balanceOf(address(this)),
                        totalSupply: _vault.totalSupply(),
                        accRequestedWithdrawAssets: $.accRequestedWithdrawAssets,
                        proccessedWithdrawAssets: $.proccessedWithdrawAssets,
                        currentLeverage: currentLeverage,
                        targetLeverage: targetLeverage,
                        processingRebalanceDown: $.processingRebalanceDown
                    })
                );
                (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
                (min, max) = (
                    min == 0 ? 0 : $.oracle.convertTokenAmount(_asset, _product, min),
                    max == type(uint256).max ? type(uint256).max : $.oracle.convertTokenAmount(_asset, _product, max)
                );

                // @issue amount can be 0 because of clamping that breaks emergency rebalance down
                amount = _clamp(min, amount, max);
                if (amount > 0) {
                    ManualSwapLogic.swap(amount, $.productToAssetSwapPath);
                    // produced asset shouldn't go to idle until position size is decreased
                    _adjustPosition(amount, 0, false);
                } else {
                    $.strategyStatus = StrategyStatus.IDLE;
                }
            } else {
                uint256 collateralDeltaAmount =
                    idleAssets_ > deltaCollateralToIncrease ? deltaCollateralToIncrease : idleAssets_;
                if (!_adjustPosition(0, collateralDeltaAmount, true)) $.strategyStatus = StrategyStatus.IDLE;
            }
            $.processingRebalanceDown = true;
        } else if (hedgeDeviationInTokens != 0) {
            if (hedgeDeviationInTokens > 0) {
                if (!_adjustPosition(uint256(hedgeDeviationInTokens), 0, false)) $.strategyStatus = StrategyStatus.IDLE;
            } else {
                if (!_adjustPosition(uint256(-hedgeDeviationInTokens), 0, true)) {
                    $.strategyStatus = StrategyStatus.IDLE;
                }
            }
        } else if (positionManagerNeedKeep) {
            $.positionManager.keep();
        } else if (decreaseCollateral) {
            if (!_adjustPosition(0, $.pendingDecreaseCollateral, false)) $.strategyStatus = StrategyStatus.IDLE;
        } else if (rebalanceUpNeeded) {
            IPositionManager _positionManager = $.positionManager;
            uint256 deltaCollateralToDecrease = _calculateDeltaCollateralForRebalance(
                _positionManager, _positionManager.currentLeverage(), $.targetLeverage
            );
            if (!_adjustPosition(0, deltaCollateralToDecrease, false)) {
                $.strategyStatus = StrategyStatus.IDLE;
            }
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
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if (!$.isSwapPool[msg.sender]) {
            revert Errors.InvalidCallback();
        }
    }

    // callback function dispatcher
    function afterAdjustPosition(IPositionManager.PositionManagerPayload calldata params)
        external
        onlyPositionManager
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        StrategyStatus status = $.strategyStatus;

        if (status == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }

        if (params.isIncrease) {
            _afterIncreasePosition(params);
        } else {
            _afterDecreasePosition(params, status);
        }

        $.strategyStatus = StrategyStatus.IDLE;

        emit UpdatePendingUtilization();

        emit UpdateStrategyStatus(StrategyStatus.IDLE);

        emit AfterAdjustPosition(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    function pendingUtilizations()
        external
        view
        returns (uint256 pendingUtilizationInAsset, uint256 pendingDeutilizationInProduct)
    {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (upkeepNeeded) return (pendingUtilizationInAsset, pendingDeutilizationInProduct);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        // when strategy is in processing, return 0
        // so that operator doesn't need to take care of status
        if ($.strategyStatus != StrategyStatus.IDLE) {
            return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
        }

        IPositionManager _positionManager = $.positionManager;
        IBasisVault _vault = $.vault;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 idleAssets_ = _idleAssets(_asset, address(_vault), $.assetsToClaim);
        bool _processingRebalanceDown = $.processingRebalanceDown;
        pendingUtilizationInAsset = _pendingUtilization(idleAssets_, $.targetLeverage, _processingRebalanceDown);
        pendingDeutilizationInProduct = _pendingDeutilization(
            InternalPendingDeutilization({
                oracle: $.oracle,
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                productBalance: IERC20(_product).balanceOf(address(this)),
                totalSupply: _vault.totalSupply(),
                accRequestedWithdrawAssets: $.accRequestedWithdrawAssets,
                proccessedWithdrawAssets: $.proccessedWithdrawAssets,
                currentLeverage: _positionManager.currentLeverage(),
                targetLeverage: $.targetLeverage,
                processingRebalanceDown: _processingRebalanceDown
            })
        );
        return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
    }

    /// @dev return total assets that includes idle, spot, hedge balances
    function totalAssets() external view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IBasisVault _vault = $.vault;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 idleAssets_ = _idleAssets(_asset, _product, $.assetsToClaim);
        uint256 utilizedAssets_ = _utilizedAssets(_asset, _product, $.oracle, $.positionManager);
        uint256 _assetsToWithdraw = IERC20(_asset).balanceOf(address(this));

        (, uint256 totalAssets_) = ((utilizedAssets_ + idleAssets_) + _assetsToWithdraw).trySub(
            ($.accRequestedWithdrawAssets - $.proccessedWithdrawAssets)
        );
        return totalAssets_;
    }

    /// @dev return idle asset that can be claimed or used for utilizing
    function idleAssets() external view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IBasisVault _vault = $.vault;
        return _idleAssets(_vault.asset(), address(_vault), $.assetsToClaim);
    }

    function totalPendingWithdraw() external view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        return _totalPendingWithdraw($.vault.asset(), $.accRequestedWithdrawAssets, $.proccessedWithdrawAssets);
    }

    function isClaimable(bytes32 withdrawRequestKey) external view returns (bool) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        WithdrawRequestState memory withdrawRequest = $.withdrawRequests[withdrawRequestKey];

        IBasisVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 productBalance = IERC20(_product).balanceOf(address(this));
        uint256 totalSupply = _vault.totalSupply();
        uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;
        uint256 _proccessedWithdrawAssets = $.proccessedWithdrawAssets;

        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                oracle: $.oracle,
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                pendingDecreaseCollateral: $.pendingDecreaseCollateral,
                productBalance: productBalance,
                totalSupply: totalSupply,
                accRequestedWithdrawAssets: _accRequestedWithdrawAssets,
                proccessedWithdrawAssets: _proccessedWithdrawAssets,
                currentLeverage: _positionManager.currentLeverage(),
                targetLeverage: $.targetLeverage,
                processingRebalanceDown: $.processingRebalanceDown
            })
        );
        (bool isExecuted,) = _isWithdrawRequestExecuted(
            withdrawRequest,
            pendingDeutilization_,
            totalSupply,
            _accRequestedWithdrawAssets,
            _proccessedWithdrawAssets,
            $.strategyStatus
        );

        return isExecuted && !withdrawRequest.isClaimed;
    }

    function getWithdrawKey(uint256 counter) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), counter));
    }

    function depositLimits() external view returns (uint256 userDepositLimit, uint256 strategyDepostLimit) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        userDepositLimit = $.userDepositLimit;
        strategyDepostLimit = $.strategyDepostLimit;
        return (userDepositLimit, strategyDepostLimit);
    }

    function _adjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease)
        internal
        virtual
        returns (bool)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        address _asset = $.vault.asset();
        address _product = address($.product);
        if (isIncrease && collateralDeltaAmount > 0) {
            IERC20(_asset).safeTransfer(address($.positionManager), collateralDeltaAmount);
        }

        if (sizeDeltaInTokens > 0) {
            uint256 min;
            uint256 max;
            if (isIncrease) (min, max) = $.positionManager.increaseSizeMinMax();
            else (min, max) = $.positionManager.decreaseSizeMinMax();

            (min, max) = (
                min == 0 ? 0 : $.oracle.convertTokenAmount(_asset, _product, min),
                max == type(uint256).max ? type(uint256).max : $.oracle.convertTokenAmount(_asset, _product, max)
            );
            sizeDeltaInTokens = _clamp(min, sizeDeltaInTokens, max);
        }

        if (collateralDeltaAmount > 0) {
            uint256 min;
            uint256 max;
            if (isIncrease) (min, max) = $.positionManager.increaseCollateralMinMax();
            else (min, max) = $.positionManager.decreaseCollateralMinMax();
            collateralDeltaAmount = _clamp(min, collateralDeltaAmount, max);
        }

        if (collateralDeltaAmount > 0 || sizeDeltaInTokens > 0) {
            IPositionManager.PositionManagerPayload memory requestParams = IPositionManager.PositionManagerPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: collateralDeltaAmount,
                isIncrease: isIncrease
            });
            $.requestParams = requestParams;
            $.positionManager.adjustPosition(requestParams);
            return true;
        } else {
            return false;
        }
    }

    function _afterIncreasePosition(IPositionManager.PositionManagerPayload calldata responseParams) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.PositionManagerPayload memory requestParams = $.requestParams;

        if (requestParams.sizeDeltaInTokens > 0) {
            (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens) = _checkResultedPositionSize(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, $.hedgeDeviationThreshold
            );
            if (isWrongPositionSize) {
                // status = StrategyStatus.PAUSE;
                if (sizeDeltaDeviationInTokens < 0) {
                    IBasisVault _vault = $.vault;
                    // revert spot to make hedge size the same as spot
                    uint256 amountOut =
                        ManualSwapLogic.swap(uint256(-sizeDeltaDeviationInTokens), $.productToAssetSwapPath);
                    IERC20(_vault.asset()).safeTransfer(address(_vault), amountOut);
                }
            }
        }

        (, uint256 revertCollateralDeltaAmount) =
            requestParams.collateralDeltaAmount.trySub(responseParams.collateralDeltaAmount);

        if (revertCollateralDeltaAmount > 0) {
            IBasisVault _vault = $.vault;
            IERC20(_vault.asset()).safeTransferFrom(
                address($.positionManager), address(_vault), revertCollateralDeltaAmount
            );
        }

        (, bool rebalanceDownNeeded) =
            _checkNeedRebalance($.positionManager.currentLeverage(), $.targetLeverage, $.rebalanceDeviationThreshold);
        // only when rebalance was started, we need to check
        $.processingRebalanceDown = $.processingRebalanceDown && rebalanceDownNeeded;
    }

    function _afterDecreasePosition(
        IPositionManager.PositionManagerPayload calldata responseParams,
        StrategyStatus status
    ) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.PositionManagerPayload memory requestParams = $.requestParams;
        bool _processingRebalanceDown = $.processingRebalanceDown;
        IBasisVault _vault = $.vault;
        address _asset = _vault.asset();

        if (requestParams.sizeDeltaInTokens > 0) {
            uint256 _pendingDeutilizedAssets = $.pendingDeutilizedAssets;
            delete $.pendingDeutilizedAssets;
            (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens) = _checkResultedPositionSize(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, $.hedgeDeviationThreshold
            );
            if (isWrongPositionSize) {
                // status = StrategyStatus.PAUSE;
                if (sizeDeltaDeviationInTokens < 0) {
                    uint256 sizeDeltaDeviationInTokensAbs = uint256(-sizeDeltaDeviationInTokens);
                    uint256 assetsToBeReverted;
                    if (sizeDeltaDeviationInTokensAbs == requestParams.sizeDeltaInTokens) {
                        assetsToBeReverted = _pendingDeutilizedAssets;
                    } else {
                        assetsToBeReverted = _pendingDeutilizedAssets.mulDiv(
                            sizeDeltaDeviationInTokensAbs, requestParams.sizeDeltaInTokens
                        );
                    }

                    ManualSwapLogic.swap(assetsToBeReverted, $.assetToProductSwapPath);
                    _pendingDeutilizedAssets -= assetsToBeReverted;
                }
            }

            if (_processingRebalanceDown) {
                // release deutilized asset to idle when rebalance down
                IERC20(_asset).safeTransfer(address(_vault), _pendingDeutilizedAssets);
                uint256 idleAssets_ = _idleAssets(_asset, address(_vault), $.assetsToClaim);
                _processPendingWithdrawRequests(idleAssets_);
            } else {
                // process withdraw request
                uint256 _assetsToWithdraw = IERC20(_asset).balanceOf(address(this));
                (uint256 processedAssets,) = _processPendingWithdrawRequests(_assetsToWithdraw);
                IERC20(_asset).safeTransfer(address(_vault), processedAssets);
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.positionManager.currentLeverage(), $.targetLeverage, $.rebalanceDeviationThreshold
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = _processingRebalanceDown && rebalanceDownNeeded;
        }

        if (responseParams.collateralDeltaAmount > 0) {
            // the case when deutilizing for withdrawls and rebalancing Up
            (, $.pendingDecreaseCollateral) = $.pendingDecreaseCollateral.trySub(responseParams.collateralDeltaAmount);
            if (status == StrategyStatus.KEEPING) {
                // release deutilized asset to idle when rebalance down
                IERC20(_asset).safeTransferFrom(
                    address($.positionManager), address(_vault), responseParams.collateralDeltaAmount
                );
                uint256 idleAssets_ = _idleAssets(_asset, address(_vault), $.assetsToClaim);
                _processPendingWithdrawRequests(idleAssets_);
            } else {
                IERC20(_asset).safeTransferFrom(
                    address($.positionManager), address(this), responseParams.collateralDeltaAmount
                );
                uint256 _assetsToWithdraw = IERC20(_asset).balanceOf(address(this));
                (uint256 processedAssets,) = _processPendingWithdrawRequests(_assetsToWithdraw);
                IERC20(_asset).safeTransfer(address(_vault), processedAssets);
            }
        }
    }

    /// @dev process pending withdraw request
    function _processPendingWithdrawRequests(uint256 assets)
        private
        returns (uint256 processedAssets, uint256 remainingAssets)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (assets == 0) {
            return (processedAssets, remainingAssets);
        } else {
            uint256 _proccessedWithdrawAssets = $.proccessedWithdrawAssets;
            uint256 _accRequestedWithdrawAssets = $.accRequestedWithdrawAssets;

            // check if there is neccessarity to process withdraw requests
            if (_proccessedWithdrawAssets < _accRequestedWithdrawAssets) {
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
                processedAssets = assets;
            } else {
                remainingAssets = assets;
            }
            return (processedAssets, remainingAssets);
        }
    }

    function _checkUpkeep(InternalCheckUpkeep memory params)
        private
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (params.status != StrategyStatus.IDLE) {
            return (upkeepNeeded, performData);
        }

        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;
        bool decreaseCollateral;

        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded) = _checkRebalance(params.leverages);

        if (!rebalanceDownNeeded && params.processingRebalanceDown) {
            (, rebalanceDownNeeded) = _checkNeedRebalance(
                params.leverages.currentLeverage, params.leverages.targetLeverage, params.rebalanceDeviationThreshold
            );
        }

        if (rebalanceUpNeeded) {
            uint256 deltaCollateralToDecrease = _calculateDeltaCollateralForRebalance(
                params.positionManager, params.leverages.currentLeverage, params.leverages.targetLeverage
            );
            (uint256 minDecreaseCollateral,) = params.positionManager.decreaseCollateralMinMax();
            rebalanceUpNeeded = deltaCollateralToDecrease >= minDecreaseCollateral;
        }

        if (rebalanceDownNeeded && params.processingRebalanceDown && !deleverageNeeded) {
            (uint256 minIncreaseCollateral,) = params.positionManager.increaseCollateralMinMax();
            rebalanceDownNeeded = params.idleAssets != 0 && params.idleAssets >= minIncreaseCollateral;
        }

        if (rebalanceUpNeeded) {
            upkeepNeeded = true;
        } else {
            hedgeDeviationInTokens = _checkHedgeDeviation(
                params.oracle, params.positionManager, params.asset, params.product, params.hedgeDeviationThreshold
            );
            if (hedgeDeviationInTokens != 0) {
                upkeepNeeded = true;
            } else {
                positionManagerNeedKeep = params.positionManager.needKeep();
                if (positionManagerNeedKeep) {
                    upkeepNeeded = true;
                } else {
                    (uint256 minDecreaseCollateral,) = params.positionManager.decreaseCollateralMinMax();
                    if (params.pendingDecreaseCollateral > minDecreaseCollateral) {
                        decreaseCollateral = true;
                        upkeepNeeded = true;
                    } else if (rebalanceUpNeeded) {
                        upkeepNeeded = true;
                    }
                }
            }
        }

        performData = abi.encode(
            rebalanceDownNeeded,
            deleverageNeeded,
            hedgeDeviationInTokens,
            positionManagerNeedKeep,
            decreaseCollateral,
            rebalanceUpNeeded
        );

        return (upkeepNeeded, performData);
    }

    function _idleAssets(address _asset, address _vault, uint256 _assetsToClaim) private view returns (uint256) {
        uint256 assetsOfVault = IERC20(_asset).balanceOf(_vault);
        return assetsOfVault - _assetsToClaim;
    }

    /// @dev returns the spot assets value
    function _utilizedAssets(address _asset, address _product, IOracle _oralce, IPositionManager _positionManager)
        private
        view
        returns (uint256)
    {
        uint256 productBalance = IERC20(_product).balanceOf(address(this));
        uint256 productValueInAssets = _oralce.convertTokenAmount(_product, _asset, productBalance);
        return productValueInAssets + _positionManager.positionNetBalance();
    }

    function _totalPendingWithdraw(
        address _asset,
        uint256 _accRequestedWithdrawAssets,
        uint256 _proccessedWithdrawAssets
    ) private view returns (uint256) {
        uint256 _assetsToWithdraw = IERC20(_asset).balanceOf(address(this));
        (, uint256 totalPendingWithdraw_) =
            _accRequestedWithdrawAssets.trySub(_proccessedWithdrawAssets + _assetsToWithdraw);
        return totalPendingWithdraw_;
    }

    function _pendingUtilization(uint256 idleAssets_, uint256 _targetLeverage, bool _processingRebalanceDown)
        public
        pure
        returns (uint256)
    {
        // don't use utilze function when rebalancing
        return _processingRebalanceDown
            ? 0
            : idleAssets_.mulDiv(_targetLeverage, Constants.FLOAT_PRECISION + _targetLeverage);
    }

    function _pendingIncreaseCollateral(uint256 idleAssets_, uint256 _targetLeverage) private pure returns (uint256) {
        return idleAssets_.mulDiv(
            Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + _targetLeverage, Math.Rounding.Ceil
        );
    }

    function _pendingDeutilization(InternalPendingDeutilization memory params) private view returns (uint256) {
        if (params.totalSupply == 0) return params.productBalance;

        uint256 positionSizeInTokens = params.positionManager.positionSizeInTokens();

        uint256 deutilization;
        if (params.processingRebalanceDown) {
            if (params.currentLeverage > params.targetLeverage) {
                // deltaSizeToDecrease =  positionSize - targetLeverage * positionSize / currentLeverage
                deutilization =
                    positionSizeInTokens - positionSizeInTokens.mulDiv(params.targetLeverage, params.currentLeverage);
            }
        } else {
            uint256 positionSizeInAssets =
                params.oracle.convertTokenAmount(params.product, params.asset, positionSizeInTokens);
            uint256 positionNetBalance = params.positionManager.positionNetBalance();

            if (positionSizeInAssets == 0 || positionNetBalance == 0) return 0;

            uint256 totalPendingWithdraw_ =
                _totalPendingWithdraw(params.asset, params.accRequestedWithdrawAssets, params.proccessedWithdrawAssets);

            if (
                params.pendingDecreaseCollateral > totalPendingWithdraw_
                    || params.pendingDecreaseCollateral >= (positionSizeInAssets + positionNetBalance)
            ) {
                return 0;
            }

            deutilization = positionSizeInTokens.mulDiv(
                totalPendingWithdraw_ - params.pendingDecreaseCollateral,
                positionSizeInAssets + positionNetBalance - params.pendingDecreaseCollateral
            );
        }

        deutilization = deutilization > params.productBalance ? params.productBalance : deutilization;

        return deutilization;
    }

    function _clamp(uint256 min, uint256 value, uint256 max) internal pure returns (uint256 result) {
        result = value < min ? 0 : (value > max ? max : value);
    }

    // @dev should be called under the condition that sizeDeltaInTokensReq != 0
    function _checkResultedPositionSize(
        uint256 sizeDeltaInTokensResp,
        uint256 sizeDeltaInTokensReq,
        uint256 _hedgeDeviationThreshold
    ) internal pure returns (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens) {
        sizeDeltaDeviationInTokens = sizeDeltaInTokensResp.toInt256() - sizeDeltaInTokensReq.toInt256();
        isWrongPositionSize = (
            sizeDeltaDeviationInTokens < 0 ? uint256(-sizeDeltaDeviationInTokens) : uint256(sizeDeltaDeviationInTokens)
        ).mulDiv(Constants.FLOAT_PRECISION, sizeDeltaInTokensReq) > _hedgeDeviationThreshold;
        return (isWrongPositionSize, sizeDeltaDeviationInTokens);
    }

    function _checkNeedRebalance(
        uint256 _currentLeverage,
        uint256 _targetLeverage,
        uint256 _rebalanceDeviationThreshold
    ) internal pure returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded) {
        int256 leverageDeviation = _currentLeverage.toInt256() - _targetLeverage.toInt256();
        if (
            (leverageDeviation < 0 ? uint256(-leverageDeviation) : uint256(leverageDeviation)).mulDiv(
                Constants.FLOAT_PRECISION, _targetLeverage
            ) > _rebalanceDeviationThreshold
        ) {
            rebalanceUpNeeded = leverageDeviation < 0;
            rebalanceDownNeeded = !rebalanceUpNeeded;
        }
        return (rebalanceUpNeeded, rebalanceDownNeeded);
    }

    function _checkRebalance(Leverages memory leverages)
        internal
        pure
        returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded)
    {
        if (leverages.currentLeverage > leverages.maxLeverage) {
            rebalanceDownNeeded = true;
            if (leverages.currentLeverage > leverages.safeMarginLeverage) {
                deleverageNeeded = true;
            }
        }

        if (leverages.currentLeverage != 0 && leverages.currentLeverage < leverages.minLeverage) {
            rebalanceUpNeeded = true;
        }
    }

    /// @param _oracle IOracle
    /// @param _positionManager IPositionManager
    /// @param _asset address
    /// @param _product address
    /// @param _hedgeDeviationThreshold uint256
    ///
    /// @return hedge deviation of int type
    function _checkHedgeDeviation(
        IOracle _oracle,
        IPositionManager _positionManager,
        address _asset,
        address _product,
        uint256 _hedgeDeviationThreshold
    ) internal view returns (int256) {
        uint256 spotExposure = IERC20(_product).balanceOf(address(this));
        uint256 hedgeExposure = _positionManager.positionSizeInTokens();
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return 0;
            } else {
                return -hedgeExposure.toInt256();
            }
        }
        uint256 hedgeDeviation = hedgeExposure.mulDiv(Constants.FLOAT_PRECISION, spotExposure);
        if (
            hedgeDeviation > Constants.FLOAT_PRECISION + _hedgeDeviationThreshold
                || hedgeDeviation < Constants.FLOAT_PRECISION - _hedgeDeviationThreshold
        ) {
            int256 hedgeDeviationInTokens = hedgeExposure.toInt256() - spotExposure.toInt256();
            if (hedgeDeviationInTokens > 0) {
                (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
                (min, max) = (
                    min == 0 ? 0 : _oracle.convertTokenAmount(_asset, _product, min),
                    max == type(uint256).max ? type(uint256).max : _oracle.convertTokenAmount(_asset, _product, max)
                );
                return int256(_clamp(min, uint256(hedgeDeviationInTokens), max));
            } else {
                (uint256 min, uint256 max) = _positionManager.increaseSizeMinMax();
                (min, max) = (
                    min == 0 ? 0 : _oracle.convertTokenAmount(_asset, _product, min),
                    max == type(uint256).max ? type(uint256).max : _oracle.convertTokenAmount(_asset, _product, max)
                );
                return -int256(_clamp(min, uint256(-hedgeDeviationInTokens), max));
            }
        }
        return 0;
    }

    function _isWithdrawRequestExecuted(
        WithdrawRequestState memory withdrawRequest,
        uint256 pendingDeutilization,
        uint256 totalSupply,
        uint256 accRequestedWithdrawAssets,
        uint256 proccessedWithdrawAssets,
        StrategyStatus status
    ) private pure returns (bool isExecuted, bool isLast) {
        // separate worflow for last withdraw
        // check if current withdrawRequest is last withdraw
        if (totalSupply == 0 && withdrawRequest.accRequestedWithdrawAssets == accRequestedWithdrawAssets) {
            isLast = true;
        }
        if (isLast) {
            // last withdraw is claimable when deutilization is complete
            isExecuted = pendingDeutilization == 0 && status == StrategyStatus.IDLE;
        } else {
            isExecuted = withdrawRequest.accRequestedWithdrawAssets <= proccessedWithdrawAssets;
        }

        return (isExecuted, isLast);
    }

    /// @dev collateral adjustment for rebalancing
    /// currentLeverage = notional / collateral
    /// notional = currentLeverage * collateral
    /// targetLeverage = notional / targetCollateral
    /// targetCollateral = notional / targetLeverage
    /// targetCollateral = collateral * currentLeverage  / targetLeverage
    function _calculateDeltaCollateralForRebalance(
        IPositionManager _positionManager,
        uint256 _currentLeverage,
        uint256 _targetLeverage
    ) internal view returns (uint256) {
        uint256 positionNetBalance = _positionManager.positionNetBalance();
        uint256 targetCollateral = positionNetBalance.mulDiv(_currentLeverage, _targetLeverage);
        uint256 deltaCollateral;
        if (_currentLeverage > _targetLeverage) {
            deltaCollateral = targetCollateral - positionNetBalance;
        } else {
            deltaCollateral = positionNetBalance - targetCollateral;
        }
        return deltaCollateral;
    }

    function positionManager() external view returns (address) {
        return address(_getBasisStrategyStorage().positionManager);
    }

    function oracle() external view returns (address) {
        return address(_getBasisStrategyStorage().oracle);
    }

    function asset() external view returns (address) {
        return address(_getBasisStrategyStorage().vault.asset());
    }

    function product() external view returns (address) {
        return address(_getBasisStrategyStorage().product);
    }

    function strategyStatus() external view returns (StrategyStatus) {
        return _getBasisStrategyStorage().strategyStatus;
    }
}
