// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutomationCompatibleInterface} from "../externals/chainlink/interfaces/AutomationCompatibleInterface.sol";
import {ISpotManager} from "../spot/ISpotManager.sol";
import {IHedgeManager} from "../hedge/IHedgeManager.sol";
import {IBasisStrategy} from "../strategy/IBasisStrategy.sol";
import {ILogarithmVault} from "../vault/ILogarithmVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IStrategyConfig} from "../strategy/IStrategyConfig.sol";

import {Constants} from "../libraries/utils/Constants.sol";
import {Errors} from "../libraries/utils/Errors.sol";

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
        // When utilizing gets initiated.
        UTILIZING,
        // When deutilizing gets initiated.
        DEUTILIZING,
        // When one of deutilizations (spot & hedge) has been proceeded,
        // or rehedge with spot gets initiated
        AWAITING_FINAL_DEUTILIZATION,
        // When one of utilizations (spot & hedge) has been proceeded.
        AWAITING_FINAL_UTILIZATION
    }

    /// @dev Used internally to optimize params of utilization.
    struct InternalPendingUtilization {
        // The totalSupply of connected vault
        uint256 totalSupply;
        // The totalAssets of connected vault
        uint256 totalAssets;
        // The idle assets of connected vault
        uint256 idleAssets;
        // The targetLeverage
        uint256 targetLeverage;
        // The boolean value of storage variable processingRebalanceDown.
        bool processingRebalanceDown;
        // The boolean value tells whether strategy gets paused of not.
        bool paused;
        // The max amount for utilization
        uint256 maxAmount;
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
        // The boolean value tells whether strategy gets paused of not.
        bool paused;
        // The cap amount for deutilization
        uint256 maxAmount;
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
        // eliminate pending exection cost
        bool clearReservedExecutionCost;
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
        // entry/exit fees accrued by the vault that will be spend during utilization/deutilization
        uint256 reservedExecutionCost;
        // entry/exit fees that will be deducted from the reservedExecution cost
        // after completion of utilization/deutilization
        uint256 utilizingExecutionCost;
        // percentage of vault's TVL that caps pending utilization/deutilization
        uint256 maxUtilizePct;
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
    event Utilize(address indexed caller, uint256 assetDelta, uint256 productDelta, uint256 timestamp);

    /// @dev Emitted when assets are deutilized.
    event Deutilize(address indexed caller, uint256 productDelta, uint256 assetDelta, uint256 timestamp);

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

    /// @dev Emitted when maxUtilizePct vault gets updated.
    event MaxUtilizePctUpdated(address indexed account, uint256 newPct);

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

        _setMaxUtilizePct(1 ether); // no cap by default
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

    function _setMaxUtilizePct(uint256 value) internal {
        require(value > 0 && value <= 1 ether);
        if (maxUtilizePct() != value) {
            _getBasisStrategyStorage().maxUtilizePct = value;
            emit MaxUtilizePctUpdated(_msgSender(), value);
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
            require(manager.collateralToken() == asset());
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

    /// @notice Sets the limit percent given vault's total asset against utilize/deutilize amounts.
    function setMaxUtilizePct(uint256 value) external onlyOwner {
        _setMaxUtilizePct(value);
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
        _adjustPosition(type(uint256).max, type(uint256).max, false, true);
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
        uint256 _targetLeverage = targetLeverage();
        uint256 _idleAssets = _vault.idleAssets();
        (uint256 pendingUtilization, uint256 uncappedUtilization) = _pendingUtilization(
            InternalPendingUtilization({
                totalSupply: _vault.totalSupply(),
                totalAssets: _vault.totalAssets(),
                idleAssets: _idleAssets,
                targetLeverage: _targetLeverage,
                processingRebalanceDown: processingRebalanceDown(),
                paused: paused(),
                maxAmount: _maxUtilization(_idleAssets, utilizedAssets())
            })
        );

        amount = _capAmount(amount, pendingUtilization);

        if (amount == uncappedUtilization) {
            $.utilizingExecutionCost = reservedExecutionCost();
        } else {
            $.utilizingExecutionCost = reservedExecutionCost().mulDiv(amount, uncappedUtilization);
        }

        // can only utilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        ISpotManager _spotManager = $.spotManager;
        IERC20 _asset = $.asset;

        _asset.safeTransferFrom(address(_vault), address(_spotManager), amount);

        if (_spotManager.isXChain()) {
            // apply asynchronous utilization
            uint256 collateralDeltaAmount = _calculateDeltaCollateralForUtilize(amount, _targetLeverage);
            uint256 estimatedProductAmount = $.oracle.convertTokenAmount(address(_asset), product(), amount);
            // don't emit hedge request
            uint256 round = _adjustPosition(estimatedProductAmount, collateralDeltaAmount, true, false);
            _spotManager.buy(amount, swapType, abi.encode(round, collateralDeltaAmount));
        } else {
            // apply synchronous utilization
            _spotManager.buy(amount, swapType, swapData);
        }
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
        ILogarithmVault _vault = $.vault;
        uint256 _totalSupply = _vault.totalSupply();
        ISpotManager _spotManager = $.spotManager;
        uint256 _exposure = _spotManager.exposure();
        uint256 maxDeutilization =
            $.oracle.convertTokenAmount(_asset, _product, _maxUtilization(_vault.idleAssets(), utilizedAssets()));

        (uint256 pendingDeutilization, uint256 uncappedDeutilization) = _pendingDeutilization(
            InternalPendingDeutilization({
                hedgeManager: _hedgeManager,
                asset: _asset,
                product: _product,
                totalSupply: _totalSupply,
                exposure: _exposure,
                processingRebalanceDown: _processingRebalanceDown,
                paused: paused(),
                maxAmount: maxDeutilization
            })
        );

        amount = _capAmount(amount, pendingDeutilization);

        // Replace amount with uncappedDeutilization when intend to deutilize fully
        // Note: Oracle price keeps changing, so need to check deviation.
        // Note: If the remaining product is smaller than the min size, treat it as full.
        // because there is no way to deutilize it.
        (bool exceedsThreshold, int256 deutilizationDeviation) =
            _checkDeviation(uncappedDeutilization, amount, config().deutilizationThreshold());
        uint256 min = _hedgeManager.decreaseSizeMin();
        (, uint256 absoluteThreshold) = uncappedDeutilization.trySub(min);
        if (deutilizationDeviation < 0 || !exceedsThreshold || amount >= absoluteThreshold) {
            amount = uncappedDeutilization;
        }

        if (_processingRebalanceDown && amount > 0 && amount < min) {
            // when processing rebalance down, deutilization should be at least decreaseSizeMin
            amount = min;
        } else {
            // check if amount is in the possible adjustment range
            amount = _clamp(min, amount);
        }

        // can only deutilize when amount is positive
        if (amount == 0) {
            revert Errors.ZeroAmountUtilization();
        }

        uint256 collateralDeltaAmount;
        uint256 sizeDeltaInTokens = amount;
        // if the operation is not for processing rebalance down,
        // that means deutilizing for withdraw requests, then decreases
        // the collateral of hedge position as well.
        if (!_processingRebalanceDown) {
            if (amount == uncappedDeutilization) {
                // when full deutilization
                $.utilizingExecutionCost = reservedExecutionCost();
                if (_totalSupply == 0) {
                    // in case of redeeming all by users,
                    // or selling out all product
                    // close hedge position
                    sizeDeltaInTokens = type(uint256).max;
                    collateralDeltaAmount = type(uint256).max;
                } else {
                    // estimate assets that will be derived from selling spot
                    uint256 estimatedAssets = $.oracle.convertTokenAmount(_product, _asset, amount);
                    // subtract 1% less than the estimated one to process fully
                    (, collateralDeltaAmount) = assetsToDeutilize().trySub(estimatedAssets * 99 / 100);
                    min = _hedgeManager.decreaseCollateralMin();
                    if (collateralDeltaAmount < min) {
                        collateralDeltaAmount = min;
                    }
                }
            } else {
                // when partial deutilizing
                $.utilizingExecutionCost = reservedExecutionCost().mulDiv(amount, uncappedDeutilization);
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

        if (sizeDeltaInTokens == type(uint256).max) {
            _adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false, true);
            if (_spotManager.isXChain()) {
                _spotManager.sell(amount, swapType, "");
            } else {
                _spotManager.sell(amount, swapType, swapData);
            }
        } else {
            if (_spotManager.isXChain()) {
                uint256 round = _adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false, false);
                _spotManager.sell(amount, swapType, abi.encode(round, collateralDeltaAmount));
            } else {
                _adjustPosition(sizeDeltaInTokens, collateralDeltaAmount, false, true);
                _spotManager.sell(amount, swapType, swapData);
            }
        }
    }

    function reserveExecutionCost(uint256 amount) external authCaller(vault()) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        $.reservedExecutionCost += amount;
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
            || result.deltaCollateralToDecrease > 0 || result.clearReservedExecutionCost;

        performData = abi.encode(result);

        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /*performData*/ ) external whenIdle {
        InternalCheckUpkeepResult memory result = _checkUpkeep();

        _setStrategyStatus(StrategyStatus.KEEPING);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if (result.clearReservedExecutionCost) {
            $.reservedExecutionCost = 0;
        }

        ISpotManager _spotManager = $.spotManager;
        if (result.emergencyDeutilizationAmount > 0) {
            $.processingRebalanceDown = true;
            _setStrategyStatus(StrategyStatus.DEUTILIZING);
            if (_spotManager.isXChain()) {
                uint256 round = _adjustPosition(result.emergencyDeutilizationAmount, 0, false, false);
                _spotManager.sell(
                    result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, abi.encode(round, 0)
                );
            } else {
                _adjustPosition(result.emergencyDeutilizationAmount, 0, false, true);
                _spotManager.sell(result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, "");
            }
        } else if (result.deltaCollateralToIncrease > 0) {
            $.processingRebalanceDown = true;
            ILogarithmVault _vault = $.vault;
            uint256 idleAssets = _vault.idleAssets();
            result.deltaCollateralToIncrease =
                idleAssets < result.deltaCollateralToIncrease ? idleAssets : result.deltaCollateralToIncrease;
            if (
                result.deltaCollateralToIncrease > 0
                    && result.deltaCollateralToIncrease >= $.hedgeManager.increaseCollateralMin()
            ) {
                _adjustPosition(0, result.deltaCollateralToIncrease, true, true);
            } else {
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        } else if (result.clearProcessingRebalanceDown) {
            $.processingRebalanceDown = false;
            _setStrategyStatus(StrategyStatus.IDLE);
        } else if (result.hedgeDeviationInTokens != 0) {
            if (result.hedgeDeviationInTokens > 0) {
                _adjustPosition(uint256(result.hedgeDeviationInTokens), 0, false, true);
            } else {
                uint256 hedgeDeviationInTokens = uint256(-result.hedgeDeviationInTokens);
                // not increase hedge size as it includes risks, instead sell spot
                // in x chain, sell spot while not adjusting hedge position
                $.spotManager.sell(hedgeDeviationInTokens, ISpotManager.SwapType.MANUAL, "");
            }
        } else if (result.hedgeManagerNeedKeep) {
            $.hedgeManager.keep();
        } else if (result.deltaCollateralToDecrease > 0) {
            _adjustPosition(0, result.deltaCollateralToDecrease, false, true);
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

        if (ISpotManager(_msgSender()).isXChain()) {
            if (status == StrategyStatus.AWAITING_FINAL_UTILIZATION) {
                _setStrategyStatus(StrategyStatus.IDLE);
                _processUtilizingExecutionCost();
            } else if (status == StrategyStatus.UTILIZING) {
                _setStrategyStatus(StrategyStatus.AWAITING_FINAL_UTILIZATION);
            }
        } else {
            _setStrategyStatus(StrategyStatus.AWAITING_FINAL_UTILIZATION);
            _adjustPosition(productDelta, _calculateDeltaCollateralForUtilize(assetDelta, targetLeverage()), true, true);
        }

        emit Utilize(_msgSender(), assetDelta, productDelta, timestamp);
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

        // collect derived assets
        _asset.safeTransferFrom(_msgSender(), address(this), assetDelta);
        if (status == StrategyStatus.AWAITING_FINAL_DEUTILIZATION) {
            // if hedge already adjusted
            _setStrategyStatus(StrategyStatus.IDLE);
            _processUtilizingExecutionCost();
            _processAssetsToWithdraw(address(_asset));
        } else if (status == StrategyStatus.DEUTILIZING) {
            _setStrategyStatus(StrategyStatus.AWAITING_FINAL_DEUTILIZATION);
        } else {
            // for rehedge
            _setStrategyStatus(StrategyStatus.IDLE);
            _processAssetsToWithdraw(address(_asset));
        }

        emit Deutilize(_msgSender(), productDelta, assetDelta, timestamp);
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

        if (params.isIncrease) {
            _afterIncreasePosition(params);
            if (status == StrategyStatus.AWAITING_FINAL_UTILIZATION) {
                _setStrategyStatus(StrategyStatus.IDLE);
                _processUtilizingExecutionCost();
            } else if (status == StrategyStatus.UTILIZING) {
                _setStrategyStatus(StrategyStatus.AWAITING_FINAL_UTILIZATION);
            } else {
                // for rebalance down to increase collateral
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        } else {
            _afterDecreasePosition(params);
            if (status == StrategyStatus.AWAITING_FINAL_DEUTILIZATION) {
                _setStrategyStatus(StrategyStatus.IDLE);
                _processUtilizingExecutionCost();
                _processAssetsToWithdraw(asset());
            } else if (status == StrategyStatus.DEUTILIZING) {
                _setStrategyStatus(StrategyStatus.AWAITING_FINAL_DEUTILIZATION);
            } else {
                // for rebalance up to decrease collateral or for rehedge
                _setStrategyStatus(StrategyStatus.IDLE);
                _processAssetsToWithdraw(asset());
            }
        }

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        delete $.requestParams;

        emit PositionAdjusted(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    function harvestPerformanceFee() external authCaller(hedgeManager()) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        $.vault.harvestPerformanceFee();
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
        IHedgeManager _hedgeManager = $.hedgeManager;
        uint256 totalSupply = _vault.totalSupply();
        address _asset = asset();
        address _product = product();
        uint256 idleAssets = _vault.idleAssets();
        bool _processingRebalanceDown = $.processingRebalanceDown;
        bool _paused = paused();
        IOracle _oracle = $.oracle;
        uint256 maxUtilization = _maxUtilization(idleAssets, utilizedAssets());
        uint256 maxDeutilization = _oracle.convertTokenAmount(_asset, _product, maxUtilization);
        (pendingUtilizationInAsset,) = _pendingUtilization(
            InternalPendingUtilization({
                totalSupply: totalSupply,
                totalAssets: _vault.totalAssets(),
                idleAssets: idleAssets,
                targetLeverage: targetLeverage(),
                processingRebalanceDown: _processingRebalanceDown,
                paused: _paused,
                maxAmount: maxUtilization
            })
        );
        (pendingDeutilizationInProduct,) = _pendingDeutilization(
            InternalPendingDeutilization({
                hedgeManager: _hedgeManager,
                asset: _asset,
                product: _product,
                totalSupply: totalSupply,
                exposure: $.spotManager.exposure(),
                processingRebalanceDown: _processingRebalanceDown,
                paused: _paused,
                maxAmount: maxDeutilization
            })
        );

        uint256 pendingUtilizationInProduct = _oracle.convertTokenAmount(_asset, _product, pendingUtilizationInAsset);
        if (pendingUtilizationInProduct < _hedgeManager.increaseSizeMin()) pendingUtilizationInAsset = 0;
        // When processing rebalance down, deutilization should be at least decreaseSizeMin
        uint256 decreaseSizeMin = _hedgeManager.decreaseSizeMin();
        if (pendingDeutilizationInProduct > 0 && pendingDeutilizationInProduct < decreaseSizeMin) {
            if (_processingRebalanceDown) {
                pendingDeutilizationInProduct = decreaseSizeMin;
            } else {
                pendingDeutilizationInProduct = 0;
            }
        }

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
    function _adjustPosition(
        uint256 sizeDeltaInTokens,
        uint256 collateralDeltaAmount,
        bool isIncrease,
        bool emitRequest
    ) internal virtual returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        IHedgeManager _hedgeManager = $.hedgeManager;

        if (isIncrease && collateralDeltaAmount > 0) {
            $.asset.safeTransferFrom(vault(), address(_hedgeManager), collateralDeltaAmount);
        }

        IHedgeManager.AdjustPositionPayload memory requestParams = IHedgeManager.AdjustPositionPayload({
            sizeDeltaInTokens: sizeDeltaInTokens,
            collateralDeltaAmount: collateralDeltaAmount,
            isIncrease: isIncrease
        });
        $.requestParams = requestParams;
        return _hedgeManager.adjustPosition(requestParams, emitRequest);
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

        uint256 idleAssets = _vault.idleAssets();

        if (rebalanceDownNeeded) {
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

        // clear reserved execution cost when there is no idle to utilize in vault
        // and when there is no pending withdraw request
        // if it is none-zero
        if (idleAssets == 0 && assetsToDeutilize() == 0 && $.reservedExecutionCost > 0) {
            result.clearReservedExecutionCost = true;
        }

        return result;
    }

    /// @dev Called after the hedge position is increased.
    function _afterIncreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IHedgeManager.AdjustPositionPayload memory requestParams = $.requestParams;
        uint256 _responseDeviationThreshold = config().responseDeviationThreshold();

        if (requestParams.sizeDeltaInTokens > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                revert Errors.HedgeInvalidSizeResponse();
            }
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.collateralDeltaAmount, requestParams.collateralDeltaAmount, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                revert Errors.HedgeInvalidCollateralResponse();
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                $.hedgeManager.currentLeverage(), targetLeverage(), config().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            $.processingRebalanceDown = $.processingRebalanceDown && rebalanceDownNeeded;
        }
    }

    /// @dev Called after the hedge position is decreased.
    function _afterDecreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams) private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        IHedgeManager.AdjustPositionPayload memory requestParams = $.requestParams;

        if (requestParams.sizeDeltaInTokens == type(uint256).max) {
            // when closing hedge
            // size delta and collateral delta should be none zero
            if (responseParams.sizeDeltaInTokens == 0 || responseParams.collateralDeltaAmount == 0) {
                revert Errors.HedgeWrongCloseResponse();
            }
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
                revert Errors.HedgeInvalidSizeResponse();
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
                revert Errors.HedgeInvalidCollateralResponse();
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

    function _maxUtilization(uint256 _idleAssets, uint256 _utilizedAssets) private view returns (uint256) {
        return (_idleAssets + _utilizedAssets).mulDiv(maxUtilizePct(), Constants.FLOAT_PRECISION);
    }

    function _capAmount(uint256 amount, uint256 cap) private pure returns (uint256) {
        return amount > cap ? cap : amount;
    }

    /// @dev This return value should be 0 when rebalancing down or when paused or when the totalSupply is 0.
    function _pendingUtilization(InternalPendingUtilization memory params)
        private
        view
        returns (uint256 amount, uint256 uncappedAmount)
    {
        // don't use utilize function when rebalancing or when totalSupply is zero, or when paused
        if (params.totalSupply == 0 || params.processingRebalanceDown || params.paused) {
            return (0, 0);
        } else {
            uint256 withdrawBuffer =
                params.totalAssets.mulDiv(config().withdrawBufferThreshold(), Constants.FLOAT_PRECISION);
            (, uint256 availableAssets) = params.idleAssets.trySub(withdrawBuffer);
            uncappedAmount =
                availableAssets.mulDiv(params.targetLeverage, Constants.FLOAT_PRECISION + params.targetLeverage);
            amount = _capAmount(uncappedAmount, params.maxAmount);
            return (amount, uncappedAmount);
        }
    }

    /// @dev This return value should be 0 when paused and not processing rebalance down.
    function _pendingDeutilization(InternalPendingDeutilization memory params)
        private
        view
        returns (uint256 amount, uint256 uncappedAmount)
    {
        // disable only withdraw deutilization
        if (!params.processingRebalanceDown && params.paused) return (0, 0);

        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (params.totalSupply == 0) {
            uncappedAmount = params.exposure;
            amount = _capAmount(params.exposure, params.maxAmount);
            return (amount, uncappedAmount);
        }

        uint256 positionSizeInTokens = params.hedgeManager.positionSizeInTokens();
        uint256 positionSizeInAssets = $.oracle.convertTokenAmount(params.product, params.asset, positionSizeInTokens);
        uint256 positionNetBalance = params.hedgeManager.positionNetBalance();
        if (positionSizeInAssets == 0 || positionNetBalance == 0) return (0, 0);

        uint256 totalPendingWithdraw = assetsToDeutilize();

        if (params.processingRebalanceDown) {
            // for rebalance
            uint256 currentLeverage = params.hedgeManager.currentLeverage();
            uint256 _targetLeverage = $.targetLeverage;
            if (currentLeverage > _targetLeverage) {
                // calculate deutilization product
                // when totalPendingWithdraw is enough big to prevent increasing collateral
                uint256 deltaLeverage = currentLeverage - _targetLeverage;
                uncappedAmount = positionSizeInTokens.mulDiv(deltaLeverage, currentLeverage);
                uint256 deutilizationInAsset = $.oracle.convertTokenAmount(params.product, params.asset, uncappedAmount);

                // when totalPendingWithdraw is not enough big to prevent increasing collateral
                if (totalPendingWithdraw < deutilizationInAsset) {
                    uint256 num = deltaLeverage + _targetLeverage.mulDiv(totalPendingWithdraw, positionNetBalance);
                    uint256 den = currentLeverage + _targetLeverage.mulDiv(positionSizeInAssets, positionNetBalance);
                    uncappedAmount = positionSizeInTokens.mulDiv(num, den);
                }
            }
        } else {
            if (totalPendingWithdraw == 0) return (0, 0);

            uncappedAmount =
                positionSizeInTokens.mulDiv(totalPendingWithdraw, positionSizeInAssets + positionNetBalance);
        }

        uncappedAmount = _capAmount(uncappedAmount, params.exposure);
        amount = _capAmount(uncappedAmount, params.maxAmount);

        return (amount, uncappedAmount);
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

    function _calculateDeltaCollateralForUtilize(uint256 _utilization, uint256 _targetLeverage)
        internal
        pure
        returns (uint256)
    {
        return _utilization.mulDiv(Constants.FLOAT_PRECISION, _targetLeverage);
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

    function _processUtilizingExecutionCost() private {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        uint256 _utilizingExecutionCost = $.utilizingExecutionCost;
        delete $.utilizingExecutionCost;
        $.reservedExecutionCost -= _utilizingExecutionCost;
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

    /// @notice Execution cost to be processed in the next utilization / deutilization.
    function reservedExecutionCost() public view returns (uint256) {
        return _getBasisStrategyStorage().reservedExecutionCost;
    }

    /// @notice Percentage of vault's TVL that caps pending utilization/deutilization.
    function maxUtilizePct() public view returns (uint256) {
        return _getBasisStrategyStorage().maxUtilizePct;
    }
}
