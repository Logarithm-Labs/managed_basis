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

/// @title A basis strategy
/// @author Logarithm Labs
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

    enum StrategyStatus {
        IDLE,
        KEEPING,
        UTILIZING,
        PARTIAL_DEUTILIZING,
        FULL_DEUTILIZING
    }

    struct InternalPendingDeutilization {
        IPositionManager positionManager;
        address asset;
        address product;
        uint256 totalSupply;
        bool processingRebalanceDown;
        bool paused;
    }

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
        uint256 pendingDeutilizedAssets;
        uint256 pendingDecreaseCollateral;
        // status state
        StrategyStatus strategyStatus;
        bool processingRebalanceDown;
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

    event Deutilize(address indexed caller, uint256 productDelta, uint256 assetDelta);

    event AfterAdjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier authCaller(address authorized) {
        if (_msgSender() != authorized) {
            revert Errors.CallerNotAuthorized(authorized, _msgSender());
        }
        _;
    }

    modifier onlyOwnerOrVault() {
        if (_msgSender() != owner() && _msgSender() != vault()) {
            revert Errors.CallerNotOwnerOrVault();
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
        $.operator = _operator;
        $.config = _config;

        _setLeverages(_targetLeverage, _minLeverage, _maxLeverage, _safeMarginLeverage);
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

    function setSpotManager(address _spotManager) external onlyOwner {
        if (_spotManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getBasisStrategyStorage().spotManager = ISpotManager(_spotManager);
    }

    function setPositionManager(address _positionManager) external onlyOwner {
        if (_positionManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getBasisStrategyStorage().positionManager = IPositionManager(_positionManager);
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

    function pause() external onlyOwnerOrVault whenNotPaused {
        _pause();
    }

    function unpause() external onlyOwnerOrVault whenPaused {
        _unpause();
    }

    function stop() external onlyOwnerOrVault whenNotPaused {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        delete $.pendingDecreaseCollateral;
        delete $.pendingDeutilizedAssets;
        delete $.processingRebalanceDown;
        $.strategyStatus = StrategyStatus.FULL_DEUTILIZING;
        ISpotManager _spotManager = $.spotManager;
        _spotManager.sell(_spotManager.exposure(), ISpotManager.SwapType.MANUAL, "");
        _pause();
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE/DEUTILZE   
    //////////////////////////////////////////////////////////////*/

    /// @dev utilize asset
    ///
    /// @param amount is the asset value to be utilized
    /// @param swapType is the swap type of inch or manual
    /// @param swapData is the data used in inch
    function utilize(uint256 amount, ISpotManager.SwapType swapType, bytes calldata swapData)
        external
        virtual
        authCaller(operator())
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        StrategyStatus strategyStatus_ = $.strategyStatus;

        // can only utilize when the strategy status is IDLE
        if (strategyStatus_ != StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(strategyStatus_));
        }
        $.strategyStatus = StrategyStatus.UTILIZING;

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

    /// @dev deutilize product
    ///
    /// @param amount is the product value to be deutilized
    /// @param swapType is the swap type of inch or manual
    /// @param swapData is the data used in inch
    function deutilize(uint256 amount, ISpotManager.SwapType swapType, bytes calldata swapData)
        external
        authCaller(operator())
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        StrategyStatus strategyStatus_ = $.strategyStatus;

        // can only deutilize when the strategy status is IDLE
        if (strategyStatus_ != StrategyStatus.IDLE) {
            revert Errors.InvalidStrategyStatus(uint8(strategyStatus_));
        }

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
            $.strategyStatus = StrategyStatus.FULL_DEUTILIZING;
        } else {
            $.strategyStatus = StrategyStatus.PARTIAL_DEUTILIZING;
        }

        $.spotManager.sell(amount, swapType, swapData);
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
            _processAssetsToWithdraw(address($.asset));
        }
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
    function performUpkeep(bytes calldata /*performData*/ ) external {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        InternalCheckUpkeepResult memory result = _checkUpkeep();

        $.strategyStatus = StrategyStatus.KEEPING;

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
            ) $.strategyStatus = StrategyStatus.IDLE;
        } else if (result.clearProcessingRebalanceDown) {
            $.processingRebalanceDown = false;
            $.strategyStatus = StrategyStatus.IDLE;
        } else if (result.hedgeDeviationInTokens != 0) {
            if (result.hedgeDeviationInTokens > 0) {
                if (!_adjustPosition(uint256(result.hedgeDeviationInTokens), 0, false)) {
                    $.strategyStatus = StrategyStatus.IDLE;
                }
            } else {
                uint256 hedgeDeviationInTokens = uint256(-result.hedgeDeviationInTokens);
                if (!_adjustPosition(hedgeDeviationInTokens, 0, true)) {
                    $.strategyStatus = StrategyStatus.IDLE;
                    $.spotManager.sell(hedgeDeviationInTokens, ISpotManager.SwapType.MANUAL, "");
                }
            }
        } else if (result.positionManagerNeedKeep) {
            $.positionManager.keep();
        } else if (result.processPendingDecreaseCollateral) {
            if (!_adjustPosition(0, $.pendingDecreaseCollateral, false)) {
                $.strategyStatus = StrategyStatus.IDLE;
            }
        } else if (result.deltaCollateralToDecrease > 0) {
            if (!_adjustPosition(0, result.deltaCollateralToDecrease, false)) {
                $.strategyStatus = StrategyStatus.IDLE;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function spotBuyCallback(uint256 assetDelta, uint256 productDelta) external authCaller(spotManager()) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        if (strategyStatus() == StrategyStatus.UTILIZING) {
            if (productDelta == 0) {
                // fail to buy product
                $.asset.safeTransferFrom(_msgSender(), vault(), assetDelta);
                $.strategyStatus = StrategyStatus.IDLE;
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
            $.strategyStatus = StrategyStatus.IDLE;
        }
    }

    function spotSellCallback(uint256 assetDelta, uint256 productDelta) external authCaller(spotManager()) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        StrategyStatus status = strategyStatus();
        if (status == StrategyStatus.UTILIZING || status == StrategyStatus.IDLE) {
            // revert utilizing
            ILogarithmVault _vault = $.vault;
            $.asset.safeTransferFrom(_msgSender(), address(_vault), assetDelta);
            if (status == StrategyStatus.UTILIZING) $.strategyStatus = StrategyStatus.IDLE;
            _vault.processPendingWithdrawRequests();
        } else {
            if (assetDelta == 0) {
                // fail to sell product
                $.strategyStatus = StrategyStatus.IDLE;
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

    // callback function dispatcher
    function afterAdjustPosition(IPositionManager.AdjustPositionPayload calldata params)
        external
        authCaller(positionManager())
    {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();

        if (strategyStatus() == StrategyStatus.IDLE) {
            revert Errors.InvalidCallback();
        }
        $.strategyStatus = StrategyStatus.IDLE;

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

        emit AfterAdjustPosition(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

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
        address _asset = address($.asset);
        address _product = address($.product);
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

    /// @dev return assets that are utilized across spot and hedge
    function utilizedAssets() public view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        uint256 productBalance = $.spotManager.exposure();
        uint256 productValueInAssets = $.oracle.convertTokenAmount(product(), asset(), productBalance);
        return productValueInAssets + $.positionManager.positionNetBalance() + assetsToWithdraw();
    }

    /// @dev Assets that are pending to process withdraw requests.
    function assetsToWithdraw() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function assetsToDeutilize() public view returns (uint256) {
        BasisStrategyStorage storage $ = _getBasisStrategyStorage();
        (, uint256 assets) = $.vault.totalPendingWithdraw().trySub(assetsToWithdraw());
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                           PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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

    /// @dev process assetsToWithdraw for the withdraw requests
    function _processAssetsToWithdraw(address _asset) private {
        uint256 _assetsToWithdraw = assetsToWithdraw();
        if (_assetsToWithdraw == 0) return;
        ILogarithmVault _vault = ILogarithmVault(vault());
        IERC20(_asset).safeTransfer(address(_vault), _assetsToWithdraw);
        _vault.processPendingWithdrawRequests();
    }

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

    /// @dev should be called under the condition that denominator != 0
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

    /// @dev check if current leverage is not near to the target leverage
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
    /// @param _hedgeDeviationThreshold uint256
    ///
    /// @return hedge deviation of int type
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

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function vault() public view returns (address) {
        return address(_getBasisStrategyStorage().vault);
    }

    function spotManager() public view returns (address) {
        return address(_getBasisStrategyStorage().spotManager);
    }

    function positionManager() public view returns (address) {
        return address(_getBasisStrategyStorage().positionManager);
    }

    function oracle() public view returns (address) {
        return address(_getBasisStrategyStorage().oracle);
    }

    function operator() public view returns (address) {
        return _getBasisStrategyStorage().operator;
    }

    function asset() public view returns (address) {
        return address(_getBasisStrategyStorage().asset);
    }

    function product() public view returns (address) {
        return address(_getBasisStrategyStorage().product);
    }

    function config() public view returns (IStrategyConfig) {
        return IStrategyConfig(_getBasisStrategyStorage().config);
    }

    function strategyStatus() public view returns (StrategyStatus) {
        return _getBasisStrategyStorage().strategyStatus;
    }

    function targetLeverage() public view returns (uint256) {
        return _getBasisStrategyStorage().targetLeverage;
    }

    function pendingDecreaseCollateral() public view returns (uint256) {
        return _getBasisStrategyStorage().pendingDecreaseCollateral;
    }

    function processingRebalanceDown() public view returns (bool) {
        return _getBasisStrategyStorage().processingRebalanceDown;
    }
}
