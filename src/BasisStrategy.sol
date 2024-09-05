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
import {IStrategyConfig} from "src/interfaces/IStrategyConfig.sol";

import {InchAggregatorV6Logic} from "src/libraries/inch/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";
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
        uint256 totalSupply;
        bool processingRebalanceDown;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.BasisStrategy
    struct BasisStrategyStorage {
        // addresses
        IERC20 product;
        IERC20 asset;
        ILogarithmVault vault;
        IPositionManager positionManager;
        IOracle oracle;
        address operator;
        address forwarder;
        address config;
        // leverage state
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
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
        address _config,
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
        if (
            _config == address(0) || IOracle(_oracle).getAssetPrice(_asset) == 0
                || IOracle(_oracle).getAssetPrice(_product) == 0
        ) revert();

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        $.product = IERC20(_product);
        $.asset = IERC20(_asset);
        $.vault = ILogarithmVault(_vault);
        $.oracle = IOracle(_oracle);
        $.operator = _operator;
        $.config = _config;

        _setManualSwapPath(_assetToProductSwapPath, _asset, _product);
        _setLeverages(_targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
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

    function _setLeverages(
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage
    ) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (_targetLeverage == 0) revert();
        $.targetLeverage = _targetLeverage;
        if (_minLeverage >= _targetLeverage) revert();
        $.minLeverage = _minLeverage;
        if (_maxLeverage <= _targetLeverage) revert();
        $.maxLeverage = _maxLeverage;
        if (_safeMarginLeverage <= _maxLeverage) revert();
        $.safeMarginLeverage = _safeMarginLeverage;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS   
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

    function setOperator(address _operator) external onlyOwner {
        if (_operator == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getBasisStrategyStorage().operator = _operator;
    }

    function setLeverages(
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage
    ) external onlyOwner {
        _setLeverages(_targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
    }

    function unpause() external onlyOwner {
        // callable only when status is KEEPING
        require(_getBasisStrategyStorage().strategyStatus == StrategyStatus.KEEPING);
        _getBasisStrategyStorage().strategyStatus = StrategyStatus.IDLE;
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
        uint256 idleAssets = _vault.idleAssets();
        uint256 totalSupply = _vault.totalSupply();
        address _asset = address($.asset);
        uint256 _targetLeverage = $.targetLeverage;
        bool _processingRebalanceDown = $.processingRebalanceDown;

        uint256 pendingUtilization =
            _pendingUtilization(totalSupply, idleAssets, _targetLeverage, _processingRebalanceDown);
        if (pendingUtilization == 0) {
            revert Errors.ZeroPendingUtilization();
        }

        amount = amount > pendingUtilization ? pendingUtilization : amount;

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 amountOut;
        IERC20(_asset).safeTransferFrom(address(_vault), address(this), amount);
        if (swapType == SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, _asset, address($.product), true, swapData);
            if (!success) {
                emit SwapFailed();
                $.strategyStatus = StrategyStatus.IDLE;
                return;
            }
        } else if (swapType == SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, $.assetToProductSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        uint256 pendingIncreaseCollateral_ =
            _pendingIncreaseCollateral(idleAssets, _targetLeverage, _processingRebalanceDown);
        uint256 collateralDeltaAmount = pendingIncreaseCollateral_.mulDiv(amount, pendingUtilization);
        // (uint256 min,) = $.positionManager.increaseCollateralMinMax();
        if (!_adjustPosition(amountOut, collateralDeltaAmount, true)) {
            // @fix Numa: we don't need to do swap back, it would be better to simply revert the transaction if
            // _adjustPosition returns false (both size and collateral are clamped to zero).
            // if only collateralDeltaAmount is clamped to zero then _adjustPosition will just skip requesting
            // collateral, which is fine for small amounts, increase in leverage would be insignificant

            // if increasing collateral is smaller than min
            // or if position adjustment request is failed
            // then revert utilizing
            // this is because only increasing size without collateral resulted in
            // increasing the position's leverage

            revert Errors.ZeroAmountUtilization();
        } else {
            $.strategyStatus = StrategyStatus.UTILIZING;
            emit UpdateStrategyStatus(StrategyStatus.UTILIZING);
            emit Utilize(msg.sender, amount, amountOut);
        }
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
        address _asset = address($.asset);
        address _product = address($.product);
        uint256 totalSupply = _vault.totalSupply();

        // actual deutilize amount is min of amount, product balance and pending deutilization
        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                totalSupply: totalSupply,
                processingRebalanceDown: _processingRebalanceDown
            })
        );

        amount = amount > pendingDeutilization_ ? pendingDeutilization_ : amount;

        (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
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
            // @note Numa: relativeThreshold and absoluteThreshold are used introduced to prevent leaving dust deutilization
            // in the strategy. If deutilization amount is over relativeThreshold or absoluteThreshold, then the strategy
            // should behave like it is a full deutilize.
            uint256 relativeThreshold = pendingDeutilization_.mulDiv(
                Constants.FLOAT_PRECISION - config().deutilizationThreshold(), Constants.FLOAT_PRECISION
            );
            (, uint256 absoluteThreshold) = pendingDeutilization_.trySub(min);
            if (amount > relativeThreshold || amount > absoluteThreshold) {
                // when full deutilizing
                // @fix Numa: we should not guarantee that all withdraw requests are processed after full deutilization.
                // In case of full deutilization, we only send collateral decrease request if it greater then Min.
                // In prod we will have minCollateralDecrease around 500 USDC, so that execution cost would be below 0.2%.
                // If there is a very small withdraw request, it should not be processed with full deutilization.
                // With small vault totalAssets 500 USDC can create signifficant leverage impact.
                // We would process such small withdraws manually be making deposits once per day to match withdraw requests.
                // We can skip clamping here as it will be done in the _adjustPosition function.

                if (totalSupply == 0) {
                    // in case of redeeming all by users, close hedge position
                    amount = type(uint256).max;
                    collateralDeltaAmount = type(uint256).max;
                    $.pendingDecreaseCollateral = 0;
                } else {
                    // @fix Numa: if collateralDeltaAmount will be clamped to 0, then we need to reflect it in pendingDecreaseCollateral
                    (min, max) = _positionManager.decreaseCollateralMinMax();
                    int256 totalPendingWithdraw = $.vault.totalPendingWithdraw();
                    uint256 pendingWithdraw = totalPendingWithdraw > 0 ? uint256(totalPendingWithdraw) : 0;
                    collateralDeltaAmount = _clamp(min, pendingWithdraw, max);
                    $.pendingDecreaseCollateral = pendingWithdraw - collateralDeltaAmount;
                }

                // pendingDecreaseCollateral is used when partial deutilizing
                // when full deutilization, we don't need
            } else {
                // when partial deutilizing
                uint256 positionNetBalance = _positionManager.positionNetBalance();
                uint256 _pendingDecreaseCollateral = $.pendingDecreaseCollateral;
                if (_pendingDecreaseCollateral > 0) {
                    (, positionNetBalance) = positionNetBalance.trySub(_pendingDecreaseCollateral);
                }
                uint256 positionSizeInTokens = _positionManager.positionSizeInTokens();
                uint256 collateralDeltaToDecrease = positionNetBalance.mulDiv(amount, positionSizeInTokens);
                collateralDeltaToDecrease += _pendingDecreaseCollateral;
                uint256 limitDecreaseCollateral = _positionManager.limitDecreaseCollateral();
                if (collateralDeltaToDecrease < limitDecreaseCollateral) {
                    $.pendingDecreaseCollateral = collateralDeltaToDecrease;
                } else {
                    collateralDeltaAmount = collateralDeltaToDecrease;
                }
            }
        }

        // the return value of this operation should be true, due to above checks
        _adjustPosition(amount, collateralDeltaAmount, false);

        $.strategyStatus = StrategyStatus.DEUTILIZING;
        emit UpdateStrategyStatus(StrategyStatus.DEUTILIZING);

        emit Deutilize(msg.sender, amount, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @notice anyone can call this to process
    /// asset balance of this contract for the pending withdrawals
    /// Note: has effect only when idle
    function processAssetsToWithdraw() public {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if ($.strategyStatus == StrategyStatus.IDLE) {
            _processAssetsToWithdraw(address($.asset), $.vault);
        }
    }

    function checkUpkeep(bytes memory) public view virtual returns (bool upkeepNeeded, bytes memory performData) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if ($.strategyStatus != StrategyStatus.IDLE) {
            return (upkeepNeeded, performData);
        }

        ILogarithmVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;

        uint256 currentLeverage = _positionManager.currentLeverage();
        bool _processingRebalanceDown = $.processingRebalanceDown;

        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;
        bool decreaseCollateral;

        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded) =
            _checkRebalance(currentLeverage, $.minLeverage, $.maxLeverage, $.safeMarginLeverage);

        // check if strategy is in rebalancing down and currentLeverage is not near to target
        if (!rebalanceDownNeeded && _processingRebalanceDown) {
            (, rebalanceDownNeeded) =
                _checkNeedRebalance(currentLeverage, $.targetLeverage, config().rebalanceDeviationThreshold());
        }

        // perform upkeep only when deltaCollateralToDecrease is more than and equal to limit amount
        if (rebalanceUpNeeded) {
            uint256 deltaCollateralToDecrease = _calculateDeltaCollateralForRebalance(
                _positionManager.positionNetBalance(), currentLeverage, $.targetLeverage
            );
            uint256 limitDecreaseCollateral = _positionManager.limitDecreaseCollateral();
            rebalanceUpNeeded = deltaCollateralToDecrease >= limitDecreaseCollateral;
        }

        // deutilize when idle assets are not enough to increase collateral
        // and when processingRebalanceDown is true
        // and when deleverageNeeded is false
        if (rebalanceDownNeeded && _processingRebalanceDown && !deleverageNeeded) {
            uint256 idleAssets = _vault.idleAssets();
            uint256 assetsToWithdraw = $.asset.balanceOf(address(this));
            uint256 assetsToIncrease = idleAssets + assetsToWithdraw;
            (uint256 minIncreaseCollateral,) = _positionManager.increaseCollateralMinMax();
            rebalanceDownNeeded = assetsToIncrease != 0 && assetsToIncrease >= minIncreaseCollateral;
        }

        if (rebalanceDownNeeded) {
            upkeepNeeded = true;
        } else {
            hedgeDeviationInTokens =
                _checkHedgeDeviation(_positionManager, address($.product), config().hedgeDeviationThreshold());
            if (hedgeDeviationInTokens != 0) {
                upkeepNeeded = true;
            } else {
                positionManagerNeedKeep = _positionManager.needKeep();
                if (positionManagerNeedKeep) {
                    upkeepNeeded = true;
                } else {
                    (uint256 minDecreaseCollateral,) = _positionManager.decreaseCollateralMinMax();
                    if (minDecreaseCollateral != 0 && $.pendingDecreaseCollateral >= minDecreaseCollateral) {
                        uint256 pendingDeutilization_ = _pendingDeutilization(
                            InternalPendingDeutilization({
                                positionManager: _positionManager,
                                asset: address($.asset),
                                product: address($.product),
                                totalSupply: _vault.totalSupply(),
                                processingRebalanceDown: false
                            })
                        );
                        if (pendingDeutilization_ == 0) {
                            decreaseCollateral = true;
                            upkeepNeeded = true;
                        }
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
            IERC20 _asset = $.asset;
            uint256 currentLeverage = _positionManager.currentLeverage();
            uint256 idleAssets = _vault.idleAssets();
            uint256 assetsToWithdraw = _asset.balanceOf(address(this));
            uint256 assetsToIncrease = idleAssets + assetsToWithdraw;
            uint256 deltaCollateralToIncrease = _calculateDeltaCollateralForRebalance(
                _positionManager.positionNetBalance(), currentLeverage, $.targetLeverage
            );
            (uint256 minIncreaseCollateral,) = _positionManager.increaseCollateralMinMax();

            if (deltaCollateralToIncrease < minIncreaseCollateral) deltaCollateralToIncrease = minIncreaseCollateral;

            if (deleverageNeeded && (deltaCollateralToIncrease > assetsToIncrease)) {
                (, uint256 deltaLeverage) = currentLeverage.trySub($.maxLeverage);
                uint256 amount = _positionManager.positionSizeInTokens().mulDiv(deltaLeverage, currentLeverage);
                (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
                // @issue amount can be 0 because of clamping that breaks emergency rebalance down
                amount = _clamp(min, amount, max);
                if (amount > 0) {
                    uint256 amountOut = ManualSwapLogic.swap(amount, $.productToAssetSwapPath);
                    $.pendingDeutilizedAssets = amountOut;
                    // produced asset shouldn't go to idle until position size is decreased
                    _adjustPosition(amount, 0, false);
                } else {
                    $.strategyStatus = StrategyStatus.IDLE;
                }
            } else {
                // prioritize idleAssets to do rebalancing up
                if (idleAssets < deltaCollateralToIncrease) {
                    uint256 shortfall = deltaCollateralToIncrease - idleAssets;
                    if (shortfall > assetsToWithdraw) {
                        $.asset.safeTransfer(address($.vault), assetsToWithdraw);
                        if (!_adjustPosition(0, assetsToIncrease, true)) $.strategyStatus = StrategyStatus.IDLE;
                    } else {
                        $.asset.safeTransfer(address($.vault), shortfall);
                        if (!_adjustPosition(0, deltaCollateralToIncrease, true)) {
                            $.strategyStatus = StrategyStatus.IDLE;
                        }
                    }
                } else {
                    if (!_adjustPosition(0, deltaCollateralToIncrease, true)) {
                        $.strategyStatus = StrategyStatus.IDLE;
                    }
                }
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
            if (!_adjustPosition(0, $.pendingDecreaseCollateral, false)) {
                $.strategyStatus = StrategyStatus.IDLE;
            }
        } else if (rebalanceUpNeeded) {
            IPositionManager _positionManager = $.positionManager;
            uint256 deltaCollateralToDecrease = _calculateDeltaCollateralForRebalance(
                _positionManager.positionNetBalance(), _positionManager.currentLeverage(), $.targetLeverage
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
            _afterDecreasePosition(params);
        }

        $.strategyStatus = StrategyStatus.IDLE;

        emit UpdateStrategyStatus(StrategyStatus.IDLE);

        emit AfterAdjustPosition(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    function pendingUtilizations()
        external
        view
        returns (uint256 pendingUtilizationInAsset, uint256 pendingDeutilizationInProduct)
    {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (upkeepNeeded) return (0, 0);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        // when strategy is in processing, return 0
        // so that operator doesn't need to take care of status
        if ($.strategyStatus != StrategyStatus.IDLE) {
            return (0, 0);
        }

        ILogarithmVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;
        uint256 totalSupply = _vault.totalSupply();
        address _asset = address($.asset);
        address _product = address($.product);
        uint256 idleAssets = _vault.idleAssets();
        bool _processingRebalanceDown = $.processingRebalanceDown;
        pendingUtilizationInAsset =
            _pendingUtilization(totalSupply, idleAssets, $.targetLeverage, _processingRebalanceDown);
        pendingDeutilizationInProduct = _pendingDeutilization(
            InternalPendingDeutilization({
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                totalSupply: totalSupply,
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

        if (sizeDeltaInTokens > 0) {
            uint256 min;
            uint256 max;
            if (isIncrease) (min, max) = $.positionManager.increaseSizeMinMax();
            else (min, max) = $.positionManager.decreaseSizeMinMax();

            sizeDeltaInTokens = _clamp(min, sizeDeltaInTokens, max);
        }

        if (collateralDeltaAmount > 0) {
            uint256 min;
            uint256 max;
            if (isIncrease) (min, max) = $.positionManager.increaseCollateralMinMax();
            else (min, max) = $.positionManager.decreaseCollateralMinMax();
            collateralDeltaAmount = _clamp(min, collateralDeltaAmount, max);
        }

        if (isIncrease && collateralDeltaAmount > 0) {
            $.asset.safeTransferFrom(address($.vault), address($.positionManager), collateralDeltaAmount);
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
            (bool exceedsThreshold, int256 sizeDeviation) = _checkResponseDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, config().responseDeviationThreshold()
            );
            if (exceedsThreshold) {
                $.strategyStatus = StrategyStatus.PAUSE;
                if (sizeDeviation < 0) {
                    // revert spot to make hedge size the same as spot
                    uint256 amountOut = ManualSwapLogic.swap(uint256(-sizeDeviation), $.productToAssetSwapPath);
                    IERC20($.asset).safeTransfer(address($.vault), amountOut);
                }
            }
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold, int256 collateralDeviation) = _checkResponseDeviation(
                responseParams.collateralDeltaAmount,
                requestParams.collateralDeltaAmount,
                config().responseDeviationThreshold()
            );
            if (exceedsThreshold) {
                $.strategyStatus = StrategyStatus.PAUSE;
                if (collateralDeviation < 0) {
                    IERC20($.asset).safeTransferFrom(
                        address($.positionManager), address($.vault), uint256(-collateralDeviation)
                    );
                }
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.positionManager.currentLeverage(), $.targetLeverage, config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = $.processingRebalanceDown && rebalanceDownNeeded;
        }
    }

    function _afterDecreasePosition(IPositionManager.AdjustPositionPayload calldata responseParams) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.AdjustPositionPayload memory requestParams = $.requestParams;
        bool _processingRebalanceDown = $.processingRebalanceDown;
        ILogarithmVault _vault = $.vault;
        IERC20 _asset = $.asset;

        if (requestParams.sizeDeltaInTokens == type(uint256).max) {
            // when closing hedge
            requestParams.sizeDeltaInTokens = responseParams.sizeDeltaInTokens;
            requestParams.collateralDeltaAmount = responseParams.collateralDeltaAmount;
        }

        if (requestParams.sizeDeltaInTokens > 0) {
            uint256 _pendingDeutilizedAssets = $.pendingDeutilizedAssets;
            delete $.pendingDeutilizedAssets;
            (bool exceedsThreshold, int256 sizeDeviation) = _checkResponseDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, config().responseDeviationThreshold()
            );
            if (exceedsThreshold) {
                $.strategyStatus = StrategyStatus.PAUSE;
                if (sizeDeviation < 0) {
                    uint256 sizeDeviationAbs = uint256(-sizeDeviation);
                    uint256 assetsToBeReverted;
                    if (sizeDeviationAbs == requestParams.sizeDeltaInTokens) {
                        assetsToBeReverted = _pendingDeutilizedAssets;
                    } else {
                        assetsToBeReverted =
                            _pendingDeutilizedAssets.mulDiv(sizeDeviationAbs, requestParams.sizeDeltaInTokens);
                    }
                    ManualSwapLogic.swap(assetsToBeReverted, $.assetToProductSwapPath);
                }
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.positionManager.currentLeverage(), $.targetLeverage, config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = _processingRebalanceDown && rebalanceDownNeeded;
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold,) = _checkResponseDeviation(
                responseParams.collateralDeltaAmount,
                requestParams.collateralDeltaAmount,
                config().responseDeviationThreshold()
            );
            if (exceedsThreshold) {
                $.strategyStatus = StrategyStatus.PAUSE;
            }
        }

        if (responseParams.collateralDeltaAmount > 0) {
            // the case when deutilizing for withdrawls and rebalancing Up
            (, $.pendingDecreaseCollateral) = $.pendingDecreaseCollateral.trySub(responseParams.collateralDeltaAmount);
            _asset.safeTransferFrom(address($.positionManager), address(this), responseParams.collateralDeltaAmount);
        }
        // process withdraw request
        _processAssetsToWithdraw(address(_asset), _vault);
    }

    /// @dev process assetsToWithdraw for the withdraw requests
    function _processAssetsToWithdraw(address _asset, ILogarithmVault _vault) private {
        uint256 assetsToWithdraw = IERC20(_asset).balanceOf(address(this));
        if (assetsToWithdraw == 0) return;
        IERC20(_asset).safeTransfer(address(_vault), assetsToWithdraw);
        _vault.processPendingWithdrawRequests();
    }

    function _pendingUtilization(
        uint256 totalSupply,
        uint256 idleAssets,
        uint256 _targetLeverage,
        bool _processingRebalanceDown
    ) public pure returns (uint256) {
        // don't use utilze function when rebalancing or when totalSupply is zero
        if (totalSupply == 0 || _processingRebalanceDown) {
            return 0;
        } else {
            return idleAssets.mulDiv(_targetLeverage, Constants.FLOAT_PRECISION + _targetLeverage);
        }
    }

    function _pendingIncreaseCollateral(uint256 idleAssets, uint256 _targetLeverage, bool _processingRebalanceDown)
        private
        pure
        returns (uint256)
    {
        return _processingRebalanceDown
            ? idleAssets
            : idleAssets.mulDiv(Constants.FLOAT_PRECISION, Constants.FLOAT_PRECISION + _targetLeverage, Math.Rounding.Ceil);
    }

    function _pendingDeutilization(InternalPendingDeutilization memory params) private view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        uint256 productBalance = IERC20(params.product).balanceOf(address(this));
        if (params.totalSupply == 0) return productBalance;

        uint256 positionSizeInTokens = params.positionManager.positionSizeInTokens();
        uint256 positionSizeInAssets = $.oracle.convertTokenAmount(params.product, params.asset, positionSizeInTokens);
        uint256 positionNetBalance = params.positionManager.positionNetBalance();
        if (positionSizeInAssets == 0 || positionNetBalance == 0) return 0;

        int256 totalPendingWithdraw = $.vault.totalPendingWithdraw();
        uint256 deutilization;
        if (params.processingRebalanceDown) {
            // for rebalance
            uint256 currentLeverage = params.positionManager.currentLeverage();
            uint256 _targetLeverage = $.targetLeverage;
            if (currentLeverage > _targetLeverage) {
                // calculate deutilization product
                // when totalPendingWithdraw is enough big to prevent increasing collalteral
                uint256 deltaLeverage = currentLeverage - _targetLeverage;
                deutilization = positionSizeInTokens.mulDiv(deltaLeverage, currentLeverage);
                uint256 deutilizationInAsset = $.oracle.convertTokenAmount(params.product, params.asset, deutilization);
                uint256 totalPendingWithdrawAbs = totalPendingWithdraw < 0 ? 0 : uint256(totalPendingWithdraw);

                // when totalPendingWithdraw is not enough big to prevent increasing collalteral
                if (totalPendingWithdrawAbs < deutilizationInAsset) {
                    uint256 num = deltaLeverage + _targetLeverage.mulDiv(totalPendingWithdrawAbs, positionNetBalance);
                    uint256 den = currentLeverage + _targetLeverage.mulDiv(positionSizeInAssets, positionNetBalance);
                    deutilization = positionSizeInTokens.mulDiv(num, den);
                }
            }
        } else {
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

    /// @dev should be called under the condition that valueReq != 0
    /// Note: check if response of position adjustment is in allowed deviation
    function _checkResponseDeviation(uint256 valueResp, uint256 valueReq, uint256 _responseDeviationThreshold)
        internal
        pure
        returns (bool exceedsThreshold, int256 deviation)
    {
        deviation = valueResp.toInt256() - valueReq.toInt256();
        exceedsThreshold = (deviation < 0 ? uint256(-deviation) : uint256(deviation)).mulDiv(
            Constants.FLOAT_PRECISION, valueReq
        ) > _responseDeviationThreshold;
        return (exceedsThreshold, deviation);
    }

    /// @dev check if current leverage is not near to the target leverage
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

    /// @dev check if current leverage is out of the min and max leverage
    function _checkRebalance(
        uint256 currentLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage
    ) internal pure returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded) {
        if (currentLeverage > _maxLeverage) {
            rebalanceDownNeeded = true;
            if (currentLeverage > _safeMarginLeverage) {
                deleverageNeeded = true;
            }
        }

        if (currentLeverage != 0 && currentLeverage < _minLeverage) {
            rebalanceUpNeeded = true;
        }
    }

    /// @param _positionManager IPositionManager
    /// @param _product address
    /// @param _hedgeDeviationThreshold uint256
    ///
    /// @return hedge deviation of int type
    function _checkHedgeDeviation(IPositionManager _positionManager, address _product, uint256 _hedgeDeviationThreshold)
        internal
        view
        returns (int256)
    {
        uint256 spotExposure = IERC20(_product).balanceOf(address(this));
        uint256 hedgeExposure = _positionManager.positionSizeInTokens();
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return 0;
            } else {
                return hedgeExposure.toInt256();
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
                return int256(_clamp(min, uint256(hedgeDeviationInTokens), max));
            } else {
                (uint256 min, uint256 max) = _positionManager.increaseSizeMinMax();
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
        uint256 positionNetBalance,
        uint256 _currentLeverage,
        uint256 _targetLeverage
    ) internal pure returns (uint256) {
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

    function operator() external view returns (address) {
        return _getBasisStrategyStorage().operator;
    }

    function forwarder() external view returns (address) {
        return _getBasisStrategyStorage().forwarder;
    }

    function asset() external view returns (address) {
        return address(_getBasisStrategyStorage().asset);
    }

    function product() external view returns (address) {
        return address(_getBasisStrategyStorage().product);
    }

    function config() public view returns (IStrategyConfig) {
        return IStrategyConfig(_getBasisStrategyStorage().config);
    }

    function strategyStatus() external view returns (StrategyStatus) {
        return _getBasisStrategyStorage().strategyStatus;
    }

    function pendingIncreaseCollateral() external view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        return _pendingIncreaseCollateral($.vault.idleAssets(), $.targetLeverage, $.processingRebalanceDown);
    }

    function pendingDecreaseCollateral() external view returns (uint256) {
        return _getBasisStrategyStorage().pendingDecreaseCollateral;
    }

    function processingRebalance() external view returns (bool) {
        return _getBasisStrategyStorage().processingRebalanceDown;
    }
}
