// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutomationCompatibleInterface} from "src/externals/chainlink/interfaces/AutomationCompatibleInterface.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {ILogarithmVault} from "src/vault/ILogarithmVault.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {IStrategyConfig} from "src/strategy/IStrategyConfig.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title BasisStrategy
/// @author Logarithm Labs
/// @notice A basis strategy which hedges spots by opening perpetual positions while receiving funding payments.
/// @dev Deployed according to the upgradeable beacon proxy pattern.
contract BasisStrategy is
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    IBasisStrategy,
    AutomationCompatibleInterface
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                ENUMS   
    //////////////////////////////////////////////////////////////*/

    /// @dev Used to specify strategy's operations.
    enum StrategyStatus {
        IDLE,
        KEEPING,
        UTILIZING,
        PARTIAL_DEUTILIZING,
        FULL_DEUTILIZING
    }

    /// @dev Used to optimize params of deutilization internally.
    struct InternalPendingDeutilization {
        // The address of hedge position manager.
        IPositionManager positionManager;
        // The address of the connected vault's underlying asset.
        address asset;
        // The product address.
        address product;
        // The totalSupply of shares of its connected vault
        uint256 totalSupply;
        // The boolean value of storage variable processingRebalanceDown.
        bool processingRebalanceDown;
        // The boolean value tells wether strategy gets paused of not.
        bool paused;
    }

    /// @dev Used internally as a result of checkUpkeep function.
    struct InternalCheckUpkeepResult {
        // emergency rebalance down when idle assets not enough
        uint256 emergencyDeutilizationAmount;
        // rebalance down by using idle assets
        uint256 deltaCollateralToIncrease;
        // clear processingRebalanceDown storage in case oracle fluctuated
        bool clearProcessingRebalanceDown;
        // none-zero means re-hedge
        int256 hedgeDeviationInTokens;
        // position manager is in need of keeping
        bool positionManagerNeedKeep;
        // process pendingDecreaseCollateral
        bool processPendingDecreaseCollateral;
        // rebalance up by decreasing collateral
        uint256 deltaCollateralToDecrease;
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
        ISpotManager spotManager;
        IPositionManager positionManager;
        IOracle oracle;
        address operator;
        address config;
        // leverage state
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        // pending state
        // used to revert deutilized assets
        uint256 pendingDeutilizedAssets;
        // used to decrease collateral through performUpkeep
        uint256 pendingDecreaseCollateral;
        // status state
        StrategyStatus strategyStatus;
        // used to change deutilization calc method
        bool processingRebalanceDown;
        // adjust position request to be used to check response
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

    /// @dev Emitted when assets are utilized.
    event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta);

    /// @dev Emitted when assets are deutilized.
    event Deutilize(address indexed caller, uint256 productDelta, uint256 assetDelta);

    /// @dev Emitted when the hedge position gets adjusted.
    event PositionAdjusted(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    /// @dev Emitted when leverage config gets changed.
    event LeverageConfigUpdated(
        address indexed account,
        uint256 targetLeverage,
        uint256 minLeverage,
        uint256 maxLeverage,
        uint256 safeMarginLeverage
    );

    /// @dev Emitted when the spot manager is changed.
    event SpotManagerUpdated(address indexed account, address indexed newSpotManager);

    /// @dev Emitted when the position manager is changed.
    event PositionManagerUpdated(address indexed account, address indexed newPositionManager);

    /// @dev Emitted when the operator is changed.
    event OperatorUpdated(address indexed account, address indexed newOperator);

    /// @dev Emitted when strategy is stopped.
    event Stopped(address indexed account);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorize caller if it is authorized one.
    modifier authCaller(address authorized) {
        if (_msgSender() != authorized) {
            revert Errors.CallerNotAuthorized(authorized, _msgSender());
        }
        _;
    }

    /// @dev Authorize caller if it is owner and vault.
    modifier onlyOwnerOrVault() {
        if (_msgSender() != owner() && _msgSender() != vault()) {
            revert Errors.CallerNotOwnerOrVault();
        }
        _;
    }

    /// @dev Validates if strategy is in IDLE status, otherwise reverts calling.
    modifier whenIdle() {
        _validateStrategyStatus(StrategyStatus.IDLE);
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
        uint256 _safeMarginLeverage
    ) external initializer {
        __Ownable_init(_msgSender());

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
        $.config = _config;

        _setOperator(_operator);
        _setLeverages(_targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
    }

    function _setLeverages(
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage
    ) internal {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (_targetLeverage == 0) revert();
        if (targetLeverage() != _targetLeverage) {
            $.targetLeverage = _targetLeverage;
        }
        if (_minLeverage >= _targetLeverage) revert();
        if (minLeverage() != _minLeverage) {
            $.minLeverage = _minLeverage;
        }
        if (_maxLeverage <= _targetLeverage) revert();
        if (maxLeverage() != _maxLeverage) {
            $.maxLeverage = _maxLeverage;
        }
        if (_safeMarginLeverage <= _maxLeverage) revert();
        if (safeMarginLeverage() != _safeMarginLeverage) {
            $.safeMarginLeverage = _safeMarginLeverage;
        }

        emit LeverageConfigUpdated(_msgSender(), _targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
    }

    function _setOperator(address newOperator) internal {
        if (newOperator == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (operator() != newOperator) {
            _getBasisStrategyStorage().operator = newOperator;
            emit OperatorUpdated(_msgSender(), newOperator);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS   
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the spot manager.
    function setSpotManager(address _spotManager) external onlyOwner {
        if (spotManager() != _spotManager) {
            ISpotManager manager = ISpotManager(_spotManager);
            require(manager.asset() == asset() && manager.product() == product());
            _getBasisStrategyStorage().spotManager = manager;
            emit SpotManagerUpdated(_msgSender(), _spotManager);
        }
    }

    /// @notice Sets the position manager.
    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (positionManager() != _positionManager) {
            _getBasisStrategyStorage().positionManager = IPositionManager(_positionManager);
            emit PositionManagerUpdated(_msgSender(), _positionManager);
        }
    }

    /// @notice Sets the operator.
    function setOperator(address newOperator) external onlyOwner {
        _setOperator(newOperator);
    }

    /// @notice Sets the leverages.
    function setLeverages(
        uint256 _targetLeverage,
        uint256 _minLeverage,
        uint256 _maxLeverage,
        uint256 _safeMarginLeverage
    ) external onlyOwner {
        _setLeverages(_targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
    }

    /// @notice Pauses strategy.
    ///
    /// @dev If paused, utilizing and deutilizing for withdrawal are disabled, while upkeep logic keeps working.
    function pause() external onlyOwnerOrVault whenNotPaused {
        _pause();
    }

    /// @notice Unpauses strategy.
    function unpause() external onlyOwnerOrVault whenPaused {
        _unpause();
    }

    /// @notice Stop strategy.
    ///
    /// @dev Pauses and swaps all products back to assets.
    function stop() external onlyOwnerOrVault whenNotPaused {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        delete $.pendingDecreaseCollateral;
        delete $.pendingDeutilizedAssets;
        delete $.processingRebalanceDown;
        _setStrategyStatus(StrategyStatus.FULL_DEUTILIZING);
        ISpotManager _spotManager = $.spotManager;
        _spotManager.sell(_spotManager.exposure(), ISpotManager.SwapType.MANUAL, "");
        _pause();

        emit Stopped(_msgSender());
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE/DEUTILZE   
    //////////////////////////////////////////////////////////////*/

    /// @notice Utilizes assets to increase the spot size.
    ///
    /// @dev Uses assets in vault. Callable only by the operator.
    ///
    /// @param amount The underlying asset amount to be utilized.
    /// @param swapType The swap type in which the underlying asset is swapped.
    /// @param swapData The data used in swapping.
    function utilize(uint256 amount, ISpotManager.SwapType swapType, bytes calldata swapData)
        external
        virtual
        authCaller(operator())
        whenIdle
    {
        _setStrategyStatus(StrategyStatus.UTILIZING);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        ILogarithmVault _vault = $.vault;
        uint256 pendingUtilization = _pendingUtilization(
            _vault.totalSupply(), _vault.idleAssets(), targetLeverage(), processingRebalanceDown(), paused()
        );
        if (pendingUtilization == 0) {
            revert Errors.ZeroPendingUtilization();
        }

        amount = amount > pendingUtilization ? pendingUtilization : amount;

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        ISpotManager _spotManager = $.spotManager;
        IERC20(asset()).safeTransferFrom(address(_vault), address(_spotManager), amount);
        _spotManager.buy(amount, swapType, swapData);
    }

    /// @notice Deutilizes products to decrease the spot size.
    ///
    /// @dev Called when processing withdraw requests, when deleveraging the position, and when there are funding risks.
    /// Callable only by the operator.
    ///
    /// @param amount The product amount to be deutilized.
    /// @param swapType The swap type in which the product is swapped.
    /// @param swapData The data used in swapping.
    function deutilize(uint256 amount, ISpotManager.SwapType swapType, bytes calldata swapData)
        external
        authCaller(operator())
        whenIdle
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        IPositionManager _positionManager = $.positionManager;

        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                positionManager: _positionManager,
                asset: asset(),
                product: product(),
                totalSupply: $.vault.totalSupply(),
                processingRebalanceDown: processingRebalanceDown(),
                paused: paused()
            })
        );

        // cap amount by pendingDeutilization
        // btw pendingDeutilization keeps changing according to the oracle price
        // so cap it only when amount is bigger than it over threshold
        (bool exceedsThreshold, int256 deutilizationDeviation) =
            _checkDeviation(pendingDeutilization_, amount, config().deutilizationThreshold());
        if (exceedsThreshold && deutilizationDeviation < 0) {
            amount = pendingDeutilization_;
        }

        // check if amount is in the possible adjustment range
        (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
        amount = _clamp(min, amount, max);

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        // check if full or partial deutilizing
        // if remaining deutiliization is smaller than min size
        // treat it as full
        (, uint256 absoluteThreshold) = pendingDeutilization_.trySub(min);
        if (!exceedsThreshold || deutilizationDeviation < 0 || amount >= absoluteThreshold) {
            _setStrategyStatus(StrategyStatus.FULL_DEUTILIZING);
        } else {
            _setStrategyStatus(StrategyStatus.PARTIAL_DEUTILIZING);
        }

        $.spotManager.sell(amount, swapType, swapData);
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes assets in this strategy for the withdraw requests.
    ///
    /// @dev Callable by anyone and only when strategy is in the IDLE status.
    function processAssetsToWithdraw() public whenIdle {
        _processAssetsToWithdraw(asset());
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes memory) public view returns (bool upkeepNeeded, bytes memory performData) {
        InternalCheckUpkeepResult memory result = _checkUpkeep();

        upkeepNeeded = result.emergencyDeutilizationAmount > 0 || result.deltaCollateralToIncrease > 0
            || result.clearProcessingRebalanceDown || result.hedgeDeviationInTokens != 0 || result.positionManagerNeedKeep
            || result.processPendingDecreaseCollateral || result.deltaCollateralToDecrease > 0;

        performData = abi.encode(
            result.emergencyDeutilizationAmount,
            result.deltaCollateralToIncrease,
            result.clearProcessingRebalanceDown,
            result.hedgeDeviationInTokens,
            result.positionManagerNeedKeep,
            result.processPendingDecreaseCollateral,
            result.deltaCollateralToDecrease
        );

        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /*performData*/ ) external whenIdle {
        InternalCheckUpkeepResult memory result = _checkUpkeep();

        _setStrategyStatus(StrategyStatus.KEEPING);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if (result.emergencyDeutilizationAmount > 0) {
            $.pendingDecreaseCollateral = 0;
            $.processingRebalanceDown = true;
            $.spotManager.sell(result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, "");
        } else if (result.deltaCollateralToIncrease > 0) {
            $.pendingDecreaseCollateral = 0;
            $.processingRebalanceDown = true;
            uint256 idleAssets = $.vault.idleAssets();
            if (
                !_adjustPosition(
                    0,
                    idleAssets < result.deltaCollateralToIncrease ? idleAssets : result.deltaCollateralToIncrease,
                    true
                )
            ) _setStrategyStatus(StrategyStatus.IDLE);
        } else if (result.clearProcessingRebalanceDown) {
            $.processingRebalanceDown = false;
            _setStrategyStatus(StrategyStatus.IDLE);
        } else if (result.hedgeDeviationInTokens != 0) {
            if (result.hedgeDeviationInTokens > 0) {
                if (!_adjustPosition(uint256(result.hedgeDeviationInTokens), 0, false)) {
                    _setStrategyStatus(StrategyStatus.IDLE);
                }
            } else {
                uint256 hedgeDeviationInTokens = uint256(-result.hedgeDeviationInTokens);
                if (!_adjustPosition(hedgeDeviationInTokens, 0, true)) {
                    _setStrategyStatus(StrategyStatus.IDLE);
                    $.spotManager.sell(hedgeDeviationInTokens, ISpotManager.SwapType.MANUAL, "");
                }
            }
        } else if (result.positionManagerNeedKeep) {
            $.positionManager.keep();
        } else if (result.processPendingDecreaseCollateral) {
            if (!_adjustPosition(0, $.pendingDecreaseCollateral, false)) {
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        } else if (result.deltaCollateralToDecrease > 0) {
            if (!_adjustPosition(0, result.deltaCollateralToDecrease, false)) {
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        } else {
            _setStrategyStatus(StrategyStatus.IDLE);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Called after product is bought.
    function spotBuyCallback(uint256 assetDelta, uint256 productDelta) external authCaller(spotManager()) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if (strategyStatus() == StrategyStatus.UTILIZING) {
            if (productDelta == 0) {
                // fail to buy product
                $.asset.safeTransferFrom(_msgSender(), vault(), assetDelta);
                _setStrategyStatus(StrategyStatus.IDLE);
            } else {
                uint256 collateralDeltaAmount =
                    assetDelta.mulDiv(Constants.FLOAT_PRECISION, targetLeverage(), Math.Rounding.Ceil);
                if (!_adjustPosition(productDelta, collateralDeltaAmount, true)) {
                    ISpotManager(_msgSender()).sell(productDelta, ISpotManager.SwapType.MANUAL, "");
                } else {
                    emit Utilize(_msgSender(), assetDelta, productDelta);
                }
            }
        } else {
            // reverting of deutilizing
            _setStrategyStatus(StrategyStatus.IDLE);
        }
    }

    /// @dev Called after product is sold.
    function spotSellCallback(uint256 assetDelta, uint256 productDelta) external authCaller(spotManager()) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        StrategyStatus status = strategyStatus();
        if (status == StrategyStatus.UTILIZING || status == StrategyStatus.IDLE) {
            // revert utilizing
            ILogarithmVault _vault = $.vault;
            $.asset.safeTransferFrom(_msgSender(), address(_vault), assetDelta);
            if (status == StrategyStatus.UTILIZING) _setStrategyStatus(StrategyStatus.IDLE);
            _vault.processPendingWithdrawRequests();
        } else {
            if (assetDelta == 0) {
                // fail to sell product
                _setStrategyStatus(StrategyStatus.IDLE);
            } else {
                // collect derived assets
                $.asset.safeTransferFrom(_msgSender(), address(this), assetDelta);
                $.pendingDeutilizedAssets = assetDelta;

                uint256 collateralDeltaAmount;
                uint256 sizeDeltaInTokens = productDelta;
                if (!processingRebalanceDown()) {
                    if ($.vault.totalSupply() == 0 || ISpotManager(_msgSender()).exposure() == 0) {
                        // in case of redeeming all by users,
                        // or selling out all product
                        // close hedge position
                        sizeDeltaInTokens = type(uint256).max;
                        collateralDeltaAmount = type(uint256).max;
                        $.pendingDecreaseCollateral = 0;
                    } else if (status == StrategyStatus.FULL_DEUTILIZING) {
                        (uint256 min, uint256 max) = $.positionManager.decreaseCollateralMinMax();
                        uint256 pendingWithdraw = assetsToDeutilize();
                        collateralDeltaAmount = min > pendingWithdraw ? min : pendingWithdraw;
                        $.pendingDecreaseCollateral = 0;
                    } else {
                        // when partial deutilizing
                        IPositionManager _positionManager = $.positionManager;
                        uint256 positionNetBalance = _positionManager.positionNetBalance();
                        uint256 _pendingDecreaseCollateral = $.pendingDecreaseCollateral;
                        if (_pendingDecreaseCollateral > 0) {
                            (, positionNetBalance) = positionNetBalance.trySub(_pendingDecreaseCollateral);
                        }
                        uint256 positionSizeInTokens = _positionManager.positionSizeInTokens();
                        uint256 collateralDeltaToDecrease =
                            positionNetBalance.mulDiv(productDelta, positionSizeInTokens);
                        collateralDeltaToDecrease += _pendingDecreaseCollateral;
                        uint256 limitDecreaseCollateral = _positionManager.limitDecreaseCollateral();
                        if (collateralDeltaToDecrease < limitDecreaseCollateral) {
                            $.pendingDecreaseCollateral = collateralDeltaToDecrease;
                        } else {
                            collateralDeltaAmount = collateralDeltaToDecrease;
                        }
                    }
                }

                // the return value of this operation should be true
                // because size checks are already done in calling deutilize
                _adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false);

                emit Deutilize(_msgSender(), productDelta, assetDelta);
            }
        }
    }

    /// @dev Callback function dispatcher of the hedge position adjustment.
    function afterAdjustPosition(IPositionManager.AdjustPositionPayload calldata params)
        external
        authCaller(positionManager())
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (strategyStatus() == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }
        _setStrategyStatus(StrategyStatus.IDLE);

        bool shouldPause;
        if (params.isIncrease) {
            shouldPause = _afterIncreasePosition(params);
        } else {
            shouldPause = _afterDecreasePosition(params);
        }

        delete $.requestParams;

        if (shouldPause && !paused()) {
            _pause();
        }

        emit PositionAdjusted(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    /// @notice Returns available pending utilization and deutilization amounts.
    ///
    /// @dev The operator uses these values on offchain side to call utilize or deutilize functions.
    /// Both of those values can't be none-zero at the same time.
    ///
    /// @return pendingUtilizationInAsset The available pending utilization amount in asset.
    /// @return pendingDeutilizationInProduct The available pending deutilzation amount in product.
    /// The calculation of this amount depends on the goal of deutilizing whether it is for processing withdraw requests or for rebalancing down.
    function pendingUtilizations()
        public
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
        address _asset = asset();
        address _product = product();
        uint256 idleAssets = _vault.idleAssets();
        bool _processingRebalanceDown = $.processingRebalanceDown;
        bool _paused = paused();
        pendingUtilizationInAsset =
            _pendingUtilization(totalSupply, idleAssets, $.targetLeverage, _processingRebalanceDown, _paused);
        pendingDeutilizationInProduct = _pendingDeutilization(
            InternalPendingDeutilization({
                positionManager: _positionManager,
                asset: _asset,
                product: _product,
                totalSupply: totalSupply,
                processingRebalanceDown: _processingRebalanceDown,
                paused: _paused
            })
        );

        (uint256 increaseSizeMin,) = _positionManager.increaseSizeMinMax();
        (uint256 decreaseSizeMin,) = _positionManager.decreaseSizeMinMax();

        uint256 pendingUtilizationInProduct = $.oracle.convertTokenAmount(_asset, _product, pendingUtilizationInAsset);
        if (pendingUtilizationInProduct < increaseSizeMin) pendingUtilizationInAsset = 0;
        if (pendingDeutilizationInProduct < decreaseSizeMin) pendingDeutilizationInProduct = 0;

        return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
    }

    /// @notice The total underlying asset amount that is utilized by this strategy.
    ///
    /// @dev Includes the product balance, the position net balance, and the asset balance of this strategy.
    function utilizedAssets() public view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        uint256 productBalance = $.spotManager.exposure();
        uint256 productValueInAssets = $.oracle.convertTokenAmount(product(), asset(), productBalance);
        return productValueInAssets + $.positionManager.positionNetBalance() + assetsToWithdraw();
    }

    /// @notice The asset balance of this strategy.
    ///
    /// @dev This value should be transferred to the vault after finishing strategy operations.
    function assetsToWithdraw() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @notice The total asset amount that is needed to be withdrawn from strategy to vault to process withdraw requests.
    function assetsToDeutilize() public view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        (, uint256 assets) = $.vault.totalPendingWithdraw().trySub(assetsToWithdraw());
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Validate the position adjustment parameters before requesting.
    function _adjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease)
        internal
        virtual
        returns (bool)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        // check leverage
        if (isIncrease && collateralDeltaAmount == 0 && $.positionManager.positionNetBalance() == 0) {
            return false;
        }

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

    /// @dev Common function of checkUpkeep and performUpkeep.
    function _checkUpkeep() private view returns (InternalCheckUpkeepResult memory result) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if ($.strategyStatus != StrategyStatus.IDLE) {
            return result;
        }

        ILogarithmVault _vault = $.vault;
        IPositionManager _positionManager = $.positionManager;

        uint256 currentLeverage = _positionManager.currentLeverage();
        bool _processingRebalanceDown = $.processingRebalanceDown;
        uint256 _maxLeverage = $.maxLeverage;
        uint256 _targetLeverage = $.targetLeverage;

        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded) =
            _checkRebalance(currentLeverage, $.minLeverage, _maxLeverage, $.safeMarginLeverage);

        // rebalanceDownNeeded becomes true if currentLeverage is not near to target
        // when processingRebalanceDown is true
        // even though current leverage is smaller than max
        if (!rebalanceDownNeeded && _processingRebalanceDown) {
            (, rebalanceDownNeeded) =
                _checkNeedRebalance(currentLeverage, _targetLeverage, config().rebalanceDeviationThreshold());
        }

        if (rebalanceDownNeeded) {
            uint256 idleAssets = _vault.idleAssets();
            (uint256 minIncreaseCollateral,) = _positionManager.increaseCollateralMinMax();
            result.deltaCollateralToIncrease = _calculateDeltaCollateralForRebalance(
                _positionManager.positionNetBalance(), currentLeverage, _targetLeverage
            );
            if (result.deltaCollateralToIncrease < minIncreaseCollateral) {
                result.deltaCollateralToIncrease = minIncreaseCollateral;
            }

            // deutilize when idle assets are not enough to increase collateral
            // and when processingRebalanceDown is true
            // and when deleverageNeeded is false
            if (
                !deleverageNeeded && _processingRebalanceDown && (idleAssets == 0 || idleAssets < minIncreaseCollateral)
            ) {
                result.deltaCollateralToIncrease = 0;
                return result;
            }

            // emergency deutilize when idleAssets are not enough to increase collateral
            // in case currentLeverage is bigger than safeMarginLeverage
            if (deleverageNeeded && (result.deltaCollateralToIncrease > idleAssets)) {
                (, uint256 deltaLeverage) = currentLeverage.trySub(_maxLeverage);
                result.emergencyDeutilizationAmount =
                    _positionManager.positionSizeInTokens().mulDiv(deltaLeverage, currentLeverage);
                (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
                // @issue amount can be 0 because of clamping that breaks emergency rebalance down
                result.emergencyDeutilizationAmount = _clamp(min, result.emergencyDeutilizationAmount, max);
            }
            return result;
        }

        if (!rebalanceDownNeeded && _processingRebalanceDown) {
            result.clearProcessingRebalanceDown = true;
            return result;
        }

        result.hedgeDeviationInTokens = _checkHedgeDeviation(_positionManager, config().hedgeDeviationThreshold());
        if (result.hedgeDeviationInTokens != 0) {
            return result;
        }

        result.positionManagerNeedKeep = _positionManager.needKeep();
        if (result.positionManagerNeedKeep) {
            return result;
        }

        (uint256 minDecreaseCollateral,) = _positionManager.decreaseCollateralMinMax();
        if (minDecreaseCollateral != 0 && $.pendingDecreaseCollateral >= minDecreaseCollateral) {
            uint256 pendingDeutilization_ = _pendingDeutilization(
                InternalPendingDeutilization({
                    positionManager: _positionManager,
                    asset: asset(),
                    product: product(),
                    totalSupply: _vault.totalSupply(),
                    processingRebalanceDown: false,
                    paused: paused()
                })
            );
            (uint256 min, uint256 max) = _positionManager.decreaseSizeMinMax();
            pendingDeutilization_ = _clamp(min, pendingDeutilization_, max);
            if (pendingDeutilization_ == 0) {
                result.processPendingDecreaseCollateral = true;
                return result;
            }
        }

        if (rebalanceUpNeeded) {
            result.deltaCollateralToDecrease = _calculateDeltaCollateralForRebalance(
                _positionManager.positionNetBalance(), currentLeverage, _targetLeverage
            );
            uint256 limitDecreaseCollateral = _positionManager.limitDecreaseCollateral();
            if (result.deltaCollateralToDecrease < limitDecreaseCollateral) {
                result.deltaCollateralToDecrease = 0;
            }
        }

        return result;
    }

    /// @dev Called after the hedge position is increased.
    function _afterIncreasePosition(IPositionManager.AdjustPositionPayload calldata responseParams)
        private
        returns (bool shouldPause)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.AdjustPositionPayload memory requestParams = $.requestParams;
        uint256 _responseDeviationThreshold = config().responseDeviationThreshold();

        if (requestParams.sizeDeltaInTokens > 0) {
            (bool exceedsThreshold, int256 sizeDeviation) = _checkDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                shouldPause = true;
                if (sizeDeviation < 0) {
                    // revert spot to make hedge size the same as spot
                    $.spotManager.sell(uint256(-sizeDeviation), ISpotManager.SwapType.MANUAL, "");
                }
            }
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold, int256 collateralDeviation) = _checkDeviation(
                responseParams.collateralDeltaAmount, requestParams.collateralDeltaAmount, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                if (collateralDeviation < 0) {
                    shouldPause = true;
                    $.asset.safeTransferFrom(positionManager(), vault(), uint256(-collateralDeviation));
                }
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.positionManager.currentLeverage(), targetLeverage(), config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = $.processingRebalanceDown && rebalanceDownNeeded;
        }
    }

    /// @dev Called after the hedge position is decreased.
    function _afterDecreasePosition(IPositionManager.AdjustPositionPayload calldata responseParams)
        private
        returns (bool shouldPause)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IPositionManager.AdjustPositionPayload memory requestParams = $.requestParams;

        if (requestParams.sizeDeltaInTokens == type(uint256).max) {
            // when closing hedge
            requestParams.sizeDeltaInTokens = responseParams.sizeDeltaInTokens;
            requestParams.collateralDeltaAmount = responseParams.collateralDeltaAmount;
        }

        uint256 _responseDeviationThreshold = config().responseDeviationThreshold();
        IERC20 _asset = $.asset;
        if (requestParams.sizeDeltaInTokens > 0) {
            uint256 _pendingDeutilizedAssets = $.pendingDeutilizedAssets;
            delete $.pendingDeutilizedAssets;
            (bool exceedsThreshold, int256 sizeDeviation) = _checkDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                shouldPause = true;
                if (sizeDeviation < 0) {
                    uint256 sizeDeviationAbs = uint256(-sizeDeviation);
                    uint256 assetsToBeReverted;
                    if (sizeDeviationAbs == requestParams.sizeDeltaInTokens) {
                        assetsToBeReverted = _pendingDeutilizedAssets;
                    } else {
                        assetsToBeReverted =
                            _pendingDeutilizedAssets.mulDiv(sizeDeviationAbs, requestParams.sizeDeltaInTokens);
                    }
                    if (assetsToBeReverted > 0) {
                        ISpotManager _spotManager = $.spotManager;
                        _asset.safeTransfer(address(_spotManager), assetsToBeReverted);
                        _spotManager.buy(assetsToBeReverted, ISpotManager.SwapType.MANUAL, "");
                    }
                }
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.positionManager.currentLeverage(), $.targetLeverage, config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = processingRebalanceDown() && rebalanceDownNeeded;
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.collateralDeltaAmount, requestParams.collateralDeltaAmount, _responseDeviationThreshold
            );
            shouldPause = exceedsThreshold;
        }

        if (responseParams.collateralDeltaAmount > 0) {
            // the case when deutilizing for withdrawals and rebalancing Up
            (, $.pendingDecreaseCollateral) = $.pendingDecreaseCollateral.trySub(responseParams.collateralDeltaAmount);
            _asset.safeTransferFrom(_msgSender(), address(this), responseParams.collateralDeltaAmount);
        }
        // process withdraw request
        _processAssetsToWithdraw(address(_asset));
    }

    /// @dev Processes assetsToWithdraw for the withdraw requests
    function _processAssetsToWithdraw(address _asset) private {
        uint256 _assetsToWithdraw = assetsToWithdraw();
        if (_assetsToWithdraw == 0) return;
        ILogarithmVault _vault = ILogarithmVault(vault());
        IERC20(_asset).safeTransfer(address(_vault), _assetsToWithdraw);
        _vault.processPendingWithdrawRequests();
    }

    /// @dev This return value should be 0 when rebalancing down or when paused or when the totalSupply is 0.
    function _pendingUtilization(
        uint256 totalSupply,
        uint256 idleAssets,
        uint256 _targetLeverage,
        bool _processingRebalanceDown,
        bool _paused
    ) private pure returns (uint256) {
        // don't use utilize function when rebalancing or when totalSupply is zero, or when paused
        if (totalSupply == 0 || _processingRebalanceDown || _paused) {
            return 0;
        } else {
            return idleAssets.mulDiv(_targetLeverage, Constants.FLOAT_PRECISION + _targetLeverage);
        }
    }

    /// @dev This return value should be 0 when paused and not processing rebalance down.
    function _pendingDeutilization(InternalPendingDeutilization memory params) private view returns (uint256) {
        // disable only withdraw deutilization
        if (!params.processingRebalanceDown && params.paused) return 0;

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        uint256 productBalance = $.spotManager.exposure();
        if (params.totalSupply == 0) return productBalance;

        uint256 positionSizeInTokens = params.positionManager.positionSizeInTokens();
        uint256 positionSizeInAssets = $.oracle.convertTokenAmount(params.product, params.asset, positionSizeInTokens);
        uint256 positionNetBalance = params.positionManager.positionNetBalance();
        if (positionSizeInAssets == 0 || positionNetBalance == 0) return 0;

        uint256 totalPendingWithdraw = assetsToDeutilize();
        uint256 deutilization;
        if (params.processingRebalanceDown) {
            // for rebalance
            uint256 currentLeverage = params.positionManager.currentLeverage();
            uint256 _targetLeverage = $.targetLeverage;
            if (currentLeverage > _targetLeverage) {
                // calculate deutilization product
                // when totalPendingWithdraw is enough big to prevent increasing collateral
                uint256 deltaLeverage = currentLeverage - _targetLeverage;
                deutilization = positionSizeInTokens.mulDiv(deltaLeverage, currentLeverage);
                uint256 deutilizationInAsset = $.oracle.convertTokenAmount(params.product, params.asset, deutilization);

                // when totalPendingWithdraw is not enough big to prevent increasing collateral
                if (totalPendingWithdraw < deutilizationInAsset) {
                    uint256 num = deltaLeverage + _targetLeverage.mulDiv(totalPendingWithdraw, positionNetBalance);
                    uint256 den = currentLeverage + _targetLeverage.mulDiv(positionSizeInAssets, positionNetBalance);
                    deutilization = positionSizeInTokens.mulDiv(num, den);
                }
            }
        } else {
            if (totalPendingWithdraw == 0) return 0;

            uint256 _pendingDecreaseCollateral = $.pendingDecreaseCollateral;
            if (
                _pendingDecreaseCollateral > totalPendingWithdraw
                    || _pendingDecreaseCollateral >= (positionSizeInAssets + positionNetBalance)
            ) {
                return 0;
            }

            deutilization = positionSizeInTokens.mulDiv(
                totalPendingWithdraw - _pendingDecreaseCollateral,
                positionSizeInAssets + positionNetBalance - _pendingDecreaseCollateral
            );
        }

        deutilization = deutilization > productBalance ? productBalance : deutilization;

        return deutilization;
    }

    function _clamp(uint256 min, uint256 value, uint256 max) internal pure returns (uint256 result) {
        result = value < min ? 0 : (value > max ? max : value);
    }

    /// @dev Should be called under the condition that denominator != 0.
    /// Note: check if response of position adjustment is in allowed deviation
    function _checkDeviation(uint256 numerator, uint256 denominator, uint256 deviationThreshold)
        internal
        pure
        returns (bool exceedsThreshold, int256 deviation)
    {
        deviation = numerator.toInt256() - denominator.toInt256();
        exceedsThreshold = (deviation < 0 ? uint256(-deviation) : uint256(deviation)).mulDiv(
            Constants.FLOAT_PRECISION, denominator
        ) > deviationThreshold;
        return (exceedsThreshold, deviation);
    }

    /// @dev Checks if current leverage is not near to the target leverage
    function _checkNeedRebalance(
        uint256 _currentLeverage,
        uint256 _targetLeverage,
        uint256 _rebalanceDeviationThreshold
    ) internal pure returns (bool rebalanceUpNeeded, bool rebalanceDownNeeded) {
        (bool exceedsThreshold, int256 leverageDeviation) =
            _checkDeviation(_currentLeverage, _targetLeverage, _rebalanceDeviationThreshold);
        if (exceedsThreshold) {
            rebalanceUpNeeded = leverageDeviation < 0;
            rebalanceDownNeeded = !rebalanceUpNeeded;
        }
        return (rebalanceUpNeeded, rebalanceDownNeeded);
    }

    /// @dev Checks if current leverage is out of the min and max leverage
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

    /// @dev Checks the difference between spot and hedge sizes if it is over the configured threshold.
    function _checkHedgeDeviation(IPositionManager _positionManager, uint256 _hedgeDeviationThreshold)
        internal
        view
        returns (int256)
    {
        uint256 spotExposure = ISpotManager(spotManager()).exposure();
        uint256 hedgeExposure = _positionManager.positionSizeInTokens();
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return 0;
            } else {
                return hedgeExposure.toInt256();
            }
        }
        (bool exceedsThreshold, int256 hedgeDeviationInTokens) =
            _checkDeviation(hedgeExposure, spotExposure, _hedgeDeviationThreshold);
        if (exceedsThreshold) {
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

    /// @dev Validates the strategy status if it is desired one.
    function _validateStrategyStatus(StrategyStatus targetStatus) private view {
        StrategyStatus currentStatus = strategyStatus();
        if (currentStatus != targetStatus) {
            revert Errors.InvalidStrategyStatus(uint8(currentStatus), uint8(targetStatus));
        }
    }

    /// @dev Sets the strategy status.
    function _setStrategyStatus(StrategyStatus newStatus) private {
        _getBasisStrategyStorage().strategyStatus = newStatus;
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of connected vault.
    function vault() public view returns (address) {
        return address(_getBasisStrategyStorage().vault);
    }

    /// @notice The address of the spot manager which buys and sells product in spot markets.
    function spotManager() public view returns (address) {
        return address(_getBasisStrategyStorage().spotManager);
    }

    /// @notice The address of the position manager which hedges the spot by opening perpetual positions.
    function positionManager() public view returns (address) {
        return address(_getBasisStrategyStorage().positionManager);
    }

    /// @notice The address of system oracle.
    function oracle() public view returns (address) {
        return address(_getBasisStrategyStorage().oracle);
    }

    /// @notice The address of operator which is responsible for calling utilize/deutilize.
    function operator() public view returns (address) {
        return _getBasisStrategyStorage().operator;
    }

    /// @notice The address of underlying asset.
    function asset() public view returns (address) {
        return address(_getBasisStrategyStorage().asset);
    }

    /// @notice The address of product.
    function product() public view returns (address) {
        return address(_getBasisStrategyStorage().product);
    }

    /// @notice The address of Config smart contract that is used throughout all strategies for their configurations.
    function config() public view returns (IStrategyConfig) {
        return IStrategyConfig(_getBasisStrategyStorage().config);
    }

    /// @notice The strategy status.
    function strategyStatus() public view returns (StrategyStatus) {
        return _getBasisStrategyStorage().strategyStatus;
    }

    /// @notice The target leverage at which the hedge position is increased.
    function targetLeverage() public view returns (uint256) {
        return _getBasisStrategyStorage().targetLeverage;
    }

    /// @notice The minimum leverage value to which the hedge position can be reached down.
    function minLeverage() public view returns (uint256) {
        return _getBasisStrategyStorage().minLeverage;
    }

    /// @notice The maximum leverage value to which the hedge position can be reached up.
    function maxLeverage() public view returns (uint256) {
        return _getBasisStrategyStorage().maxLeverage;
    }

    /// @notice The maximum leverage value where normal rebalancing down is applied.
    /// If the leverage overshoots it, emergency rebalancing down is executed.
    function safeMarginLeverage() public view returns (uint256) {
        return _getBasisStrategyStorage().safeMarginLeverage;
    }

    /// @notice The value that couldn't be decreased due to size limits.
    /// Accumulated overtime and executed to decrease collateral by keeping logic once the size satisfies the conditions.
    function pendingDecreaseCollateral() public view returns (uint256) {
        return _getBasisStrategyStorage().pendingDecreaseCollateral;
    }

    /// @notice Tells if strategy is in rebalancing down.
    function processingRebalanceDown() public view returns (bool) {
        return _getBasisStrategyStorage().processingRebalanceDown;
    }
}
