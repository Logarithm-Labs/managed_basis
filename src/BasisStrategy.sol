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
import {ILogarithmVault} from "src/interfaces/ILogarithmVault.sol";
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

    struct InternalPendingDeutilization {
        IPositionManager positionManager;
        address asset;
        address product;
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
        ILogarithmVault vault;
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
        // pending state
        uint256 pendingDeutilizedAssets;
        uint256 pendingDecreaseCollateral;
        // status state
        StrategyStatus strategyStatus;
        bool processingRebalanceDown;
        // manual swap state
        mapping(address => bool) isSwapPool;
        address[] productToAssetSwapPath;
        address[] assetToProductSwapPath;
        // adjust position
        IPositionManager.AdjustPositionPayload requestParams;
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

    event UpdatePendingUtilization();

    event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event Deutilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    event SwapFailed();

    event UpdateStrategyStatus(StrategyStatus status);

    event AfterAdjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

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

        address _asset = ILogarithmVault(_vault).asset();

        // validation oracle
        if (IOracle(_oracle).getAssetPrice(_asset) == 0 || IOracle(_oracle).getAssetPrice(_product) == 0) revert();

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        $.product = IERC20(_product);
        $.vault = ILogarithmVault(_vault);
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

        ILogarithmVault _vault = $.vault;
        address _asset = _vault.asset();
        address _product = address($.product);

        uint256 idleAssets = _vault.idleAssets();
        uint256 _targetLeverage = $.targetLeverage;

        // actual utilize amount is min of amount, idle assets and pending utilization
        uint256 pendingUtilization = _pendingUtilization(idleAssets, _targetLeverage, $.processingRebalanceDown);
        if (pendingUtilization == 0) {
            revert Errors.ZeroPendingUtilization();
        }

        amount = amount > pendingUtilization ? pendingUtilization : amount;

        (uint256 min, uint256 max) = $.positionManager.increaseSizeMinMax();
        (min, max) = (
            min == 0 ? 0 : $.oracle.convertTokenAmount(_asset, _product, min),
            max == type(uint256).max ? type(uint256).max : $.oracle.convertTokenAmount(_asset, _product, max)
        );
        amount = _clamp(min, amount, max);

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

        uint256 pendingIncreaseCollateral_ = _pendingIncreaseCollateral(idleAssets, _targetLeverage);
        uint256 collateralDeltaAmount;
        if (pendingIncreaseCollateral_ > 0) {
            collateralDeltaAmount = pendingIncreaseCollateral_.mulDiv(amount, pendingUtilization);
            (min, max) = $.positionManager.increaseCollateralMinMax();
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
        ILogarithmVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 totalSupply = _vault.totalSupply();

        // actual deutilize amount is min of amount, product balance and pending deutilization
        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                processingRebalanceDown: _processingRebalanceDown
            })
        );

        amount = amount > pendingDeutilization_ ? pendingDeutilization_ : amount;

        (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
        (min, max) = (
            min == 0 ? 0 : $.oracle.convertTokenAmount(_asset, _product, min),
            max == type(uint256).max ? type(uint256).max : $.oracle.convertTokenAmount(_asset, _product, max)
        );
        amount = _clamp(min, amount, max);

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        if (swapType == SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, _asset, _product, false, swapData);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = StrategyStatus.IDLE;
                emit UpdateStrategyStatus(StrategyStatus.IDLE);
                return;
            }
        } else if (swapType == SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, $.productToAssetSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        $.pendingDeutilizedAssets = amountOut;

        uint256 collateralDeltaAmount;
        if (!_processingRebalanceDown) {
            if (amount == pendingDeutilization_) {
                int256 totalPendingWithdraw = $.vault.totalPendingWithdraw();
                collateralDeltaAmount = totalPendingWithdraw > 0 ? uint256(totalPendingWithdraw) : 0;
                if (totalSupply != 0) {
                    // in case of not last withdrawing, full deutilization should guarantee that
                    // all withdraw requests are processed
                    // so if collateralDeltaAmount is smaller than min, then increase it by min
                    (min,) = _positionManager.decreaseCollateralMinMax();
                    if (collateralDeltaAmount < min) collateralDeltaAmount = min;
                }
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

        ILogarithmVault _vault = $.vault;
        address _asset = _vault.asset();
        uint256 idleAssets = _vault.idleAssets();
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
                idleAssets: idleAssets,
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
            ILogarithmVault _vault = $.vault;
            address _asset = _vault.asset();
            uint256 idleAssets = _vault.idleAssets();
            uint256 currentLeverage = _positionManager.currentLeverage();
            uint256 targetLeverage = $.targetLeverage;
            uint256 deltaCollateralToIncrease =
                _calculateDeltaCollateralForRebalance(_positionManager, currentLeverage, targetLeverage);
            (uint256 minIncreaseCollateral,) = _positionManager.increaseCollateralMinMax();

            if (deleverageNeeded && (deltaCollateralToIncrease > idleAssets || minIncreaseCollateral > idleAssets)) {
                address _product = address($.product);
                uint256 amount = _pendingDeutilization(
                    InternalPendingDeutilization({
                        positionManager: _positionManager,
                        asset: _asset,
                        product: _product,
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
                    idleAssets > deltaCollateralToIncrease ? deltaCollateralToIncrease : idleAssets;
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
    function afterAdjustPosition(IPositionManager.AdjustPositionPayload calldata params) external onlyPositionManager {
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
        ILogarithmVault _vault = $.vault;
        address _asset = _vault.asset();
        address _product = address($.product);
        uint256 idleAssets = _vault.idleAssets();
        bool _processingRebalanceDown = $.processingRebalanceDown;
        pendingUtilizationInAsset = _pendingUtilization(idleAssets, $.targetLeverage, _processingRebalanceDown);
        pendingDeutilizationInProduct = _pendingDeutilization(
            InternalPendingDeutilization({
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                processingRebalanceDown: _processingRebalanceDown
            })
        );
        return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
    }

    /// @dev return assets that are utilized across spot and hedge
    function utilizedAssets() public view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        address _product = address($.product);
        uint256 productBalance = IERC20(_product).balanceOf(address(this));
        uint256 productValueInAssets = $.oracle.convertTokenAmount(_product, $.vault.asset(), productBalance);
        return productValueInAssets + $.positionManager.positionNetBalance();
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
            IPositionManager.AdjustPositionPayload memory requestParams = IPositionManager.AdjustPositionPayload({
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

    function _afterIncreasePosition(IPositionManager.AdjustPositionPayload calldata responseParams) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.AdjustPositionPayload memory requestParams = $.requestParams;

        if (requestParams.sizeDeltaInTokens > 0) {
            (bool isWrongPositionSize, int256 sizeDeltaDeviationInTokens) = _checkResultedPositionSize(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, $.hedgeDeviationThreshold
            );
            if (isWrongPositionSize) {
                // status = StrategyStatus.PAUSE;
                if (sizeDeltaDeviationInTokens < 0) {
                    ILogarithmVault _vault = $.vault;
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
            ILogarithmVault _vault = $.vault;
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
        IPositionManager.AdjustPositionPayload calldata responseParams,
        StrategyStatus status
    ) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.AdjustPositionPayload memory requestParams = $.requestParams;
        bool _processingRebalanceDown = $.processingRebalanceDown;
        ILogarithmVault _vault = $.vault;
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
                _vault.processPendingWithdrawRequests();
            } else {
                // process withdraw request
                uint256 assetsToWithdraw = IERC20(_asset).balanceOf(address(this));
                IERC20(_asset).safeTransfer(address(_vault), assetsToWithdraw);
                uint256 processedAssets = _vault.processPendingWithdrawRequests();
                // collect assets back to strategy except the processed assets
                (, uint256 collectingAssets) = assetsToWithdraw.trySub(processedAssets);
                if (collectingAssets > 0) {
                    IERC20(_asset).safeTransferFrom(address(_vault), address(this), collectingAssets);
                }
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
                _vault.processPendingWithdrawRequests();
            } else {
                IERC20(_asset).safeTransferFrom(
                    address($.positionManager), address(this), responseParams.collateralDeltaAmount
                );
                uint256 assetsToWithdraw = IERC20(_asset).balanceOf(address(this));
                IERC20(_asset).safeTransfer(address(_vault), assetsToWithdraw);
                uint256 processedAssets = _vault.processPendingWithdrawRequests();
                // collect assets back to strategy except the processed assets
                (, uint256 collectingAssets) = assetsToWithdraw.trySub(processedAssets);
                if (collectingAssets > 0) {
                    IERC20(_asset).safeTransferFrom(address(_vault), address(this), collectingAssets);
                }
            }
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

    function _pendingUtilization(uint256 idleAssets, uint256 _targetLeverage, bool _processingRebalanceDown)
        public
        pure
        returns (uint256)
    {
        // don't use utilze function when rebalancing
        return _processingRebalanceDown
            ? 0
            : idleAssets.mulDiv(_targetLeverage, Constants.FLOAT_PRECISION + _targetLeverage);
    }

    function _pendingIncreaseCollateral(uint256 idleAssets, uint256 _targetLeverage) private pure returns (uint256) {
        return idleAssets.mulDiv(
            Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + _targetLeverage, Math.Rounding.Ceil
        );
    }

    function _pendingDeutilization(InternalPendingDeutilization memory params) private view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        uint256 productBalance = IERC20(params.product).balanceOf(address(this));
        if ($.vault.totalSupply() == 0) return productBalance;

        uint256 positionSizeInTokens = params.positionManager.positionSizeInTokens();
        uint256 deutilization;
        if (params.processingRebalanceDown) {
            // for rebalance
            uint256 currentLeverage = params.positionManager.currentLeverage();
            uint256 _targeLeverage = $.targetLeverage;
            if (currentLeverage > _targeLeverage) {
                // deltaSizeToDecrease =  positionSize - targetLeverage * positionSize / currentLeverage
                deutilization = positionSizeInTokens - positionSizeInTokens.mulDiv(_targeLeverage, currentLeverage);
            }
        } else {
            uint256 positionSizeInAssets =
                $.oracle.convertTokenAmount(params.product, params.asset, positionSizeInTokens);
            uint256 positionNetBalance = params.positionManager.positionNetBalance();

            if (positionSizeInAssets == 0 || positionNetBalance == 0) return 0;

            int256 totalPendingWithdraw = $.vault.totalPendingWithdraw();

            if (totalPendingWithdraw <= 0) return 0;

            uint256 totalPendingWithdrawAbs = uint256(totalPendingWithdraw);
            uint256 _pendingDecreaseCollateral = $.pendingDecreaseCollateral;

            if (
                _pendingDecreaseCollateral > totalPendingWithdrawAbs
                    || _pendingDecreaseCollateral >= (positionSizeInAssets + positionNetBalance)
            ) {
                return 0;
            }

            deutilization = positionSizeInTokens.mulDiv(
                totalPendingWithdrawAbs - _pendingDecreaseCollateral,
                positionSizeInAssets + positionNetBalance - _pendingDecreaseCollateral
            );
        }

        deutilization = deutilization > productBalance ? productBalance : deutilization;

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

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function vault() external view returns (address) {
        return address(_getBasisStrategyStorage().vault);
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

    function pendingIncreaseCollateral() external view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        return _pendingIncreaseCollateral($.vault.idleAssets(), $.targetLeverage);
    }

    function pendingDecreaseCollateral() external view returns (uint256) {
        return _getBasisStrategyStorage().pendingDecreaseCollateral;
    }

    function processingRebalance() external view returns (bool) {
        return _getBasisStrategyStorage().processingRebalanceDown;
    }
}
