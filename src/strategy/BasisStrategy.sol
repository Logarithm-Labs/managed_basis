// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutomationCompatibleInterface} from "src/externals/chainlink/interfaces/AutomationCompatibleInterface.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {ILogarithmVault} from "src/vault/ILogarithmVault.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {IStrategyConfig} from "src/strategy/IStrategyConfig.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title BasisStrategy
///
/// @author Logarithm Labs
///
/// @notice BasisStrategy implements a delta-neutral basis trading strategy.
/// By simultaneously buying a spot asset and selling a perpetual contract,
/// the strategy seeks to hedge the price risk of the spot position while
/// generating revenue from funding payments.
/// The contract allows depositors to provide capital through the connected vault,
/// which is then deployed across both the spot and perpetual markets.
/// Profits are derived from the funding payments collected from the short perpetual position,
/// aiming for yield independent of price direction.
///
/// @dev SpotManager and HedgeManager are connected as separated smart contracts
/// to manage spot and hedge positions.
/// BasisStrategy is an upgradeable smart contract, deployed through a beacon proxy pattern.
contract BasisStrategy is
    Initializable,
    PausableUpgradeable,
    Ownable2StepUpgradeable,
    IBasisStrategy,
    AutomationCompatibleInterface
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @dev Used to specify strategy's operations.
    enum StrategyStatus {
        // When new operations are available.
        IDLE,
        // When only hedge operation gets initiated.
        KEEPING,
        // When sync utilizing following by hedge increase gets initiated.
        UTILIZING,
        // When async deutilizing with hedge decrease gets intiated.
        DEUTILIZING,
        // When one of 2 deutilization operations has been proceeded,
        // or either of deutilizing or hedge decrease gets initiated
        AWAITING_FINAL_DEUTILIZATION
    }

    /// @dev Used internally to optimize params of deutilization.
    struct InternalPendingDeutilization {
        // The address of hedge position manager.
        IHedgeManager hedgeManager;
        // The address of the connected vault's underlying asset.
        address asset;
        // The product address.
        address product;
        // The totalSupply of shares of its connected vault
        uint256 totalSupply;
        // The current exposure of spot manager
        uint256 exposure;
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
        bool hedgeManagerNeedKeep;
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
        IHedgeManager hedgeManager;
        IOracle oracle;
        address operator;
        address config;
        // leverage config
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        // status state
        StrategyStatus strategyStatus;
        // used to change deutilization calc method
        bool processingRebalanceDown;
        // adjust position request to be used to check response
        IHedgeManager.AdjustPositionPayload requestParams;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BasisStrategy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BasisStrategyStorageLocation =
        0x3176332e209c21f110843843692adc742ac2f78c16c19930ebc0f9f8747e5200;

    function _getBasisStrategyStorage() private pure returns (BasisStrategyStorage storage $) {
        assembly {
            $.slot := BasisStrategyStorageLocation
        }
    }

    constructor() {
        _disableInitializers();
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
    event HedgeManagerUpdated(address indexed account, address indexed newPositionManager);

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
    function setSpotManager(address newSpotManager) external onlyOwner {
        if (spotManager() != newSpotManager) {
            ISpotManager manager = ISpotManager(newSpotManager);
            require(manager.asset() == asset() && manager.product() == product());
            _getBasisStrategyStorage().spotManager = manager;
            emit SpotManagerUpdated(_msgSender(), newSpotManager);
        }
    }

    /// @notice Sets the hedge manager.
    function setHedgeManager(address newHedgeManager) external onlyOwner {
        if (hedgeManager() != newHedgeManager) {
            IHedgeManager manager = IHedgeManager(newHedgeManager);
            require(manager.collateralToken() == asset() && manager.indexToken() == product());
            _getBasisStrategyStorage().hedgeManager = manager;
            emit HedgeManagerUpdated(_msgSender(), newHedgeManager);
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

    /// @notice Pauses strategy, disabling utilizing and deutilizing for withdraw requests,
    /// while all logics related to keeping are still available.
    function pause() external onlyOwnerOrVault whenNotPaused {
        _pause();
    }

    /// @notice Unpauses strategy.
    function unpause() external onlyOwnerOrVault whenPaused {
        _unpause();
    }

    /// @notice Pauses strategy while swapping all products back to assets
    /// and closing the hedge position.
    function stop() external onlyOwnerOrVault whenNotPaused {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        delete $.processingRebalanceDown;
        _setStrategyStatus(StrategyStatus.DEUTILIZING);
        ISpotManager _spotManager = $.spotManager;
        _spotManager.sell(_spotManager.exposure(), ISpotManager.SwapType.MANUAL, "");
        _adjustPosition(type(uint256).max, type(uint256).max, false);
        _pause();

        emit Stopped(_msgSender());
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE/DEUTILZE   
    //////////////////////////////////////////////////////////////*/

    /// @notice Utilizes assets to increase the spot size.
    /// Right after the increase, the hedge position is also increased
    /// as the same amount as the spot size increased.
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
    /// Right after the decrease, the hedge position is also decreased
    /// as the same amount as the spot size decreased.
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
        _setStrategyStatus(StrategyStatus.DEUTILIZING);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IHedgeManager _hedgeManager = $.hedgeManager;
        bool _processingRebalanceDown = processingRebalanceDown();
        address _asset = asset();
        address _product = product();
        uint256 _totalSupply = $.vault.totalSupply();
        ISpotManager _spotManager = $.spotManager;
        uint256 _exposure = _spotManager.exposure();

        uint256 pendingDeutilization_ = _pendingDeutilization(
            InternalPendingDeutilization({
                hedgeManager: _hedgeManager,
                asset: _asset,
                product: _product,
                totalSupply: _totalSupply,
                exposure: _exposure,
                processingRebalanceDown: _processingRebalanceDown,
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
        uint256 min = _hedgeManager.decreaseSizeMin();
        amount = _clamp(min, amount);

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        bool isFullDeutilization;
        // check if full or partial deutilizing
        // if remaining deutiliization is smaller than min size
        // treat it as full
        (, uint256 absoluteThreshold) = pendingDeutilization_.trySub(min);
        if (!exceedsThreshold || deutilizationDeviation < 0 || amount >= absoluteThreshold) {
            isFullDeutilization = true;
        } else {
            isFullDeutilization = false;
        }

        // deutilize spot
        _spotManager.sell(amount, swapType, swapData);

        // decrease hedge
        uint256 collateralDeltaAmount;
        uint256 sizeDeltaInTokens = amount;
        // if the operation is not for processing rebalance down,
        // that means deutilizing for withdraw requests, then decreases
        // the collateral of hedge position as well.
        if (!_processingRebalanceDown) {
            if (_totalSupply == 0 || _exposure == amount) {
                // in case of redeeming all by users,
                // or selling out all product
                // close hedge position
                sizeDeltaInTokens = type(uint256).max;
                collateralDeltaAmount = type(uint256).max;
            } else if (isFullDeutilization) {
                uint256 pendingWithdraw;
                if (strategyStatus() == StrategyStatus.AWAITING_FINAL_DEUTILIZATION) {
                    // in case spot has been sold already
                    pendingWithdraw = assetsToDeutilize();
                } else {
                    // in case spot hasn't been sold yet
                    uint256 estimatedAssets = $.oracle.convertTokenAmount(_product, _asset, amount);
                    // subtract 1% less than the estimated one to process fully
                    (, pendingWithdraw) = assetsToDeutilize().trySub(estimatedAssets * 99 / 100);
                }
                min = _hedgeManager.decreaseCollateralMin();
                collateralDeltaAmount = min > pendingWithdraw ? min : pendingWithdraw;
            } else {
                // when partial deutilizing
                uint256 positionNetBalance = _hedgeManager.positionNetBalance();
                uint256 positionSizeInTokens = _hedgeManager.positionSizeInTokens();
                uint256 collateralDeltaToDecrease = positionNetBalance.mulDiv(amount, positionSizeInTokens);
                uint256 limitDecreaseCollateral = _hedgeManager.limitDecreaseCollateral();
                // only decrease collateral bigger than limit
                if (collateralDeltaToDecrease >= limitDecreaseCollateral) {
                    collateralDeltaAmount = collateralDeltaToDecrease;
                }
            }
        }

        // the return value of this operation should be true
        // because size checks are already done in calling deutilize
        _adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false);
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes idle assets for the withdraw requests.
    ///
    /// @dev Callable by anyone and only when strategy is in the IDLE status.
    function processAssetsToWithdraw() public whenIdle {
        address _asset = asset();
        address _hedgeManager = hedgeManager();
        uint256 idleCollateral = IERC20(_asset).balanceOf(_hedgeManager);
        if (idleCollateral > 0) {
            IERC20(_asset).safeTransferFrom(_hedgeManager, address(this), idleCollateral);
        }
        _processAssetsToWithdraw(asset());
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes memory) public view returns (bool upkeepNeeded, bytes memory performData) {
        InternalCheckUpkeepResult memory result = _checkUpkeep();

        upkeepNeeded = result.emergencyDeutilizationAmount > 0 || result.deltaCollateralToIncrease > 0
            || result.clearProcessingRebalanceDown || result.hedgeDeviationInTokens != 0 || result.hedgeManagerNeedKeep
            || result.deltaCollateralToDecrease > 0;

        performData = abi.encode(
            result.emergencyDeutilizationAmount,
            result.deltaCollateralToIncrease,
            result.clearProcessingRebalanceDown,
            result.hedgeDeviationInTokens,
            result.hedgeManagerNeedKeep,
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
            $.processingRebalanceDown = true;
            _setStrategyStatus(StrategyStatus.DEUTILIZING);
            $.spotManager.sell(result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, "");
            _adjustPosition(result.emergencyDeutilizationAmount, 0, false);
        } else if (result.deltaCollateralToIncrease > 0) {
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
                    _setStrategyStatus(StrategyStatus.AWAITING_FINAL_DEUTILIZATION);
                    $.spotManager.sell(hedgeDeviationInTokens, ISpotManager.SwapType.MANUAL, "");
                }
            }
        } else if (result.hedgeManagerNeedKeep) {
            $.hedgeManager.keep();
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
    /// Increases the hedge position size if the swap operation is for utilizing.
    function spotBuyCallback(uint256 assetDelta, uint256 productDelta, uint256 timestamp)
        external
        authCaller(spotManager())
    {
        StrategyStatus status = strategyStatus();
        if (status == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if (status == StrategyStatus.UTILIZING) {
            if (productDelta == 0) {
                // fail to buy product
                address _vault = vault();
                $.asset.safeTransferFrom(_msgSender(), _vault, assetDelta);
                _setStrategyStatus(StrategyStatus.IDLE);
                ILogarithmVault(_vault).processPendingWithdrawRequests();
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
    /// Decreases the hedge position if the swap operation is not for reverting.
    function spotSellCallback(uint256 assetDelta, uint256 productDelta, uint256 timestamp)
        external
        authCaller(spotManager())
    {
        StrategyStatus status = strategyStatus();
        if (status == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IERC20 _asset = $.asset;

        // modify strategy status
        if (status == StrategyStatus.UTILIZING) {
            // revert utilizing
            ILogarithmVault _vault = $.vault;
            _asset.safeTransferFrom(_msgSender(), address(_vault), assetDelta);
            _setStrategyStatus(StrategyStatus.IDLE);
            _vault.processPendingWithdrawRequests();
        } else {
            if (assetDelta == 0) {
                // fail to sell product
                _setStrategyStatus(StrategyStatus.IDLE);
            } else {
                // collect derived assets
                _asset.safeTransferFrom(_msgSender(), address(this), assetDelta);
                if (status == StrategyStatus.AWAITING_FINAL_DEUTILIZATION) {
                    // if hedge already adjusted
                    _setStrategyStatus(StrategyStatus.IDLE);
                    _processAssetsToWithdraw(address(_asset));
                } else {
                    _setStrategyStatus(StrategyStatus.AWAITING_FINAL_DEUTILIZATION);
                }
                emit Deutilize(_msgSender(), productDelta, assetDelta, timestamp);
            }
        }
    }

    /// @dev Callback function dispatcher of the hedge position adjustment.
    function afterAdjustPosition(IHedgeManager.AdjustPositionPayload calldata params)
        external
        authCaller(hedgeManager())
    {
        StrategyStatus status = strategyStatus();
        if (status == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }

        bool shouldPause;
        if (params.isIncrease) {
            shouldPause = _afterIncreasePosition(params);
            // utilize is sync one, and position adjustment is final
            // hence, set status as idle
            _setStrategyStatus(StrategyStatus.IDLE);
        } else {
            shouldPause = _afterDecreasePosition(params);
            if (status == StrategyStatus.AWAITING_FINAL_DEUTILIZATION) {
                _setStrategyStatus(StrategyStatus.IDLE);
                _processAssetsToWithdraw(asset());
            } else if (status == StrategyStatus.DEUTILIZING) {
                _setStrategyStatus(StrategyStatus.AWAITING_FINAL_DEUTILIZATION);
            } else {
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        }

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        delete $.requestParams;

        if (shouldPause && !paused()) {
            _pause();
        }

        emit PositionAdjusted(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    /// @notice Returns available pending utilization and deutilization amounts.
    ///
    /// @dev The operator uses these values on offchain side to decide the parameters
    /// for calling utilize or deutilize functions.
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
        IHedgeManager _hedgeManager = $.hedgeManager;
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
                hedgeManager: _hedgeManager,
                asset: _asset,
                product: _product,
                totalSupply: totalSupply,
                exposure: $.spotManager.exposure(),
                processingRebalanceDown: _processingRebalanceDown,
                paused: _paused
            })
        );

        uint256 pendingUtilizationInProduct = $.oracle.convertTokenAmount(_asset, _product, pendingUtilizationInAsset);
        if (pendingUtilizationInProduct < _hedgeManager.increaseSizeMin()) pendingUtilizationInAsset = 0;
        if (pendingDeutilizationInProduct < _hedgeManager.decreaseSizeMin()) pendingDeutilizationInProduct = 0;

        return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
    }

    /// @notice The total underlying asset amount that has been utilized by this strategy.
    ///
    /// @dev Includes the product balance, the position net balance, and the asset balance of this strategy.
    function utilizedAssets() public view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        return $.spotManager.getAssetValue() + $.hedgeManager.positionNetBalance() + assetsToWithdraw();
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
        if (isIncrease && collateralDeltaAmount == 0 && $.hedgeManager.positionNetBalance() == 0) {
            return false;
        }

        // we don't allow to adjust hedge with modified amount due to min.
        if (sizeDeltaInTokens > 0) {
            uint256 min = isIncrease ? $.hedgeManager.increaseSizeMin() : $.hedgeManager.decreaseSizeMin();
            if (sizeDeltaInTokens < min) return false;
        }
        if (collateralDeltaAmount > 0) {
            uint256 min = isIncrease ? $.hedgeManager.increaseCollateralMin() : $.hedgeManager.decreaseCollateralMin();
            if (collateralDeltaAmount < min) return false;
        }

        if (isIncrease && collateralDeltaAmount > 0) {
            $.asset.safeTransferFrom(address($.vault), address($.hedgeManager), collateralDeltaAmount);
        }

        if (collateralDeltaAmount > 0 || sizeDeltaInTokens > 0) {
            IHedgeManager.AdjustPositionPayload memory requestParams = IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: collateralDeltaAmount,
                isIncrease: isIncrease
            });
            $.requestParams = requestParams;
            $.hedgeManager.adjustPosition(requestParams);
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
        IHedgeManager _hedgeManager = $.hedgeManager;

        uint256 currentLeverage = _hedgeManager.currentLeverage();
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
            uint256 minIncreaseCollateral = _hedgeManager.increaseCollateralMin();
            result.deltaCollateralToIncrease = _calculateDeltaCollateralForRebalance(
                _hedgeManager.positionNetBalance(), currentLeverage, _targetLeverage
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
                    _hedgeManager.positionSizeInTokens().mulDiv(deltaLeverage, currentLeverage);
                uint256 min = _hedgeManager.decreaseSizeMin();
                if (result.emergencyDeutilizationAmount < min) {
                    result.emergencyDeutilizationAmount = min;
                }
            }
            return result;
        }

        if (!rebalanceDownNeeded && _processingRebalanceDown) {
            result.clearProcessingRebalanceDown = true;
            return result;
        }

        result.hedgeDeviationInTokens = _checkHedgeDeviation(_hedgeManager, config().hedgeDeviationThreshold());
        if (result.hedgeDeviationInTokens != 0) {
            return result;
        }

        result.hedgeManagerNeedKeep = _hedgeManager.needKeep();
        if (result.hedgeManagerNeedKeep) {
            return result;
        }

        if (rebalanceUpNeeded) {
            result.deltaCollateralToDecrease = _calculateDeltaCollateralForRebalance(
                _hedgeManager.positionNetBalance(), currentLeverage, _targetLeverage
            );
            uint256 limitDecreaseCollateral = _hedgeManager.limitDecreaseCollateral();
            if (result.deltaCollateralToDecrease < limitDecreaseCollateral) {
                result.deltaCollateralToDecrease = 0;
            }
        }

        return result;
    }

    /// @dev Called after the hedge position is increased.
    function _afterIncreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams)
        private
        returns (bool shouldPause)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IHedgeManager.AdjustPositionPayload memory requestParams = $.requestParams;
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
                    address _vault = vault();
                    $.asset.safeTransferFrom(hedgeManager(), _vault, uint256(-collateralDeviation));
                    ILogarithmVault(_vault).processPendingWithdrawRequests();
                }
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.hedgeManager.currentLeverage(), targetLeverage(), config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = $.processingRebalanceDown && rebalanceDownNeeded;
        }
    }

    /// @dev Called after the hedge position is decreased.
    function _afterDecreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams)
        private
        returns (bool shouldPause)
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IHedgeManager.AdjustPositionPayload memory requestParams = $.requestParams;

        if (requestParams.sizeDeltaInTokens == type(uint256).max) {
            // when closing hedge
            requestParams.sizeDeltaInTokens = responseParams.sizeDeltaInTokens;
            requestParams.collateralDeltaAmount = responseParams.collateralDeltaAmount;
        }

        uint256 _responseDeviationThreshold = config().responseDeviationThreshold();
        IERC20 _asset = $.asset;
        if (requestParams.sizeDeltaInTokens > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                shouldPause = true;
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.hedgeManager.currentLeverage(), $.targetLeverage, config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = processingRebalanceDown() && rebalanceDownNeeded;
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.collateralDeltaAmount, requestParams.collateralDeltaAmount, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                shouldPause = true;
            }
        }

        if (responseParams.collateralDeltaAmount > 0) {
            _asset.safeTransferFrom(_msgSender(), address(this), responseParams.collateralDeltaAmount);
        }
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

        if (params.totalSupply == 0) return params.exposure;

        uint256 positionSizeInTokens = params.hedgeManager.positionSizeInTokens();
        uint256 positionSizeInAssets = $.oracle.convertTokenAmount(params.product, params.asset, positionSizeInTokens);
        uint256 positionNetBalance = params.hedgeManager.positionNetBalance();
        if (positionSizeInAssets == 0 || positionNetBalance == 0) return 0;

        uint256 totalPendingWithdraw = assetsToDeutilize();
        uint256 deutilization;
        if (params.processingRebalanceDown) {
            // for rebalance
            uint256 currentLeverage = params.hedgeManager.currentLeverage();
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

            deutilization = positionSizeInTokens.mulDiv(totalPendingWithdraw, positionSizeInAssets + positionNetBalance);
        }

        deutilization = deutilization > params.exposure ? params.exposure : deutilization;

        return deutilization;
    }

    function _clamp(uint256 min, uint256 value) internal pure returns (uint256 result) {
        result = value < min ? 0 : value;
    }

    /// @dev Should be called under the condition that denominator != 0.
    /// Note: check if response of position adjustment is in the allowed deviation
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
    function _checkHedgeDeviation(IHedgeManager _hedgeManager, uint256 _hedgeDeviationThreshold)
        internal
        view
        returns (int256)
    {
        uint256 spotExposure = ISpotManager(spotManager()).exposure();
        uint256 hedgeExposure = _hedgeManager.positionSizeInTokens();
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
                uint256 min = _hedgeManager.decreaseSizeMin();
                return int256(_clamp(min, uint256(hedgeDeviationInTokens)));
            } else {
                uint256 min = _hedgeManager.increaseSizeMin();
                return -int256(_clamp(min, uint256(-hedgeDeviationInTokens)));
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
    function hedgeManager() public view returns (address) {
        return address(_getBasisStrategyStorage().hedgeManager);
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

    /// @notice Tells if strategy is in rebalancing down.
    function processingRebalanceDown() public view returns (bool) {
        return _getBasisStrategyStorage().processingRebalanceDown;
    }
}
