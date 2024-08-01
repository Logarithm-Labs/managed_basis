// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IBaseOrderUtils} from "src/externals/gmx-v2/interfaces/IBaseOrderUtils.sol";
import {IOrderCallbackReceiver} from "src/externals/gmx-v2/interfaces/IOrderCallbackReceiver.sol";
import {IGasFeeCallbackReceiver} from "src/externals/gmx-v2/interfaces/IGasFeeCallbackReceiver.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {EventUtils} from "src/externals/gmx-v2/libraries/EventUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Order} from "src/externals/gmx-v2/libraries/Order.sol";

import {IManagedBasisStrategy} from "src/interfaces/IManagedBasisStrategy.sol";
import {IConfig} from "src/interfaces/IConfig.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IKeeper} from "src/interfaces/IKeeper.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";

import {ConfigKeys} from "src/libraries/ConfigKeys.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
contract GmxV2PositionManager is
    IPositionManager,
    IOrderCallbackReceiver,
    IGasFeeCallbackReceiver,
    Initializable,
    OwnableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 constant PRECISION = 1e18;
    uint256 constant MIN_IDLE_COLLATERAL_USD = 1e31; // $10
    string constant API_VERSION = "0.0.1";

    enum Status {
        IDLE,
        INCREASE,
        DECREASE_ONE_STEP,
        DECREASE_TWO_STEP,
        SETTLE
    }

    struct InternalCreateOrderParams {
        bool isLong;
        bool isIncrease;
        address exchangeRouter;
        address orderVault;
        address collateralToken;
        uint256 collateralDeltaAmount;
        uint256 sizeDeltaUsd;
        uint256 callbackGasLimit;
        bytes32 referralCode;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxV2PositionManager
    struct GmxV2PositionManagerStorage {
        // configuration
        address config;
        address strategy;
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
        address collateralToken;
        bool isLong;
        uint256 maxClaimableFundingShare;
        // state
        Status status;
        // bytes32 activeRequestId;
        bytes32 pendingIncreaseOrderKey;
        bytes32 pendingDecreaseOrderKey;
        uint256 pendingCollateralAmount;
        // this value is set only when changing position sizes
        uint256 sizeInTokensBefore;
        uint256 decreasingCollateralDeltaAmount;
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

    function initialize(address owner_, address strategy_, address config_) external initializer {
        __Ownable_init(owner_);
        address asset = address(IManagedBasisStrategy(strategy_).asset());
        address product = address(IManagedBasisStrategy(strategy_).product());
        address marketKey = IConfig(config_).getAddress(ConfigKeys.gmxMarketKey(asset, product));
        if (marketKey == address(0)) {
            revert Errors.InvalidMarket();
        }
        address dataStore = IConfig(config_).getAddress(ConfigKeys.GMX_DATA_STORE);
        address reader = IConfig(config_).getAddress(ConfigKeys.GMX_READER);
        Market.Props memory market = IReader(reader).getMarket(dataStore, marketKey);
        // assuming short position open
        if ((market.longToken != asset && market.shortToken != asset) || (market.indexToken != product)) {
            revert Errors.InvalidInitializationAssets();
        }
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        $.config = config_;
        $.strategy = strategy_;
        $.marketToken = market.marketToken;
        $.indexToken = market.indexToken;
        $.longToken = market.longToken;
        $.shortToken = market.shortToken;
        $.collateralToken = asset;
        $.isLong = false;

        $.maxClaimableFundingShare = 1e16; // 1%

        // approve strategy to max amount
        IERC20(asset).approve($.strategy, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function renounceOwnership() public pure override {
        revert();
    }

    function setMaxClaimableFundingShare(uint256 _maxClaimableFundingShare) external onlyOwner {
        require(_maxClaimableFundingShare < 1 ether);
        _getGmxV2PositionManagerStorage().maxClaimableFundingShare = _maxClaimableFundingShare;
    }

    function adjustPosition(DataTypes.PositionManagerPayload calldata params) external onlyStrategy whenNotPending {
        if (params.sizeDeltaInTokens == 0 && params.collateralDeltaAmount == 0) {
            revert Errors.InvalidAdjustmentParams();
        }
        address _config = config();
        GmxV2Lib.GmxParams memory gmxParams = _getGmxParams(_config);
        address _oracle = IConfig(_config).getAddress(ConfigKeys.ORACLE);
        address _collateralToken = collateralToken();
        uint256 idleCollateralAmount = IERC20(_collateralToken).balanceOf(address(this));
        if (params.isIncrease) {
            if (params.collateralDeltaAmount > idleCollateralAmount) {
                revert Errors.NotEnoughCollateral();
            }
            if (idleCollateralAmount > 0) {
                IERC20(_collateralToken).safeTransfer(
                    IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT), idleCollateralAmount
                );
            }
            uint256 sizeDeltaUsd;
            if (params.sizeDeltaInTokens > 0) {
                // record sizeInTokens
                _getGmxV2PositionManagerStorage().sizeInTokensBefore = GmxV2Lib.getPositionSizeInTokens(gmxParams);
                sizeDeltaUsd = GmxV2Lib.getSizeDeltaUsdForIncrease(gmxParams, _oracle, params.sizeDeltaInTokens);
            }
            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: true,
                    exchangeRouter: IConfig(_config).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER),
                    orderVault: IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT),
                    collateralToken: _collateralToken,
                    collateralDeltaAmount: idleCollateralAmount,
                    sizeDeltaUsd: sizeDeltaUsd,
                    callbackGasLimit: IConfig(_config).getUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT),
                    referralCode: IConfig(_config).getBytes32(ConfigKeys.GMX_REFERRAL_CODE)
                })
            );
            _getGmxV2PositionManagerStorage().status = Status.INCREASE;
        } else {
            if (params.sizeDeltaInTokens == 0 && params.collateralDeltaAmount <= idleCollateralAmount) {
                IManagedBasisStrategy(strategy()).afterAdjustPosition(
                    DataTypes.PositionManagerPayload({
                        sizeDeltaInTokens: 0,
                        collateralDeltaAmount: params.collateralDeltaAmount,
                        isIncrease: false
                    })
                );
            } else {
                uint256 collateralDeltaAmount = params.collateralDeltaAmount;
                if (collateralDeltaAmount > 0) {
                    _getGmxV2PositionManagerStorage().decreasingCollateralDeltaAmount = collateralDeltaAmount;
                }
                if (idleCollateralAmount > 0) {
                    (, collateralDeltaAmount) = params.collateralDeltaAmount.trySub(idleCollateralAmount);
                }
                GmxV2Lib.DecreasePositionResult memory decreaseResult = GmxV2Lib.getDecreasePositionResult(
                    gmxParams, _oracle, params.sizeDeltaInTokens, collateralDeltaAmount
                );
                if (params.sizeDeltaInTokens > 0) {
                    _getGmxV2PositionManagerStorage().sizeInTokensBefore = GmxV2Lib.getPositionSizeInTokens(gmxParams);
                }
                _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: false,
                        exchangeRouter: IConfig(_config).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER),
                        orderVault: IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT),
                        collateralToken: _collateralToken,
                        collateralDeltaAmount: !decreaseResult.isIncreaseCollateral
                            ? decreaseResult.initialCollateralDeltaAmount
                            : 0,
                        sizeDeltaUsd: decreaseResult.sizeDeltaUsdToDecrease,
                        callbackGasLimit: IConfig(_config).getUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT),
                        referralCode: IConfig(_config).getBytes32(ConfigKeys.GMX_REFERRAL_CODE)
                    })
                );
                if (decreaseResult.sizeDeltaUsdToIncrease > 0) {
                    _getGmxV2PositionManagerStorage().status = Status.DECREASE_TWO_STEP;
                    _createOrder(
                        InternalCreateOrderParams({
                            isLong: isLong(),
                            isIncrease: true,
                            exchangeRouter: IConfig(_config).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER),
                            orderVault: IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT),
                            collateralToken: _collateralToken,
                            collateralDeltaAmount: 0,
                            sizeDeltaUsd: decreaseResult.sizeDeltaUsdToIncrease,
                            callbackGasLimit: IConfig(_config).getUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT),
                            referralCode: IConfig(_config).getBytes32(ConfigKeys.GMX_REFERRAL_CODE)
                        })
                    );
                } else {
                    _getGmxV2PositionManagerStorage().status = Status.DECREASE_ONE_STEP;
                }
            }
        }
    }

    /// @notice keep position to claim funding and increase collateral if there are idle assets
    function keep() external onlyStrategy whenNotPending {
        _getGmxV2PositionManagerStorage().status = Status.SETTLE;
        // if there is idle collateral, then increase that amount to settle the claimable funding
        // otherwise, decrease collateral by 1 to settle
        address _collateralToken = collateralToken();
        address _config = config();
        uint256 idleCollateralAmount = IERC20(_collateralToken).balanceOf(address(this));
        if (idleCollateralAmount > 0) {
            IERC20(_collateralToken).safeTransfer(
                IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT), idleCollateralAmount
            );
            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: true,
                    exchangeRouter: IConfig(_config).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER),
                    orderVault: IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT),
                    collateralToken: _collateralToken,
                    collateralDeltaAmount: idleCollateralAmount,
                    sizeDeltaUsd: 0,
                    callbackGasLimit: IConfig(_config).getUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT),
                    referralCode: IConfig(_config).getBytes32(ConfigKeys.GMX_REFERRAL_CODE)
                })
            );
        } else {
            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: false,
                    exchangeRouter: IConfig(_config).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER),
                    orderVault: IConfig(_config).getAddress(ConfigKeys.GMX_ORDER_VAULT),
                    collateralToken: _collateralToken,
                    collateralDeltaAmount: 1,
                    sizeDeltaUsd: 0,
                    callbackGasLimit: IConfig(_config).getUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT),
                    referralCode: IConfig(_config).getBytes32(ConfigKeys.GMX_REFERRAL_CODE)
                })
            );
        }
    }

    /// @dev claims all the claimable funding fee
    /// this is callable by anyone
    /// Note: collateral funding amount is transfered to this position manager
    ///       otherwise, transfered to strategy
    function claimFunding() public {
        IExchangeRouter exchangeRouter = IExchangeRouter(IConfig(config()).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER));
        address _shortToken = shortToken();
        address _longToken = longToken();
        address _collateralToken = collateralToken();

        address[] memory markets = new address[](1);
        markets[0] = marketToken();
        address[] memory tokens = new address[](1);

        uint256 shortTokenAmount;
        uint256 longTokenAmount;

        tokens[0] = _shortToken;
        if (_shortToken == _collateralToken) {
            uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, address(this));
            shortTokenAmount = amounts[0];
        } else {
            uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, strategy());
            shortTokenAmount = amounts[0];
        }

        tokens[0] = _longToken;
        if (_longToken == _collateralToken) {
            uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, address(this));
            shortTokenAmount = amounts[0];
        } else {
            uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, strategy());
            shortTokenAmount = amounts[0];
        }

        emit FundingClaimed(_shortToken, shortTokenAmount);
        emit FundingClaimed(_longToken, longTokenAmount);
    }

    /// @dev claims all the claimable callateral amount
    /// Note: this amount stored by account, token, timeKey
    /// and there is only event to figure out it
    /// @param token token address derived from the gmx event: ClaimableCollateralUpdated
    /// @param timeKey timeKey value derived from the gmx event: ClaimableCollateralUpdated
    function claimCollateral(address token, uint256 timeKey) external {
        IExchangeRouter exchangeRouter = IExchangeRouter(IConfig(config()).getAddress(ConfigKeys.GMX_EXCHANGE_ROUTER));
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
        Order.Props calldata order,
        EventUtils.EventLogData calldata /*eventData*/
    ) external override {
        bool isIncrease = order.numbers.orderType == Order.OrderType.MarketIncrease;
        _validateOrderHandler(key, isIncrease);
        _setPendingOrderKey(bytes32(0), isIncrease);

        Status _status = _getGmxV2PositionManagerStorage().status;

        if (_status == Status.SETTLE) {
            if (order.numbers.initialCollateralDeltaAmount > 0) {
                _getGmxV2PositionManagerStorage().pendingCollateralAmount = 0;
            }
            _getGmxV2PositionManagerStorage().status = Status.IDLE;
            // notify strategy that keeping has been done
            IManagedBasisStrategy(strategy()).afterAdjustPosition(
                DataTypes.PositionManagerPayload({
                    sizeDeltaInTokens: 0,
                    collateralDeltaAmount: 0,
                    isIncrease: isIncrease
                })
            );
            claimFunding();
        } else if (_status == Status.INCREASE) {
            _processIncreasePosition(order.numbers.initialCollateralDeltaAmount, order.numbers.sizeDeltaUsd);
            _getGmxV2PositionManagerStorage().status = Status.IDLE;
        } else if (_status == Status.DECREASE_ONE_STEP) {
            _processDecreasePosition();
            _getGmxV2PositionManagerStorage().status = Status.IDLE;
        } else if (_status == Status.DECREASE_TWO_STEP) {
            _getGmxV2PositionManagerStorage().status = Status.DECREASE_ONE_STEP;
        }
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderCancellation(
        bytes32 key,
        Order.Props calldata order,
        EventUtils.EventLogData calldata /* eventData */
    ) external override {
        bool isIncrease = order.numbers.orderType == Order.OrderType.MarketIncrease;
        _validateOrderHandler(key, isIncrease);
        _setPendingOrderKey(bytes32(0), isIncrease);

        Status _status = _getGmxV2PositionManagerStorage().status;
        if (_status == Status.IDLE) return;
        if (_status == Status.INCREASE) {
            // in the case when increase order was failed
            IManagedBasisStrategy(strategy()).afterAdjustPosition(
                DataTypes.PositionManagerPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: true})
            );
        } else if (_status == Status.DECREASE_ONE_STEP || _status == Status.DECREASE_TWO_STEP) {
            // in case when the first order was executed successfully or one step decrease order was failed
            // or in case when the order executed in wrong order by gmx was failed
            _getGmxV2PositionManagerStorage().sizeInTokensBefore = 0;
            IManagedBasisStrategy(strategy()).afterAdjustPosition(
                DataTypes.PositionManagerPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: false})
            );
        }
        _getGmxV2PositionManagerStorage().status = Status.IDLE;
    }

    /// @inheritdoc IOrderCallbackReceiver
    function afterOrderFrozen(
        bytes32, /* key */
        Order.Props memory, /* order */
        EventUtils.EventLogData memory /* eventData */
    ) external pure override {
        revert(); // fronzen is not supported for market increase/decrease orders
    }

    /// @inheritdoc IGasFeeCallbackReceiver
    function refundExecutionFee(bytes32, /* key */ EventUtils.EventLogData memory /* eventData */ ) external payable {
        (bool success,) = keeper().call{value: msg.value}("");
        assert(success);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL/PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Used to track the deployed version of this contract. In practice you
    /// can use this version number to compare with Logarithm's GitHub and
    /// determine which version of the source matches this deployed contract
    ///
    /// @dev
    /// All contracts must have an `apiVersion()` that matches the Vault's
    /// `API_VERSION`.
    function apiVersion() public pure returns (string memory) {
        return API_VERSION;
    }

    /// @notice total asset token amount that position holds
    /// Note: should exclude the claimable funding amounts until claiming them
    ///       and include the pending asset token amount and idle assets
    function positionNetBalance() public view returns (uint256) {
        address _config = config();
        (uint256 remainingCollateral,) = GmxV2Lib.getRemainingCollateralAndClaimableFundingAmount(
            _getGmxParams(_config),
            IConfig(_config).getAddress(ConfigKeys.ORACLE),
            IConfig(_config).getAddress(ConfigKeys.GMX_REFERRAL_STORAGE)
        );

        return remainingCollateral + IERC20(collateralToken()).balanceOf(address(this))
            + _getGmxV2PositionManagerStorage().pendingCollateralAmount;
    }

    /// @notice current leverage of position that is based on gmx's calculation
    function currentLeverage() external view returns (uint256) {
        address _config = config();
        return GmxV2Lib.getCurrentLeverage(
            _getGmxParams(_config),
            IConfig(_config).getAddress(ConfigKeys.ORACLE),
            IConfig(_config).getAddress(ConfigKeys.GMX_REFERRAL_STORAGE)
        );
    }

    /// @notice position size in index token
    function positionSizeInTokens() external view returns (uint256) {
        return GmxV2Lib.getPositionSizeInTokens(_getGmxParams(config()));
    }

    /// @notice calculate the execution fee that is need from gmx when increase and decrease
    ///
    /// @return feeIncrease the execution fee for increase
    /// @return feeDecrease the execution fee for decrease
    function getExecutionFee() public view returns (uint256 feeIncrease, uint256 feeDecrease) {
        address _config = config();
        return GmxV2Lib.getExecutionFee(IConfig(_config).getAddress(ConfigKeys.GMX_DATA_STORE));
    }

    function getClaimableFundingAmounts()
        external
        view
        returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount)
    {
        address _config = config();
        (claimableLongTokenAmount, claimableShortTokenAmount) = GmxV2Lib.getClaimableFundingAmounts(
            _getGmxParams(_config),
            IConfig(_config).getAddress(ConfigKeys.ORACLE),
            IConfig(_config).getAddress(ConfigKeys.GMX_REFERRAL_STORAGE)
        );
        return (claimableLongTokenAmount, claimableShortTokenAmount);
    }

    /// @dev check if the claimable funding amount is over than max share
    ///      or if idle collateral is bigger than minimum requriement so that
    ///      the position can be settled to add it to position's collateral
    function needKeep() external view returns (bool) {
        address _config = config();
        address _collateralToken = collateralToken();
        address oralcle = IConfig(_config).getAddress(ConfigKeys.ORACLE);
        uint256 idleCollateralAmount = IERC20(_collateralToken).balanceOf(address(this));
        uint256 idleCollateralAmountUsd = IOracle(oralcle).getAssetPrice(_collateralToken) * idleCollateralAmount;
        if (idleCollateralAmountUsd > MIN_IDLE_COLLATERAL_USD) {
            return true;
        }
        (uint256 remainingCollateral, uint256 claimableTokenAmount) = GmxV2Lib
            .getRemainingCollateralAndClaimableFundingAmount(
            _getGmxParams(_config), oralcle, IConfig(_config).getAddress(ConfigKeys.GMX_REFERRAL_STORAGE)
        );
        if (remainingCollateral > 0) {
            return claimableTokenAmount.mulDiv(PRECISION, remainingCollateral) > maxClaimableFundingShare();
        } else {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev create increase/decrease order
    function _createOrder(InternalCreateOrderParams memory params) private returns (bytes32) {
        if (params.isIncrease && params.collateralDeltaAmount > 0) {
            _getGmxV2PositionManagerStorage().pendingCollateralAmount = params.collateralDeltaAmount;
        }
        (uint256 increaseExecutionFee, uint256 decreaseExecutionFee) = getExecutionFee();
        uint256 executionFee = params.isIncrease ? increaseExecutionFee : decreaseExecutionFee;
        IKeeper(keeper()).payGmxExecutionFee(params.exchangeRouter, params.orderVault, executionFee);
        address[] memory swapPath;
        bytes32 orderKey = IExchangeRouter(params.exchangeRouter).createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this), // the receiver of reduced collateral
                    cancellationReceiver: address(0),
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    market: marketToken(),
                    initialCollateralToken: params.collateralToken,
                    swapPath: swapPath
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: params.sizeDeltaUsd,
                    initialCollateralDeltaAmount: params.collateralDeltaAmount, // The amount of tokens to withdraw for decrease orders
                    triggerPrice: 0, // not used for market, swap, liquidation orders
                    acceptablePrice: params.isLong == params.isIncrease ? type(uint256).max : 0, // acceptable index token price
                    executionFee: executionFee,
                    callbackGasLimit: params.callbackGasLimit,
                    minOutputAmount: 0
                }),
                orderType: params.isIncrease ? Order.OrderType.MarketIncrease : Order.OrderType.MarketDecrease,
                decreasePositionSwapType: Order.DecreasePositionSwapType.NoSwap,
                isLong: params.isLong,
                shouldUnwrapNativeToken: false,
                autoCancel: true,
                referralCode: params.referralCode
            })
        );
        _setPendingOrderKey(orderKey, params.isIncrease);
        return orderKey;
    }

    function _processIncreasePosition(uint256 initialCollateralDeltaAmount, uint256 sizeDeltaUsd) private {
        DataTypes.PositionManagerPayload memory callbackParams;
        if (initialCollateralDeltaAmount > 0) {
            // increase collateral
            _getGmxV2PositionManagerStorage().pendingCollateralAmount = 0;
            callbackParams.collateralDeltaAmount = initialCollateralDeltaAmount;
        }
        if (sizeDeltaUsd > 0) {
            uint256 sizeInTokensAfter = GmxV2Lib.getPositionSizeInTokens(_getGmxParams(config()));
            uint256 sizeInTokensBefore = _getGmxV2PositionManagerStorage().sizeInTokensBefore;
            _getGmxV2PositionManagerStorage().sizeInTokensBefore = 0;
            (, callbackParams.sizeDeltaInTokens) = sizeInTokensAfter.trySub(sizeInTokensBefore);
        }
        callbackParams.isIncrease = true;
        IManagedBasisStrategy(strategy()).afterAdjustPosition(callbackParams);
    }

    function _processDecreasePosition() private {
        DataTypes.PositionManagerPayload memory callbackParams;
        uint256 sizeInTokensBefore = _getGmxV2PositionManagerStorage().sizeInTokensBefore;
        if (sizeInTokensBefore > 0) {
            uint256 sizeInTokensAfter = GmxV2Lib.getPositionSizeInTokens(_getGmxParams(config()));
            (, callbackParams.sizeDeltaInTokens) = sizeInTokensBefore.trySub(sizeInTokensAfter);
            _getGmxV2PositionManagerStorage().sizeInTokensBefore = 0;
        }
        uint256 decreasingCollateralDeltaAmount = _getGmxV2PositionManagerStorage().decreasingCollateralDeltaAmount;
        if (decreasingCollateralDeltaAmount > 0) {
            uint256 idleCollateralAmount = IERC20(collateralToken()).balanceOf(address(this));
            callbackParams.collateralDeltaAmount = idleCollateralAmount > decreasingCollateralDeltaAmount
                ? decreasingCollateralDeltaAmount
                : idleCollateralAmount;
            _getGmxV2PositionManagerStorage().decreasingCollateralDeltaAmount = 0;
        }
        callbackParams.isIncrease = false;
        IManagedBasisStrategy(strategy()).afterAdjustPosition(callbackParams);
    }

    function _getGmxParams(address _config) private view returns (GmxV2Lib.GmxParams memory) {
        Market.Props memory market = Market.Props({
            marketToken: marketToken(),
            indexToken: indexToken(),
            longToken: longToken(),
            shortToken: shortToken()
        });
        return GmxV2Lib.GmxParams({
            market: market,
            dataStore: IConfig(_config).getAddress(ConfigKeys.GMX_DATA_STORE),
            reader: IConfig(_config).getAddress(ConfigKeys.GMX_READER),
            account: address(this),
            collateralToken: collateralToken(),
            isLong: isLong()
        });
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
        return _getGmxV2PositionManagerStorage().pendingIncreaseOrderKey != bytes32(0)
            || _getGmxV2PositionManagerStorage().pendingDecreaseOrderKey != bytes32(0);
    }

    /// @dev validate if the caller is OrderHandler of gmx
    function _validateOrderHandler(bytes32 orderKey, bool isIncrease) private view {
        if (
            msg.sender != IConfig(config()).getAddress(ConfigKeys.GMX_ORDER_HANDLER)
                || (
                    isIncrease
                        ? orderKey != _getGmxV2PositionManagerStorage().pendingIncreaseOrderKey
                        : orderKey != _getGmxV2PositionManagerStorage().pendingDecreaseOrderKey
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
            $.pendingIncreaseOrderKey = orderKey;
        } else {
            $.pendingDecreaseOrderKey = orderKey;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function config() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.config;
    }

    function collateralToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.collateralToken;
    }

    function strategy() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.strategy;
    }

    function keeper() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return IConfig($.config).getAddress(ConfigKeys.KEEPER);
    }

    function marketToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.marketToken;
    }

    function indexToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.indexToken;
    }

    function longToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.longToken;
    }

    function shortToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.shortToken;
    }

    function isLong() public view returns (bool) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.isLong;
    }

    function maxClaimableFundingShare() public view returns (uint256) {
        return _getGmxV2PositionManagerStorage().maxClaimableFundingShare;
    }

    function pendingIncreaseOrderKey() public view returns (bytes32) {
        return _getGmxV2PositionManagerStorage().pendingIncreaseOrderKey;
    }

    function pendingDecreaseOrderKey() public view returns (bytes32) {
        return _getGmxV2PositionManagerStorage().pendingDecreaseOrderKey;
    }
}
