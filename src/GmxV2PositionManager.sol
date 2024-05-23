// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IOrderCallbackReceiver} from "src/externals/gmx-v2/interfaces/IOrderCallbackReceiver.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {EventUtils} from "src/externals/gmx-v2/libraries/EventUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Order} from "src/externals/gmx-v2/libraries/Order.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "src/libraries/Errors.sol";
import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";

import {FactoryDeployable} from "src/common/FactoryDeployable.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract must be deployed only by the factory
contract GmxV2PositionManager is FactoryDeployable, IGmxV2PositionManager, IOrderCallbackReceiver {
    using SafeERC20 for IERC20;

    string constant API_VERSION = "0.0.1";

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager
    struct GmxV2PositionManagerStorage {
        // configuration
        address _strategy;
        address _marketToken;
        address _indexToken;
        address _longToken;
        address _shortToken;
        address _collateralToken;
        bool _isLong;
        // state
        bytes32 _pendingOrderKey;
        uint256 _pendingAssets;
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
    event OrderCreated(
        bytes32 indexed orderKey, uint256 indexed collateralDelta, uint256 indexed sizeDeltaInUsd, bool isIncrease
    );
    event OrderExecuted(bytes32 indexed orderKey);
    event OrderFailed(bytes32 indexed orderKey);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address strategy_) external initializer {
        __FactoryDeployable_init();
        address factory = msg.sender;
        address asset = address(IBasisStrategy(strategy_).asset());
        address product = address(IBasisStrategy(strategy_).product());
        address marketKey = IBasisGmxFactory(factory).marketKey(asset, product);
        if (marketKey == address(0)) {
            revert Errors.InvalidMarket();
        }
        address dataStore = IBasisGmxFactory(factory).dataStore();
        address reader = IBasisGmxFactory(factory).reader();
        Market.Props memory market = IReader(reader).getMarket(dataStore, marketKey);
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
    }

    function _authorizeUpgrade(address) internal virtual override onlyFactory {}

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}

    /// @inheritdoc IGmxV2PositionManager
    function increasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd) external payable override onlyStrategy {
        _createOrder(collateralDelta, sizeDeltaInUsd, true);
    }

    /// @inheritdoc IGmxV2PositionManager
    function decreasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd) external payable override onlyStrategy {
        _createOrder(collateralDelta, sizeDeltaInUsd, false);
    }

    /// @inheritdoc IGmxV2PositionManager
    function claimFunding() external override {
        IBasisGmxFactory factory = IBasisGmxFactory(factory());
        IExchangeRouter exchangeRouter = IExchangeRouter(factory.exchangeRouter());
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

    /// @inheritdoc IGmxV2PositionManager
    function claimCollateral(address token, uint256 timeKey) external override {
        IBasisGmxFactory factory = IBasisGmxFactory(factory());
        IExchangeRouter exchangeRouter = IExchangeRouter(factory.exchangeRouter());

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
    function afterOrderExecution(
        bytes32 key,
        Order.Props memory, /* order */
        EventUtils.EventLogData memory /* eventData */
    ) external override {
        _validateOrderHandler(key);
        _setPendingOrderKey(bytes32(0));
        _setPendingAssets(0);
        emit OrderExecuted(key);
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderCancellation(
        bytes32 key,
        Order.Props memory order,
        EventUtils.EventLogData memory /* eventData */
    ) external override {
        _validateOrderHandler(key);
        _setPendingOrderKey(bytes32(0));
        address collateralTokenAddr = order.addresses.initialCollateralToken;
        uint256 pendingAssetsAmount = pendingAssets();
        _setPendingAssets(0);
        assert(IERC20(collateralTokenAddr).balanceOf(address(this)) == pendingAssetsAmount);
        IERC20(collateralTokenAddr).safeTransfer(strategy(), pendingAssetsAmount);
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

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL/PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGmxV2PositionManager
    function apiVersion() public pure override returns (string memory) {
        return API_VERSION;
    }

    /// @inheritdoc IGmxV2PositionManager
    function totalAssets() public view override returns (uint256) {
        address factory = factory();
        address _marketToken = marketToken();
        Market.Props memory market = Market.Props({
            marketToken: _marketToken,
            indexToken: indexToken(),
            longToken: longToken(),
            shortToken: shortToken()
        });
        uint256 positionNetAmount = GmxV2Lib.getPositionNetAmount(
            GmxV2Lib.GetPositionNetAmount({
                market: market,
                dataStore: IBasisGmxFactory(factory).dataStore(),
                reader: IBasisGmxFactory(factory).reader(),
                referralStorage: IBasisGmxFactory(factory).referralStorage(),
                positionKey: GmxV2Lib.getPositionKey(address(this), _marketToken, collateralToken(), isLong()),
                oracle: IBasisGmxFactory(factory).oracle()
            })
        );
        return positionNetAmount + pendingAssets();
    }

    // /// @notice calculate the execution fee that is need from gmx when increase and decrease
    // ///
    // /// @return feeIncrease the execution fee for increase
    // /// @return feeDecrease the execution fee for decrease
    // function getExecutionFee() public view returns (uint256 feeIncrease, uint256 feeDecrease) {
    //     IBasisGmxFactory factory = IBasisGmxFactory(factory());
    //     return GmxV2Lib.getExecutionFee(IDataStore(factory.dataStore()), factory.callbackGasLimit());
    // }

    function collateralToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._collateralToken;
    }

    function strategy() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._strategy;
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

    function pendingOrderKey() public view returns (bytes32) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._pendingOrderKey;
    }

    function pendingAssets() public view returns (uint256) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._pendingAssets;
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev create increase/decrease order
    function _createOrder(uint256 collateralDelta, uint256 sizeDeltaInUsd, bool isIncrease) private {
        if (pendingOrderKey() != bytes32(0)) {
            revert Errors.AlreadyPending();
        }
        uint256 executionFee = msg.value;
        IBasisGmxFactory factory = IBasisGmxFactory(factory());
        address orderVaultAddr = factory.orderVault();
        address exchangeRouterAddr = factory.exchangeRouter();
        address collateralTokenAddr = collateralToken();

        IExchangeRouter(exchangeRouterAddr).sendWnt{value: executionFee}(orderVaultAddr, executionFee);

        address strategyAddr = strategy();
        address[] memory swapPath;
        IExchangeRouter.CreateOrderParamsAddresses memory paramsAddresses = IExchangeRouter.CreateOrderParamsAddresses({
            receiver: strategyAddr, // the receiver of reduced collateral
            callbackContract: address(this),
            uiFeeReceiver: address(0),
            market: marketToken(),
            initialCollateralToken: collateralTokenAddr,
            swapPath: swapPath
        });

        bool _isLong = isLong();
        IExchangeRouter.CreateOrderParamsNumbers memory paramsNumbers;
        IExchangeRouter.OrderType orderType;
        if (isIncrease) {
            if (collateralDelta > 0) {
                IERC20(collateralTokenAddr).safeTransferFrom(strategyAddr, orderVaultAddr, collateralDelta);
                _setPendingAssets(collateralDelta);
            }
            paramsNumbers = IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaInUsd,
                initialCollateralDeltaAmount: 0, // The amount of tokens to withdraw for decrease orders
                triggerPrice: 0, // not used for market, swap, liquidation orders
                acceptablePrice: _isLong ? type(uint256).max : 0, // acceptable index token price
                executionFee: executionFee,
                callbackGasLimit: factory.callbackGasLimit(),
                minOutputAmount: 0
            });
            orderType = IExchangeRouter.OrderType.MarketIncrease;
        } else {
            paramsNumbers = IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaInUsd,
                initialCollateralDeltaAmount: collateralDelta, // The amount of tokens to withdraw for decrease orders
                triggerPrice: 0, // not used for market, swap, liquidation orders
                acceptablePrice: _isLong ? 0 : type(uint256).max, // acceptable index token price
                executionFee: executionFee,
                callbackGasLimit: factory.callbackGasLimit(),
                minOutputAmount: 0
            });
            orderType = IExchangeRouter.OrderType.MarketDecrease;
        }
        IExchangeRouter.DecreasePositionSwapType swapType = IExchangeRouter.DecreasePositionSwapType.NoSwap;
        IExchangeRouter.CreateOrderParams memory orderParams = IExchangeRouter.CreateOrderParams({
            addresses: paramsAddresses,
            numbers: paramsNumbers,
            orderType: orderType,
            decreasePositionSwapType: swapType,
            isLong: _isLong,
            shouldUnwrapNativeToken: false,
            referralCode: factory.referralCode()
        });

        bytes32 orderKey = IExchangeRouter(exchangeRouterAddr).createOrder(orderParams);

        _setPendingOrderKey(orderKey);

        emit OrderCreated(orderKey, collateralDelta, sizeDeltaInUsd, isIncrease);
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // this is used in modifier which reduces the code size
    function _onlyStrategy() private view {
        if (msg.sender != strategy()) {
            revert Errors.CallerNotStrategy();
        }
    }

    /// @dev validate if the caller is OrderHandler of gmx
    function _validateOrderHandler(bytes32 orderKey) private view {
        if (msg.sender != IBasisGmxFactory(factory()).orderHandler() || orderKey != pendingOrderKey()) {
            revert Errors.CallbackNotAllowed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE SETTERS
    //////////////////////////////////////////////////////////////*/

    function _setPendingOrderKey(bytes32 orderKey) private {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        $._pendingOrderKey = orderKey;
    }

    function _setPendingAssets(uint256 assets) private {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        $._pendingAssets = assets;
    }
}
