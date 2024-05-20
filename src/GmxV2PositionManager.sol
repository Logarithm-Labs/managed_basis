// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

import {Errors} from "src/libraries/Errors.sol";

import {FactoryDeployable} from "./FactoryDeployable.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract must be deployed only by the factory
contract GmxV2PositionManager is FactoryDeployable, IGmxV2PositionManager, IOrderCallbackReceiver {
    using SafeERC20 for IERC20;

    string constant API_VERSION = "0.0.1";
    uint256 constant PRECISION = 1e18;

    /// @notice used for processing status
    enum Stages {
        Idle,
        Pending
    }

    struct InternalClaimFundingParams {
        IDataStore dataStore;
        IExchangeRouter exchangeRouter;
        address marketToken;
        address longToken;
        address shortToken;
        address receiver;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager
    struct GmxV2PositionManagerStorage {
        address _strategy;
        address _marketToken;
        address _indexToken;
        address _longToken;
        address _shortToken;
        bytes32 _positionKey;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxV2PositionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GmxV2PositionManagerStorageLocation = 0xf08705b56fbd504746312a6db5deff16fc51a9c005f5e6a881519498d59a9600;

    function _getGmxV2PositionManagerStorage() private pure returns (GmxV2PositionManagerStorage storage $) {
        assembly {
            $.slot := GmxV2PositionManagerStorageLocation
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
        __FactoryDeployable_init();
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

        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        $._strategy = strategy;
        $._marketToken = market.marketToken;
        $._indexToken = market.indexToken;
        $._longToken = market.longToken;
        $._shortToken = market.shortToken;
        $._positionKey = positionKey;
    }

    function _authorizeUpgrade(address) internal virtual override onlyFactory {}

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
    function claim() external override {
        IBasisGmxFactory factory = IBasisGmxFactory(_factory());
        IDataStore dataStore = IDataStore(factory.dataStore());
        IExchangeRouter exchangeRouter = IExchangeRouter(factory.exchangeRouter());

        _claimFunding(
            InternalClaimFundingParams({
                dataStore: dataStore,
                exchangeRouter: exchangeRouter,
                marketToken: _marketTokenAddr(),
                shortToken: _shortTokenAddr(),
                longToken: _longTokenAddr(),
                receiver: _strategyAddr()
            })
        );
        _claimCollateral();
    }

    /// @inheritdoc IGmxV2PositionManager
    function totalAssets() external view override returns (uint256) {}

    /// @notice calculate the execution fee that is need from gmx when increase and decrease
    ///
    /// @return feeIncrease the execution fee for increase
    /// @return feeDecrease the execution fee for decrease
    function getExecutionFee() external view returns (uint256 feeIncrease, uint256 feeDecrease) {
        IBasisGmxFactory factory = IBasisGmxFactory(_factory());
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
        pure
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
        IBasisGmxFactory factory = IBasisGmxFactory(_factory());
        address orderVaultAddr = factory.orderVault();
        address exchangeRouterAddr = factory.exchangeRouter();
        IERC20 collateralToken = _collateralToken();

        IExchangeRouter(exchangeRouterAddr).sendWnt{value: executionFee}(orderVaultAddr, executionFee);

        address strategyAddr = _strategyAddr();
        address[] memory swapPath;
        IExchangeRouter.CreateOrderParamsAddresses memory paramsAddresses = IExchangeRouter.CreateOrderParamsAddresses({
            receiver: strategyAddr, // the receiver of reduced collateral
            callbackContract: address(this),
            uiFeeReceiver: address(0),
            market: _marketTokenAddr(),
            initialCollateralToken: address(collateralToken),
            swapPath: swapPath
        });

        IExchangeRouter.CreateOrderParamsNumbers memory paramsNumbers;
        IExchangeRouter.OrderType orderType;
        if (isIncrease) {
            if (collateralDelta > 0) {
                collateralToken.safeTransferFrom(strategyAddr, orderVaultAddr, collateralDelta);
            }
            paramsNumbers = IExchangeRouter.CreateOrderParamsNumbers({
                sizeDeltaUsd: sizeDeltaInUsd,
                initialCollateralDeltaAmount: 0, // The amount of tokens to withdraw for decrease orders
                triggerPrice: 0, // not used for market, swap, liquidation orders
                acceptablePrice: 0, // acceptable index token price
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
                acceptablePrice: type(uint256).max, // acceptable index token price
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
            isLong: false,
            shouldUnwrapNativeToken: false,
            referralCode: factory.referralCode()
        });
        return IExchangeRouter(exchangeRouterAddr).createOrder(orderParams);
    }

    function _claimFunding(InternalClaimFundingParams memory params) private {
        bytes32 key = Keys.claimableFundingAmountKey(params.marketToken, params.shortToken, address(this));
        uint256 shortTokenAmount = params.dataStore.getUint(key);
        key = Keys.claimableFundingAmountKey(params.marketToken, params.longToken, address(this));
        uint256 longTokenAmount = params.dataStore.getUint(key);

        if (shortTokenAmount > 0 || longTokenAmount > 0) {
            address[] memory markets = new address[](2);
            markets[0] = params.marketToken;
            markets[1] = params.marketToken;
            address[] memory tokens = new address[](2);
            tokens[0] = params.shortToken;
            tokens[1] = params.longToken;

            uint256[] memory amounts =
                IExchangeRouter(params.exchangeRouter).claimFundingFees(markets, tokens, params.receiver);

            (uint256 shortTokenClaimed, uint256 longTokenClaimed) = (amounts[0], amounts[1]);
        }
    }

    function _claimCollateral() private {}

    /*//////////////////////////////////////////////////////////////
                        VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // this is used in modifier which reduces the code size
    function _onlyStrategy() private view {
        if (msg.sender != _strategyAddr()) {
            revert Errors.CallerNotStrategy();
        }
    }

    /// @dev validate if the caller is OrderHandler of gmx
    function _validateOrderHandler() private view {
        if (msg.sender != IBasisGmxFactory(_factory()).orderHandler()) {
            revert Errors.CallerNotOrderHandler();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _collateralToken() private view returns (IERC20) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return IERC20($._shortToken);
    }

    function _strategyAddr() private view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._strategy;
    }

    function _marketTokenAddr() private view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._marketToken;
    }

    function _longTokenAddr() private view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._longToken;
    }

    function _shortTokenAddr() private view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $._shortToken;
    }
}
