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
import {BasisStrategyState, StrategyStatus} from "../libraries/strategy/BasisStrategyState.sol";
import {Utilization} from "../libraries/strategy/Utilization.sol";
import {Deutilization} from "../libraries/strategy/Deutilization.sol";
import {Position} from "../libraries/strategy/Position.sol";
import {AssetsState} from "../libraries/strategy/AssetsState.sol";

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
        // process pending decrease collateral
        bool processPendingDecreaseCollateral;
        // rebalance up by decreasing collateral
        uint256 deltaCollateralToDecrease;
        // eliminate pending exection cost
        bool clearReservedExecutionCost;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

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

        BasisStrategyState.setProduct(_product);
        BasisStrategyState.setAsset(_asset);
        BasisStrategyState.setVault(_vault);
        BasisStrategyState.setOracle(_oracle);
        BasisStrategyState.setConfig(_config);

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
        if (_targetLeverage == 0) revert();
        if (targetLeverage() != _targetLeverage) {
            BasisStrategyState.setTargetLeverage(_targetLeverage);
        }
        if (_minLeverage >= _targetLeverage) revert();
        if (minLeverage() != _minLeverage) {
            BasisStrategyState.setMinLeverage(_minLeverage);
        }
        if (_maxLeverage <= _targetLeverage) revert();
        if (maxLeverage() != _maxLeverage) {
            BasisStrategyState.setMaxLeverage(_maxLeverage);
        }
        if (_safeMarginLeverage <= _maxLeverage) revert();
        if (safeMarginLeverage() != _safeMarginLeverage) {
            BasisStrategyState.setSafeMarginLeverage(_safeMarginLeverage);
        }

        emit LeverageConfigUpdated(_msgSender(), _targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
    }

    function _setOperator(address newOperator) internal {
        if (newOperator == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (operator() != newOperator) {
            BasisStrategyState.setOperator(newOperator);
            emit OperatorUpdated(_msgSender(), newOperator);
        }
    }

    function _setMaxUtilizePct(uint256 value) internal {
        require(value > 0 && value <= 1 ether);
        if (maxUtilizePct() != value) {
            BasisStrategyState.setMaxUtilizePct(value);
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
            BasisStrategyState.setSpotManager(newSpotManager);
            emit SpotManagerUpdated(_msgSender(), newSpotManager);
        }
    }

    /// @notice Sets the hedge manager.
    function setHedgeManager(address newHedgeManager) external onlyOwner {
        if (hedgeManager() != newHedgeManager) {
            IHedgeManager manager = IHedgeManager(newHedgeManager);
            require(manager.collateralToken() == asset());
            BasisStrategyState.setHedgeManager(newHedgeManager);
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
        BasisStrategyState.setProcessingRebalanceDown(false);
        _setStrategyStatus(StrategyStatus.DEUTILIZING);
        ISpotManager _spotManager = BasisStrategyState.getSpotManager();
        _spotManager.sell(_spotManager.exposure(), ISpotManager.SwapType.MANUAL, "");
        Position.adjustPosition(type(uint256).max, type(uint256).max, false, true);
        _pause();

        emit Stopped(_msgSender());
    }

    function forceRebalance() external onlyOwner whenNotPaused whenIdle {
        _forceRebalance();
    }

    function _forceRebalance() internal {
        uint256 _targetLeverage = targetLeverage();
        InternalCheckUpkeepResult memory result = _checkUpkeep(_targetLeverage, _targetLeverage, safeMarginLeverage());
        _performUpkeep(result);
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
        Utilization.utilize(paused(), amount, swapType, swapData);
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
        Deutilization.deutilize(paused(), amount, swapType, swapData);
    }

    function reserveExecutionCost(uint256 amount) external authCaller(vault()) {
        uint256 _reservedExecutionCost = BasisStrategyState.getReservedExecutionCost();
        BasisStrategyState.setReservedExecutionCost(_reservedExecutionCost + amount);
    }

    /*//////////////////////////////////////////////////////////////
                            KEEPER LOGIC   
    //////////////////////////////////////////////////////////////*/

    /// @notice Processes idle assets for the withdraw requests.
    ///
    /// @dev Callable by anyone and only when strategy is in the IDLE status.
    function processAssetsToWithdraw() public whenIdle {
        IERC20 _asset = BasisStrategyState.getAsset();
        address _hedgeManager = address(BasisStrategyState.getHedgeManager());
        uint256 idleCollateral = _asset.balanceOf(_hedgeManager);
        if (idleCollateral > 0) {
            _asset.safeTransferFrom(_hedgeManager, address(this), idleCollateral);
        }
        _processAssetsToWithdraw(address(_asset));
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes memory) public view returns (bool upkeepNeeded, bytes memory performData) {
        InternalCheckUpkeepResult memory result = _checkUpkeep(minLeverage(), maxLeverage(), safeMarginLeverage());

        upkeepNeeded = result.emergencyDeutilizationAmount > 0 || result.deltaCollateralToIncrease > 0
            || result.clearProcessingRebalanceDown || result.hedgeDeviationInTokens != 0 || result.hedgeManagerNeedKeep
            || result.deltaCollateralToDecrease > 0 || result.clearReservedExecutionCost
            || result.processPendingDecreaseCollateral;

        performData = abi.encode(result);

        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /*performData*/ ) external {
        InternalCheckUpkeepResult memory result = _checkUpkeep(minLeverage(), maxLeverage(), safeMarginLeverage());
        _performUpkeep(result);
    }

    function _performUpkeep(InternalCheckUpkeepResult memory result) internal {
        _setStrategyStatus(StrategyStatus.KEEPING);

        if (result.clearReservedExecutionCost) {
            BasisStrategyState.setReservedExecutionCost(0);
        }

        ISpotManager _spotManager = BasisStrategyState.getSpotManager();
        if (result.emergencyDeutilizationAmount > 0) {
            BasisStrategyState.setProcessingRebalanceDown(true);
            _setStrategyStatus(StrategyStatus.DEUTILIZING);
            if (_spotManager.isXChain()) {
                uint256 round = Position.adjustPosition(result.emergencyDeutilizationAmount, 0, false, false);
                _spotManager.sell(
                    result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, abi.encode(round, 0)
                );
            } else {
                Position.adjustPosition(result.emergencyDeutilizationAmount, 0, false, true);
                _spotManager.sell(result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, "");
            }
        } else if (result.deltaCollateralToIncrease > 0) {
            BasisStrategyState.setProcessingRebalanceDown(true);
            ILogarithmVault _vault = BasisStrategyState.getVault();
            uint256 idleAssets = _vault.idleAssets();
            result.deltaCollateralToIncrease =
                idleAssets < result.deltaCollateralToIncrease ? idleAssets : result.deltaCollateralToIncrease;
            if (
                result.deltaCollateralToIncrease > 0
                    && result.deltaCollateralToIncrease >= BasisStrategyState.getHedgeManager().increaseCollateralMin()
            ) {
                Position.adjustPosition(0, result.deltaCollateralToIncrease, true, true);
            } else {
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        } else if (result.clearProcessingRebalanceDown) {
            BasisStrategyState.setProcessingRebalanceDown(false);
            _setStrategyStatus(StrategyStatus.IDLE);
        } else if (result.hedgeDeviationInTokens != 0) {
            if (result.hedgeDeviationInTokens > 0) {
                Position.adjustPosition(uint256(result.hedgeDeviationInTokens), 0, false, true);
            } else {
                uint256 hedgeDeviationInTokens = uint256(-result.hedgeDeviationInTokens);
                // not increase hedge size as it includes risks, instead sell spot
                // in x chain, sell spot while not adjusting hedge position
                BasisStrategyState.getSpotManager().sell(hedgeDeviationInTokens, ISpotManager.SwapType.MANUAL, "");
            }
        } else if (result.hedgeManagerNeedKeep) {
            BasisStrategyState.getHedgeManager().keep();
        } else if (result.processPendingDecreaseCollateral) {
            // where pendingWithdraw <= pendingDecreaseCollateral
            uint256 minDecreaseCollateral = BasisStrategyState.getHedgeManager().decreaseCollateralMin();
            uint256 _pendingDecreaseCollateral = pendingDecreaseCollateral();
            if (_pendingDecreaseCollateral < minDecreaseCollateral) {
                // pending decrease collateral is too small, so we just remove it
                BasisStrategyState.setPendingDecreaseCollateral(0);
                _setStrategyStatus(StrategyStatus.IDLE);
            } else {
                Position.adjustPosition(0, _pendingDecreaseCollateral, false, true);
            }
        } else if (result.deltaCollateralToDecrease > 0) {
            Position.adjustPosition(0, result.deltaCollateralToDecrease, false, true);
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
            Position.adjustPosition(
                productDelta, _calculateDeltaCollateralForUtilize(assetDelta, targetLeverage()), true, true
            );
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

        IERC20 _asset = BasisStrategyState.getAsset();

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

        BasisStrategyState.deleteRequestParams();

        emit PositionAdjusted(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    function harvestPerformanceFee() external authCaller(hedgeManager()) {
        BasisStrategyState.getVault().harvestPerformanceFee();
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

        // when strategy is in processing, return 0
        // so that operator doesn't need to take care of status
        if (BasisStrategyState.getStrategyStatus() != StrategyStatus.IDLE) {
            return (0, 0);
        }

        IHedgeManager _hedgeManager = BasisStrategyState.getHedgeManager();

        bool _paused = paused();
        uint256 uncappedPendingDeutilization;
        (pendingUtilizationInAsset,) = Utilization.pendingUtilization(_paused);
        (pendingDeutilizationInProduct, uncappedPendingDeutilization) = Deutilization.pendingDeutilization(_paused);

        uint256 pendingUtilizationInProduct = BasisStrategyState.getOracle().convertTokenAmount(
            address(BasisStrategyState.getAsset()), address(BasisStrategyState.getProduct()), pendingUtilizationInAsset
        );
        if (pendingUtilizationInProduct < _hedgeManager.increaseSizeMin()) pendingUtilizationInAsset = 0;
        // When processing rebalance down, deutilization should be at least decreaseSizeMin
        uint256 decreaseSizeMin = _hedgeManager.decreaseSizeMin();
        if (pendingDeutilizationInProduct > 0) {
            (, uint256 absoluteThreshold) = uncappedPendingDeutilization.trySub(decreaseSizeMin);
            if (pendingDeutilizationInProduct < decreaseSizeMin) {
                if (BasisStrategyState.getProcessingRebalanceDown()) {
                    pendingDeutilizationInProduct = decreaseSizeMin;
                } else {
                    pendingDeutilizationInProduct = 0;
                }
            } else if (pendingDeutilizationInProduct > absoluteThreshold) {
                pendingDeutilizationInProduct = uncappedPendingDeutilization;
            }
        }

        return (pendingUtilizationInAsset, pendingDeutilizationInProduct);
    }

    /// @notice The total underlying asset amount that has been utilized by this strategy.
    ///
    /// @dev Includes the product balance, the position net balance, and the asset balance of this strategy.
    function utilizedAssets() public view returns (uint256) {
        return AssetsState._utilizedAssets();
    }

    /// @notice The asset balance of this strategy.
    ///
    /// @dev This value should be transferred to the vault after finishing strategy operations.
    function assetsToWithdraw() public view returns (uint256) {
        return AssetsState._assetsToWithdraw();
    }

    /// @notice The total asset amount that is needed to be withdrawn from strategy to vault to process withdraw requests.
    function assetsToDeutilize() public view returns (uint256) {
        return AssetsState._assetsToDeutilize();
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Common function of checkUpkeep and performUpkeep.
    function _checkUpkeep(uint256 _minLeverage, uint256 _maxLeverage, uint256 _safeMarginLeverage)
        private
        view
        returns (InternalCheckUpkeepResult memory result)
    {
        if (BasisStrategyState.getStrategyStatus() != StrategyStatus.IDLE) {
            return result;
        }

        ILogarithmVault _vault = BasisStrategyState.getVault();
        IHedgeManager _hedgeManager = BasisStrategyState.getHedgeManager();

        uint256 currentLeverage = _hedgeManager.currentLeverage();
        bool _processingRebalanceDown = BasisStrategyState.getProcessingRebalanceDown();

        uint256 _targetLeverage = BasisStrategyState.getTargetLeverage();

        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool deleverageNeeded) =
            _checkRebalance(currentLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);

        // rebalanceDownNeeded becomes true if currentLeverage is not near to target
        // when processingRebalanceDown is true
        // even though current leverage is smaller than max
        if (!rebalanceDownNeeded && _processingRebalanceDown) {
            (, rebalanceDownNeeded) = _checkNeedRebalance(
                currentLeverage, _targetLeverage, BasisStrategyState.getConfig().rebalanceDeviationThreshold()
            );
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

        if (pendingDecreaseCollateral() > 0) {
            (, uint256 pendingDeutilization_) = Deutilization._pendingDeutilization(
                Deutilization.InternalPendingDeutilization({
                    hedgeManager: _hedgeManager,
                    asset: asset(),
                    product: product(),
                    totalSupply: _vault.totalSupply(),
                    exposure: BasisStrategyState.getSpotManager().exposure(),
                    processingRebalanceDown: false,
                    paused: paused(),
                    maxAmount: 0
                })
            );
            uint256 min = _hedgeManager.decreaseSizeMin();
            if (pendingDeutilization_ < min) {
                result.processPendingDecreaseCollateral = true;
                return result;
            }
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
        if (idleAssets == 0 && assetsToDeutilize() == 0 && reservedExecutionCost() > 0) {
            result.clearReservedExecutionCost = true;
        }

        return result;
    }

    /// @dev Called after the hedge position is increased.
    function _afterIncreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams) private {
        IHedgeManager.AdjustPositionPayload memory requestParams = BasisStrategyState.getRequestParams();
        uint256 _responseDeviationThreshold = BasisStrategyState.getConfig().responseDeviationThreshold();

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
                BasisStrategyState.getHedgeManager().currentLeverage(),
                BasisStrategyState.getTargetLeverage(),
                BasisStrategyState.getConfig().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            bool _processingRebalanceDown = BasisStrategyState.getProcessingRebalanceDown();
            BasisStrategyState.setProcessingRebalanceDown(_processingRebalanceDown && rebalanceDownNeeded);
        }

        // clear pending decrease collateral
        BasisStrategyState.setPendingDecreaseCollateral(0);
    }

    /// @dev Called after the hedge position is decreased.
    function _afterDecreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams) private {
        IHedgeManager.AdjustPositionPayload memory requestParams = BasisStrategyState.getRequestParams();

        if (requestParams.sizeDeltaInTokens == type(uint256).max) {
            // when closing hedge
            // size delta and collateral delta should be none zero
            if (responseParams.sizeDeltaInTokens == 0 || responseParams.collateralDeltaAmount == 0) {
                revert Errors.HedgeWrongCloseResponse();
            }
            requestParams.sizeDeltaInTokens = responseParams.sizeDeltaInTokens;
            requestParams.collateralDeltaAmount = responseParams.collateralDeltaAmount;
        }

        uint256 _responseDeviationThreshold = BasisStrategyState.getConfig().responseDeviationThreshold();
        IERC20 _asset = BasisStrategyState.getAsset();
        if (requestParams.sizeDeltaInTokens > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.sizeDeltaInTokens, requestParams.sizeDeltaInTokens, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                revert Errors.HedgeInvalidSizeResponse();
            }

            (, bool rebalanceDownNeeded) = _checkNeedRebalance(
                BasisStrategyState.getHedgeManager().currentLeverage(),
                BasisStrategyState.getTargetLeverage(),
                BasisStrategyState.getConfig().rebalanceDeviationThreshold()
            );
            // only when rebalance was started, we need to check
            bool _processingRebalanceDown = BasisStrategyState.getProcessingRebalanceDown();
            BasisStrategyState.setProcessingRebalanceDown(_processingRebalanceDown && rebalanceDownNeeded);
        }

        if (requestParams.collateralDeltaAmount > 0) {
            (bool exceedsThreshold,) = _checkDeviation(
                responseParams.collateralDeltaAmount, requestParams.collateralDeltaAmount, _responseDeviationThreshold
            );
            if (exceedsThreshold) {
                revert Errors.HedgeInvalidCollateralResponse();
            }
            // clear pending decrease collateral
            BasisStrategyState.setPendingDecreaseCollateral(0);
        }

        if (responseParams.collateralDeltaAmount > 0) {
            _asset.safeTransferFrom(_msgSender(), address(this), responseParams.collateralDeltaAmount);
        }
    }

    /// @dev Processes assetsToWithdraw for the withdraw requests
    function _processAssetsToWithdraw(address _asset) private {
        uint256 _assetsToWithdraw = assetsToWithdraw();
        if (_assetsToWithdraw == 0) return;
        ILogarithmVault _vault = BasisStrategyState.getVault();
        IERC20(_asset).safeTransfer(address(_vault), _assetsToWithdraw);
        _vault.processPendingWithdrawRequests();
    }

    function _maxUtilization(uint256 _idleAssets, uint256 _utilizedAssets) private view returns (uint256) {
        return (_idleAssets + _utilizedAssets).mulDiv(BasisStrategyState.getMaxUtilizePct(), Constants.FLOAT_PRECISION);
    }

    function _capAmount(uint256 amount, uint256 cap) private pure returns (uint256) {
        return amount > cap ? cap : amount;
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
        BasisStrategyState.setStrategyStatus(newStatus);
    }

    function _processUtilizingExecutionCost() private {
        uint256 _utilizingExecutionCost = BasisStrategyState.getUtilizingExecutionCost();
        BasisStrategyState.setUtilizingExecutionCost(0);
        uint256 _reservedExecutionCost = BasisStrategyState.getReservedExecutionCost();
        BasisStrategyState.setReservedExecutionCost(_reservedExecutionCost - _utilizingExecutionCost);
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of connected vault.
    function vault() public view returns (address) {
        return address(BasisStrategyState.getVault());
    }

    /// @notice The address of the spot manager which buys and sells product in spot markets.
    function spotManager() public view returns (address) {
        return address(BasisStrategyState.getSpotManager());
    }

    /// @notice The address of the position manager which hedges the spot by opening perpetual positions.
    function hedgeManager() public view returns (address) {
        return address(BasisStrategyState.getHedgeManager());
    }

    /// @notice The address of system oracle.
    function oracle() public view returns (address) {
        return address(BasisStrategyState.getOracle());
    }

    /// @notice The address of operator which is responsible for calling utilize/deutilize.
    function operator() public view returns (address) {
        return BasisStrategyState.getOperator();
    }

    /// @notice The address of underlying asset.
    function asset() public view returns (address) {
        return address(BasisStrategyState.getAsset());
    }

    /// @notice The address of product.
    function product() public view returns (address) {
        return address(BasisStrategyState.getProduct());
    }

    /// @notice The address of Config smart contract that is used throughout all strategies for their configurations.
    function config() public view returns (IStrategyConfig) {
        return IStrategyConfig(BasisStrategyState.getConfig());
    }

    /// @notice The strategy status.
    function strategyStatus() public view returns (StrategyStatus) {
        return BasisStrategyState.getStrategyStatus();
    }

    /// @notice The target leverage at which the hedge position is increased.
    function targetLeverage() public view returns (uint256) {
        return BasisStrategyState.getTargetLeverage();
    }

    /// @notice The minimum leverage value to which the hedge position can be reached down.
    function minLeverage() public view returns (uint256) {
        return BasisStrategyState.getMinLeverage();
    }

    /// @notice The maximum leverage value to which the hedge position can be reached up.
    function maxLeverage() public view returns (uint256) {
        return BasisStrategyState.getMaxLeverage();
    }

    /// @notice The maximum leverage value where normal rebalancing down is applied.
    /// If the leverage overshoots it, emergency rebalancing down is executed.
    function safeMarginLeverage() public view returns (uint256) {
        return BasisStrategyState.getSafeMarginLeverage();
    }

    /// @notice Tells if strategy is in rebalancing down.
    function processingRebalanceDown() public view returns (bool) {
        return BasisStrategyState.getProcessingRebalanceDown();
    }

    /// @notice Execution cost to be processed in the next utilization / deutilization.
    function reservedExecutionCost() public view returns (uint256) {
        return BasisStrategyState.getReservedExecutionCost();
    }

    /// @notice Percentage of vault's TVL that caps pending utilization/deutilization.
    function maxUtilizePct() public view returns (uint256) {
        return BasisStrategyState.getMaxUtilizePct();
    }

    /// @notice The pending decrease collateral to save execution cost by executing in a larger size.
    function pendingDecreaseCollateral() public view returns (uint256) {
        return BasisStrategyState.getPendingDecreaseCollateral();
    }
}
