// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IOrderCallbackReceiver} from "src/externals/gmx-v2/interfaces/IOrderCallbackReceiver.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {EventUtils} from "src/externals/gmx-v2/libraries/EventUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Order} from "src/externals/gmx-v2/libraries/Order.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {Errors} from "src/libraries/Errors.sol";
import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";

import {FactoryDeployable} from "src/common/FactoryDeployable.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract must be deployed only by the factory
contract GmxV2PositionManager is IPositionManager, IOrderCallbackReceiver, UUPSUpgradeable, FactoryDeployable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant PRECISION = 1e18;
    string constant API_VERSION = "0.0.1";

    struct InternalCreateOrderParams {
        bool isLong;
        bool isIncrease;
        address exchangeRouter;
        address strategy;
        address collateralToken;
        uint256 collateralDelta;
        uint256 sizeDeltaInUsd;
        uint256 executionFee;
        uint256 callbackGasLimit;
        bytes32 referralCode;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager
    struct GmxV2PositionManagerStorage {
        // configuration
        address _strategy;
        address _keeper;
        address _marketToken;
        address _indexToken;
        address _longToken;
        address _shortToken;
        address _collateralToken;
        bool _isLong;
        uint256 _maxClaimableFundingShare;
        uint256 _maxHedgeDeviation;
        // state
        bytes32 _pendingIncreaseOrderKey;
        bytes32 _pendingDecreaseOrderKey;
        uint256 _pendingCollateralAmount;
        uint256 _idleCollateralAmount;
        // state for calcuating execution cost
        uint256 _spotExecutionPrice;
        uint256 _sizeDeltaInUsd;
        uint256 _sizeInTokensBefore;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GmxV2PositionManagerStorageLocation =
        0xf08705b56fbd504746312a6db5deff16fc51a9c005f5e6a881519498d59a9600;

    function _getGmxV2PositionManagerStorage() private pure returns (GmxV2PositionManagerStorage storage $) {
        assembly {
            $.slot := GmxV2PositionManagerStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FundingClaimed(address indexed token, uint256 indexed amount);
    event CollateralClaimed(address indexed token, uint256 indexed amount);
    event OrderExecuted(bytes32 indexed orderKey);
    event OrderFailed(bytes32 indexed orderKey);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    modifier onlyKeeper() {
        _onlyKeeper();
        _;
    }

    modifier whenNotPending() {
        _whenNotPending();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address strategy_) external initializer {
        __FactoryDeployable_init();
        address _factory = msg.sender;
        address asset = address(IBasisStrategy(strategy_).asset());
        address product = address(IBasisStrategy(strategy_).product());
        address marketKey = IBasisGmxFactory(_factory).marketKey(asset, product);
        if (marketKey == address(0)) {
            revert Errors.InvalidMarket();
        }
        address dataStore = IBasisGmxFactory(_factory).dataStore();
        address reader = IBasisGmxFactory(_factory).reader();
        Market.Props memory market = IReader(reader).getMarket(dataStore, marketKey);
        // assuming short position open
        if ((market.longToken != asset && market.shortToken != asset) || (market.indexToken != product)) {
            revert Errors.InvalidInitializationAssets();
        }
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        $._strategy = strategy_;
        $._marketToken = market.marketToken;
        $._indexToken = market.indexToken;
        $._longToken = market.longToken;
        $._shortToken = market.shortToken;
        $._collateralToken = asset;
        $._isLong = false;

        $._maxClaimableFundingShare = 1e16; // 1%
        $._maxHedgeDeviation = 1e15; // 0.1%
    }

    function _authorizeUpgrade(address) internal virtual override onlyFactory {}

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev send back eth to the operator
    receive() external payable {
        (bool success,) = keeper().call{value: msg.value}("");
        assert(success);
    }

    /// @inheritdoc IPositionManager
    function setKeeper(address _keeper) external override onlyFactory {
        if (_keeper == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getGmxV2PositionManagerStorage()._keeper = _keeper;
    }

    function setMaxClaimableFundingShare(uint256 _maxClaimableFundingShare) external onlyFactory {
        require(_maxClaimableFundingShare < 1 ether);
        _getGmxV2PositionManagerStorage()._maxClaimableFundingShare = _maxClaimableFundingShare;
    }

    function setMaxHedgeDeviation(uint256 _maxDeviation) external onlyFactory {
        require(_maxDeviation < 1 ether);
        _getGmxV2PositionManagerStorage()._maxHedgeDeviation = _maxDeviation;
    }

    /// @dev transfer assetsToPositionManager into position manger from strategy
    /// Note: this function is called whenever users deposit tokens, so not create order
    function increaseCollateral(uint256 assetsToPositionManager) external onlyStrategy {
        _getGmxV2PositionManagerStorage()._idleCollateralAmount += assetsToPositionManager;
        IERC20(collateralToken()).safeTransferFrom(strategy(), address(this), assetsToPositionManager);
    }

    /// @dev increase position size
    /// Note: if there is idle collateral, then increase the collateral with it
    ///
    /// @return orderKey
    function increaseSize(uint256 sizeDeltaInTokens, uint256 spotExecutionPrice)
        external
        payable
        onlyStrategy
        whenNotPending
        returns (bytes32)
    {
        GmxV2Lib.GetPosition memory positionParams = _getPositionParams(_factory);
        _recordExecutionCostCalcInfo(positionParams, spotExecutionPrice);
        uint256 executionFee = msg.value;
        address _factory = factory();
        uint256 sizeDeltaInUsd =
            GmxV2Lib.getSizeDeltaInUsdForIncrease(positionParams, _getPricesParams(_factory), sizeDeltaInTokens);
        uint256 idleCollateralAmount = _getGmxV2PositionManagerStorage()._idleCollateralAmount;
        // if there is idle collateral, then transfer it to gmx vault
        if (idleCollateralAmount > 0) {
            _getGmxV2PositionManagerStorage()._pendingCollateralAmount = idleCollateralAmount;
            _getGmxV2PositionManagerStorage()._idleCollateralAmount = 0;
            IERC20(collateralToken()).safeTransfer(IBasisGmxFactory(_factory).orderVault(), idleCollateralAmount);
        }
        return _createOrder(
            InternalCreateOrderParams({
                isLong: isLong(),
                isIncrease: true,
                exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                strategy: strategy(),
                collateralToken: collateralToken(),
                collateralDelta: idleCollateralAmount,
                sizeDeltaInUsd: sizeDeltaInUsd,
                executionFee: executionFee,
                callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                referralCode: IBasisGmxFactory(_factory).referralCode()
            })
        );
    }

    function decreaseSize(uint256 sizeDeltaInTokens, uint256 spotExecutionPrice)
        external
        payable
        onlyStrategy
        whenNotPending
        returns (bytes32)
    {
        GmxV2Lib.GetPosition memory positionParams = _getPositionParams(_factory);
        _recordExecutionCostCalcInfo(positionParams, spotExecutionPrice);
        uint256 executionFee = msg.value;
        address _factory = factory();
        uint256 sizeDeltaInUsd = GmxV2Lib.getSizeDeltaInUsdForDecrease(positionParams, sizeDeltaInTokens);
        return _createOrder(
            InternalCreateOrderParams({
                isLong: isLong(),
                isIncrease: false,
                exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                strategy: strategy(),
                collateralToken: collateralToken(),
                collateralDelta: 0,
                sizeDeltaInUsd: sizeDeltaInUsd,
                executionFee: executionFee,
                callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                referralCode: IBasisGmxFactory(_factory).referralCode()
            })
        );
    }

    /// @dev remove collateral from position to strategy
    ///
    /// @param collateralDelta is the target delta amout to remove
    ///
    /// @return decreaseOrderKey is the order key of decreasing
    /// @return increaseOrderKey is the order key of increasing
    function decreaseCollateral(uint256 collateralDelta)
        external
        payable
        onlyStrategy
        whenNotPending
        returns (bytes32 decreaseOrderKey, bytes32 increaseOrderKey)
    {
        uint256 totalExecutionFee = msg.value;
        address _factory = factory();
        (, uint256 decreaseExecutionFee) = getExecutionFee();
        GmxV2Lib.GetPosition memory positionParams = _getPositionParams(_factory);
        GmxV2Lib.GetPrices memory pricesParams = _getPricesParams(_factory);
        (uint256 initialCollateralDelta, uint256 sizeDeltaInTokens) =
            GmxV2Lib.getDecreaseCollateralResult(positionParams, pricesParams, collateralDelta);

        uint256 sizeDeltaInUsdForDecrease = GmxV2Lib.getSizeDeltaInUsdForDecrease(positionParams, sizeDeltaInTokens);

        decreaseOrderKey = _createOrder(
            InternalCreateOrderParams({
                isLong: isLong(),
                isIncrease: false,
                exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                strategy: strategy(),
                collateralToken: collateralToken(),
                collateralDelta: initialCollateralDelta,
                sizeDeltaInUsd: sizeDeltaInUsdForDecrease,
                executionFee: decreaseExecutionFee,
                callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                referralCode: IBasisGmxFactory(_factory).referralCode()
            })
        );

        if (sizeDeltaInTokens > 0) {
            uint256 sizeDeltaInUsdForIncrease =
                GmxV2Lib.getSizeDeltaInUsdForIncrease(positionParams, pricesParams, sizeDeltaInTokens);
            increaseOrderKey = _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: true,
                    exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                    strategy: strategy(),
                    collateralToken: collateralToken(),
                    collateralDelta: 0,
                    sizeDeltaInUsd: sizeDeltaInUsdForIncrease,
                    executionFee: totalExecutionFee - decreaseExecutionFee,
                    callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                    referralCode: IBasisGmxFactory(_factory).referralCode()
                })
            );
        } else {
            // refund fee
            (bool success,) = keeper().call{value: totalExecutionFee - decreaseExecutionFee}("");
            assert(success);
        }
        return (decreaseOrderKey, increaseOrderKey);
    }

    /// @dev claims all the claimable funding fee
    /// this is callable by anyone
    function claimFunding() public {
        IExchangeRouter exchangeRouter = IExchangeRouter(IBasisGmxFactory(factory()).exchangeRouter());
        address marketTokenAddr = marketToken();
        address shortTokenAddr = shortToken();
        address longTokenAddr = longToken();

        address[] memory markets = new address[](2);
        markets[0] = marketTokenAddr;
        markets[1] = marketTokenAddr;
        address[] memory tokens = new address[](2);
        tokens[0] = shortTokenAddr;
        tokens[1] = longTokenAddr;
        uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, strategy());
        emit FundingClaimed(shortTokenAddr, amounts[0]);
        emit FundingClaimed(longTokenAddr, amounts[1]);
    }

    /// @dev claims all the claimable callateral amount
    /// Note: this amount stored by account, token, timeKey
    /// and there is only event to figure out it
    /// @param token token address derived from the gmx event: ClaimableCollateralUpdated
    /// @param timeKey timeKey value derived from the gmx event: ClaimableCollateralUpdated
    function claimCollateral(address token, uint256 timeKey) external {
        IExchangeRouter exchangeRouter = IExchangeRouter(IBasisGmxFactory(factory()).exchangeRouter());
        address[] memory markets = new address[](1);
        markets[0] = marketToken();
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory timeKeys = new uint256[](1);
        timeKeys[0] = timeKey;
        uint256[] memory amounts = exchangeRouter.claimCollateral(markets, tokens, timeKeys, strategy());
        emit CollateralClaimed(token, amounts[0]);
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderExecution(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory /* eventData */ )
        external
        override
    {
        _validateOrderHandler(key);
        _setPendingOrderKey(bytes32(0), order.numbers.orderType == Order.OrderType.MarketIncrease);
        _getGmxV2PositionManagerStorage()._pendingCollateralAmount = 0;
        uint256 spotExecutionPrice = _getGmxV2PositionManagerStorage()._spotExecutionPrice;
        if (spotExecutionPrice > 0) {
            uint256 _sizeInTokensBefore = _getGmxV2PositionManagerStorage()._sizeInTokensBefore;
            uint256 _sizeInTokensAfter = GmxV2Lib.getPositionSizeInTokens(_getPositionParams(factory()));
            int256 executionCostInUsd;
            if (order.numbers.orderType == Order.OrderType.MarketIncrease) {
                uint256 sizeDeltaInTokens = _sizeInTokensAfter - _sizeInTokensBefore;
                // executionCostInUsd = (spotExecutionPrice - hedgeExectuionPrice) * sizeDelta
                // sizeDeltaUsd = hedgeExectuionPrice * sizeDelta
                executionCostInUsd =
                    (spotExecutionPrice * sizeDeltaInTokens).toInt256() - order.numbers.sizeDeltaUsd.toInt256();
            } else {
                uint256 sizeDeltaInTokens = _sizeInTokensBefore - _sizeInTokensAfter;
                // executionCostInUsd = (hedgeExectuionPrice - spotExecutionPrice) * sizeDelta
                // sizeDeltaUsd = hedgeExectuionPrice * sizeDelta
                executionCostInUsd =
                    order.numbers.sizeDeltaUsd.toInt256() - (spotExecutionPrice * sizeDeltaInTokens).toInt256();
            }
            _wipeExecutionCostCalcInfo();
        }
        emit OrderExecuted(key);
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderCancellation(
        bytes32 key,
        Order.Props memory order,
        EventUtils.EventLogData memory /* eventData */
    ) external override {
        _validateOrderHandler(key);
        _setPendingOrderKey(bytes32(0), order.numbers.orderType == Order.OrderType.MarketIncrease);
        _wipeExecutionCostCalcInfo();
        uint256 pendingCollateralAmount = _getGmxV2PositionManagerStorage()._pendingCollateralAmount;
        if (pendingCollateralAmount > 0) {
            _getGmxV2PositionManagerStorage()._pendingCollateralAmount = 0;
            _getGmxV2PositionManagerStorage()._idleCollateralAmount += pendingCollateralAmount;
        }
        emit OrderFailed(key);
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderFrozen(
        bytes32, /* key */
        Order.Props memory, /* order */
        EventUtils.EventLogData memory /* eventData */
    ) external pure override {
        revert(); // fronzen is not supported for market increase/decrease orders
    }

    /// @notice claim funding or adjust size as needed
    function performUpkeep(bytes calldata performData) external payable onlyKeeper returns (bytes32) {
        (bool settleNeeded, bool adjustNeeded) = abi.decode(performData, (bool, bool));
        uint256 executionFee = msg.value;
        if (settleNeeded) {
            claimFunding();
        }
        if (adjustNeeded) {
            (, int256 sizeDeltaInTokens) = _checkAdjustPositionSize();
            address _factory = factory();
            if (sizeDeltaInTokens < 0) {
                uint256 sizeDeltaInUsd =
                    GmxV2Lib.getSizeDeltaInUsdForDecrease(_getPositionParams(_factory), uint256(-sizeDeltaInTokens));
                return _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: false,
                        exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                        strategy: strategy(),
                        collateralToken: collateralToken(),
                        collateralDelta: 0,
                        sizeDeltaInUsd: sizeDeltaInUsd,
                        executionFee: executionFee,
                        callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                        referralCode: IBasisGmxFactory(_factory).referralCode()
                    })
                );
            } else {
                uint256 sizeDeltaInUsd = GmxV2Lib.getSizeDeltaInUsdForIncrease(
                    _getPositionParams(_factory), _getPricesParams(_factory), uint256(-sizeDeltaInTokens)
                );
                return _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: true,
                        exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                        strategy: strategy(),
                        collateralToken: collateralToken(),
                        collateralDelta: 0,
                        sizeDeltaInUsd: sizeDeltaInUsd,
                        executionFee: executionFee,
                        callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                        referralCode: IBasisGmxFactory(_factory).referralCode()
                    })
                );
            }
        } else {
            // refund native token when not creating order
            (bool success,) = msg.sender.call{value: executionFee}("");
            assert(success);
        }
        return bytes32(0);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL/PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPositionManager
    function apiVersion() public pure override returns (string memory) {
        return API_VERSION;
    }

    /// @inheritdoc IPositionManager
    function totalAssets() public view override returns (uint256) {
        address _factory = factory();
        uint256 positionNetAmount = GmxV2Lib.getPositionNetAmount(
            _getPositionParams(_factory), _getPricesParams(_factory), IBasisGmxFactory(_factory).referralStorage()
        );
        return positionNetAmount + _getGmxV2PositionManagerStorage()._idleCollateralAmount
            + _getGmxV2PositionManagerStorage()._pendingCollateralAmount;
    }

    /// @notice calculate the execution fee that is need from gmx when increase and decrease
    ///
    /// @return feeIncrease the execution fee for increase
    /// @return feeDecrease the execution fee for decrease
    function getExecutionFee() public view returns (uint256 feeIncrease, uint256 feeDecrease) {
        address _factory = factory();
        return GmxV2Lib.getExecutionFee(
            IBasisGmxFactory(_factory).dataStore(), IBasisGmxFactory(_factory).callbackGasLimit()
        );
    }

    /// @notice check if position is need to be kept by claiming funding or adjusting size
    function checkUpkeep(bytes calldata) external view virtual returns (bool upkeepNeeded, bytes memory performData) {
        bool settleNeeded = _checkSettle();
        (bool adjustNeeded,) = _checkAdjustPositionSize();
        upkeepNeeded = (settleNeeded || adjustNeeded) && !_isPending();
        performData = abi.encode(settleNeeded, adjustNeeded);
        return (upkeepNeeded, performData);
    }

    function collateralToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._collateralToken;
    }

    function strategy() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._strategy;
    }

    function keeper() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._keeper;
    }

    function marketToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._marketToken;
    }

    function indexToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._indexToken;
    }

    function longToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._longToken;
    }

    function shortToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._shortToken;
    }

    function isLong() public view returns (bool) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._isLong;
    }

    function maxClaimableFundingShare() public view returns (uint256) {
        return _getGmxV2PositionManagerStorage()._maxClaimableFundingShare;
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev create increase/decrease order
    function _createOrder(InternalCreateOrderParams memory params) private returns (bytes32) {
        IExchangeRouter(params.exchangeRouter).sendWnt{value: params.executionFee}(
            params.orderVault, params.executionFee
        );
        address[] memory swapPath;
        bytes32 orderKey = IExchangeRouter(params.exchangeRouter).createOrder(
            IExchangeRouter.CreateOrderParams({
                addresses: IExchangeRouter.CreateOrderParamsAddresses({
                    receiver: params.strategy, // the receiver of reduced collateral
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    market: marketToken(),
                    initialCollateralToken: params.collateralToken,
                    swapPath: swapPath
                }),
                numbers: IExchangeRouter.CreateOrderParamsNumbers({
                    sizeDeltaUsd: params.sizeDeltaInUsd,
                    initialCollateralDeltaAmount: params.collateralDelta, // The amount of tokens to withdraw for decrease orders
                    triggerPrice: 0, // not used for market, swap, liquidation orders
                    acceptablePrice: params.isLong == params.isIncrease ? type(uint256).max : 0, // acceptable index token price
                    executionFee: params.executionFee,
                    callbackGasLimit: params.callbackGasLimit,
                    minOutputAmount: 0
                }),
                orderType: params.isIncrease
                    ? IExchangeRouter.OrderType.MarketIncrease
                    : IExchangeRouter.OrderType.MarketDecrease,
                decreasePositionSwapType: IExchangeRouter.DecreasePositionSwapType.NoSwap,
                isLong: params.isLong,
                shouldUnwrapNativeToken: false,
                referralCode: params.referralCode
            })
        );
        _setPendingOrderKey(orderKey, params.isIncrease);
        return orderKey;
    }

    /// @dev check if the claimable funding fee amount is over than max share
    function _checkSettle() private view returns (bool) {
        address _factory = factory();
        bool isFundingClaimable = GmxV2Lib.isFundingClaimable(
            _getPositionParams(_factory),
            _getPricesParams(_factory),
            IBasisGmxFactory(_factory).referralStorage(),
            maxClaimableFundingShare(),
            PRECISION
        );
        return isFundingClaimable;
    }

    /// @dev check deviation between spot and perp
    /// @return isNeed is for deciding to adjust perp position
    /// @return sizeDeltaInTokens is delta size of perp position to be adjusted
    function _checkAdjustPositionSize() private view returns (bool isNeed, int256 sizeDeltaInTokens) {
        uint256 productBalance = IERC20(indexToken()).balanceOf(strategy());
        uint256 positionSizeInTokens = GmxV2Lib.getPositionSizeInTokens(_getPositionParams(factory()));
        sizeDeltaInTokens = productBalance.toInt256() - positionSizeInTokens.toInt256();
        uint256 deviation;
        if (sizeDeltaInTokens < 0) {
            deviation = uint256(-sizeDeltaInTokens).mulDiv(PRECISION, productBalance);
        } else {
            deviation = uint256(sizeDeltaInTokens).mulDiv(PRECISION, productBalance);
        }
        isNeed = deviation > _getGmxV2PositionManagerStorage()._maxHedgeDeviation;
        return (isNeed, sizeDeltaInTokens);
    }

    function _getPositionParams(address _factory) private view returns (GmxV2Lib.GetPosition memory) {
        return GmxV2Lib.GetPosition({
            dataStore: IBasisGmxFactory(_factory).dataStore(),
            reader: IBasisGmxFactory(_factory).reader(),
            marketToken: marketToken(),
            account: address(this),
            collateralToken: collateralToken(),
            isLong: isLong()
        });
    }

    function _getPricesParams(address _factory) private view returns (GmxV2Lib.GetPrices memory) {
        Market.Props memory market = Market.Props({
            marketToken: marketToken(),
            indexToken: indexToken(),
            longToken: longToken(),
            shortToken: shortToken()
        });
        return GmxV2Lib.GetPrices({market: market, oracle: IBasisGmxFactory(_factory).oracle()});
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // @dev used in modifier which reduces the code size
    function _onlyStrategy() private view {
        if (msg.sender != strategy()) {
            revert Errors.CallerNotStrategy();
        }
    }

    // @dev used in modifier which reduces the code size
    function _onlyKeeper() private view {
        if (msg.sender != keeper()) {
            revert Errors.CallerNotKeeper();
        }
    }

    // @dev used to stop create orders one by on
    function _whenNotPending() private view {
        if (_isPending()) {
            revert Errors.AlreadyPending();
        }
    }

    function _isPending() private view returns (bool) {
        return _getGmxV2PositionManagerStorage()._pendingIncreaseOrderKey != bytes32(0)
            || _getGmxV2PositionManagerStorage()._pendingDecreaseOrderKey != bytes32(0);
    }

    /// @dev validate if the caller is OrderHandler of gmx
    function _validateOrderHandler(bytes32 orderKey) private view {
        if (
            msg.sender != IBasisGmxFactory(factory()).orderHandler()
                || (
                    orderKey != _getGmxV2PositionManagerStorage()._pendingIncreaseOrderKey
                        && orderKey != _getGmxV2PositionManagerStorage()._pendingDecreaseOrderKey
                )
        ) {
            revert Errors.CallbackNotAllowed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE SETTERS
    //////////////////////////////////////////////////////////////*/

    function _setPendingOrderKey(bytes32 orderKey, bool isIncrease) private {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        if (isIncrease) {
            $._pendingIncreaseOrderKey = orderKey;
        } else {
            $._pendingDecreaseOrderKey = orderKey;
        }
    }

    function _recordExecutionCostCalcInfo(GmxV2Lib.GetPosition memory positionParams, uint256 spotExecutionPrice)
        private
    {
        _getGmxV2PositionManagerStorage()._spotExecutionPrice = spotExecutionPrice;
        _getGmxV2PositionManagerStorage()._sizeInTokensBefore = GmxV2Lib.getPositionSizeInTokens(positionParams);
    }

    function _wipeExecutionCostCalcInfo() private {
        _getGmxV2PositionManagerStorage()._spotExecutionPrice = 0;
        _getGmxV2PositionManagerStorage()._sizeInTokensBefore = 0;
        _getGmxV2PositionManagerStorage()._sizeDeltaInUsd = 0;
    }
}
