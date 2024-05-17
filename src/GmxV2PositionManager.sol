// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IOrderCallbackReceiver} from "src/externals/gmx-v2/interfaces/IOrderCallbackReceiver.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {ArbGasInfo} from "src/externals/arbitrum/ArbGasInfo.sol";
import {EventUtils} from "src/externals/gmx-v2/libraries/EventUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Order} from "src/externals/gmx-v2/libraries/Order.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "./Errors.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract must be deployed only by the factory
contract GmxV2PositionManager is IGmxV2PositionManager, UUPSUpgradeable, IOrderCallbackReceiver {
    using SafeERC20 for IERC20;

    string constant API_VERSION = "0.0.1";
    uint256 constant PRECISION = 1e18;

    /// @notice used for processing status
    enum Stages {
        Idle,
        Pending
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager.Config
    struct ConfigStorage {
        address _factory;
        address _strategy;
        address _marketToken;
        address _indexToken;
        address _longToken;
        address _shortToken;
        bytes32 _positionKey;
    }

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager.State
    struct StateStorage {
        Stages _stage;
        uint256 _pendingAssets;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager.Config")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ConfigStorageLocation = 0x51e553f1ed05f39323723017580800f12e204b6a09a61aeb584366ce03172f00;

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager.State")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StateStorageLocation = 0x9a05e65897e43e5729051b7a8b9a904f0ad0efe51cf504c7b850ba952775e500;

    function _getConfigStorage() private pure returns (ConfigStorage storage $) {
        assembly {
            $.slot := ConfigStorageLocation
        }
    }

    function _getStateStorage() private pure returns (StateStorage storage $) {
        assembly {
            $.slot := StateStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    function initialize(address strategy) external initializer {
        address factory = msg.sender;
        address asset = address(IBasisStrategy(strategy).asset());
        address product = address(IBasisStrategy(strategy).product());
        address marketKey = IBasisGmxFactory(factory).marketKey(asset, product);
        if (marketKey == address(0)) {
            revert Errors.InvalidMarket();
        }
        address dataStore = IBasisGmxFactory(factory).dataStore();
        address reader = IBasisGmxFactory(factory).reader();
        Market.Props memory market = IReader(reader).getMarket(dataStore, marketKey);
        if (market.shortToken != asset || market.longToken != product) {
            revert Errors.InvalidInitializationAssets();
        }
        // always short position
        bytes32 positionKey = keccak256(abi.encode(address(this), market.marketToken, market.shortToken, false));

        ConfigStorage storage $ = _getConfigStorage();
        $._factory = factory;
        $._strategy = strategy;
        $._marketToken = market.marketToken;
        $._indexToken = market.indexToken;
        $._longToken = market.longToken;
        $._shortToken = market.shortToken;
        $._positionKey = positionKey;
    }

    function _authorizeUpgrade(address) internal virtual override {
        ConfigStorage storage $ = _getConfigStorage();
        if (msg.sender != $._factory) {
            revert Errors.UnauthoirzedUpgrade();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGmxV2PositionManager
    function apiVersion() external pure override returns (string memory) {
        return API_VERSION;
    }

    /// @inheritdoc IGmxV2PositionManager
    function increasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd)
        external
        payable
        override
        onlyStrategy
        returns (bytes32)
    {
        return _adjust(collateralDelta, sizeDeltaInUsd, true);
    }

    /// @inheritdoc IGmxV2PositionManager
    function decreasePosition(uint256 collateralDelta, uint256 sizeDeltaInUsd)
        external
        payable
        override
        onlyStrategy
        returns (bytes32)
    {
        return _adjust(collateralDelta, sizeDeltaInUsd, false);
    }

    /// @inheritdoc IGmxV2PositionManager
    function claim() external override {}

    /// @inheritdoc IGmxV2PositionManager
    function totalAssets() external view override returns (uint256) {}

    /// @notice calculate the execution fee that is need from gmx when increase and decrease
    ///
    /// @return feeIncrease the execution fee for increase
    /// @return feeDecrease the execution fee for decrease
    function getExecutionFee() external view returns (uint256 feeIncrease, uint256 feeDecrease) {
        IBasisGmxFactory factory = _factory();
        IDataStore dataStore = IDataStore(factory.dataStore());
        uint256 callbackGasLimit = factory.callbackGasLimit();
        uint256 estimatedGasLimitIncrease = dataStore.getUint(Keys.increaseOrderGasLimitKey());
        uint256 estimatedGasLimitDecrease = dataStore.getUint(Keys.decreaseOrderGasLimitKey());
        estimatedGasLimitIncrease += callbackGasLimit;
        estimatedGasLimitDecrease += callbackGasLimit;
        uint256 baseGasLimit = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimitIncrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitIncrease, multiplierFactor);
        uint256 gasLimitDecrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitDecrease, multiplierFactor);
        uint256 gasPrice = tx.gasprice;
        if (gasPrice == 0) {
            gasPrice = ArbGasInfo(0x000000000000000000000000000000000000006C).getMinimumGasPrice();
        }
        return (gasPrice * gasLimitIncrease, gasPrice * gasLimitDecrease);
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderExecution(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory eventData)
        external
        override
    {
        _validateOrderHandler();
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderCancellation(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory eventData)
        external
        override
    {
        _validateOrderHandler();
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderFrozen(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory eventData)
        external
        override
    {
        revert(); // fronzen is not supported for market increase/decrease orders
    }

    
    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev create increase/decrease order
    function _adjust(uint256 collateralDelta, uint256 sizeDeltaInUsd, bool isIncrease) private returns (bytes32) {
        uint256 executionFee = msg.value;
        address orderVault = _factory().orderVault();
        address exchangeRouter = _factory().exchangeRouter();
        IExchangeRouter(exchangeRouter).sendWnt{value: executionFee}(orderVault, executionFee);

        address[] memory swapPath;
        IExchangeRouter.CreateOrderParamsAddresses memory paramsAddresses = IExchangeRouter.CreateOrderParamsAddresses({
            receiver: _strategyAddr(), // the receiver of reduced collateral
            callbackContract: address(this),
            uiFeeReceiver: address(0),
            market: _marketTokenAddr(),
            initialCollateralToken: address(_collateralToken()),
            swapPath: swapPath
        });

        IExchangeRouter.CreateOrderParamsNumbers memory paramsNumbers;
        IExchangeRouter.OrderType orderType;
        if (isIncrease) {
            if (collateralDelta > 0) {
                _collateralToken().safeTransferFrom(_strategyAddr(), orderVault, collateralDelta);
            }
            paramsNumbers = IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaInUsd,
                initialCollateralDeltaAmount: 0, // The amount of tokens to withdraw for decrease orders
                triggerPrice: 0, // not used for market, swap, liquidation orders
                acceptablePrice: 0, // acceptable index token price
                executionFee: executionFee,
                callbackGasLimit: _factory().callbackGasLimit(),
                minOutputAmount: 0
            });
            orderType = IExchangeRouter.OrderType.MarketIncrease;
        } else {
            paramsNumbers = IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaInUsd,
                initialCollateralDeltaAmount: collateralDelta, // The amount of tokens to withdraw for decrease orders
                triggerPrice: 0, // not used for market, swap, liquidation orders
                acceptablePrice: type(uint256).max, // acceptable index token price
                executionFee: executionFee,
                callbackGasLimit: _factory().callbackGasLimit(),
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
            isLong: false,
            shouldUnwrapNativeToken: false,
            referralCode: _factory().referralCode()
        });
        return IExchangeRouter(exchangeRouter).createOrder(orderParams);
    }

    // this is used in modifier which reduces the code size
    function _onlyStrategy() private view {
        if (msg.sender != _strategyAddr()) {
            revert Errors.CallerNotStrategy();
        }
    }

    function _factory() private view returns (IBasisGmxFactory) {
        ConfigStorage storage $ = _getConfigStorage();
        return IBasisGmxFactory($._factory);
    }

    function _collateralToken() private view returns (IERC20) {
        ConfigStorage storage $ = _getConfigStorage();
        return IERC20($._shortToken);
    }

    function _strategyAddr() private view returns (address) {
        ConfigStorage storage $ = _getConfigStorage();
        return $._strategy;
    }

    function _marketTokenAddr() private view returns (address) {
        ConfigStorage storage $ = _getConfigStorage();
        return $._marketToken;
    }

    /// @dev validate if the caller is OrderHandler of gmx
    function _validateOrderHandler() private view {
        if (msg.sender != _factory().orderHandler()) {
            revert Errors.CallerNotOrderHandler();
        }
    }
}
