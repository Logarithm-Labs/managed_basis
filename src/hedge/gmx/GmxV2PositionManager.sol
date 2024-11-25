// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IBaseOrderUtils} from "src/externals/gmx-v2/interfaces/IBaseOrderUtils.sol";
import {IOrderCallbackReceiver} from "src/externals/gmx-v2/interfaces/IOrderCallbackReceiver.sol";
import {IGasFeeCallbackReceiver} from "src/externals/gmx-v2/interfaces/IGasFeeCallbackReceiver.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {EventUtils} from "src/externals/gmx-v2/libraries/EventUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Order} from "src/externals/gmx-v2/libraries/Order.sol";
import {Position} from "src/externals/gmx-v2/libraries/Position.sol";

import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IGmxConfig} from "src/hedge/gmx/IGmxConfig.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {IGasStation} from "src/gas-station/IGasStation.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {GmxV2Lib} from "src/libraries/gmx/GmxV2Lib.sol";

/// @title GmxV2PositionManager
///
/// @author Logarithm Labs
///
/// @notice GmxV2PositionManager is a dedicated smart contract that interacts with the GMX protocol
/// to maintain and adjust short positions in alignment with the strategy’s delta-neutral requirements.
/// This manager operates as an auxiliary component to the main strategy, ensuring that the
/// hedge remains effective by dynamically adjusting the size of the short position based on market movements.
///
/// @dev GmxV2PositionManager is an upgradeable smart contract, deployed through the beacon proxy pattern.
contract GmxV2PositionManager is Initializable, IHedgeManager, IOrderCallbackReceiver, IGasFeeCallbackReceiver {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 constant MIN_IDLE_COLLATERAL_USD = 1e31; // $10

    /// @dev Describes the state of position manager.
    enum Status {
        IDLE,
        INCREASE,
        DECREASE_ONE_STEP,
        DECREASE_TWO_STEP,
        SETTLE
    }

    /// @dev Used to create GMX order internally.
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
        address oracle;
        address gasStation;
        address config;
        address strategy;
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
        address collateralToken;
        bool isLong;
        // state
        Status status;
        // bytes32 activeRequestId;
        bytes32 pendingIncreaseOrderKey;
        bytes32 pendingDecreaseOrderKey;
        uint256 pendingCollateralAmount;
        // this value is set only when changing position sizes
        uint256 sizeInTokensBefore;
        uint256 decreasingCollateralDeltaAmount;
        // position fee metrics
        uint256 pendingPositionFeeUsdForIncrease;
        uint256 pendingPositionFeeUsdForDecrease;
        uint256 cumulativePositionFeeUsd;
        // funding fee metrics
        uint256 positionFundingFeeAmountPerSize;
        uint256 cumulativeClaimedFundingUsd;
        uint256 cumulativeFundingFeeUsd;
        // borrowing fee metrics
        uint256 positionBorrowingFactor;
        uint256 cumulativeBorrowingFeeUsd;
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

    /// @dev Emitted when the claimable funding fee gets claimed.
    event FundingClaimed(address indexed token, uint256 indexed amount);

    /// @dev Emitted when the claimable collateral gets claimed.
    event CollateralClaimed(address indexed token, uint256 indexed amount);

    /// @dev Emitted when a position adjustment is requested by strategy.
    event PositionAdjustmentRequested(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyStrategy() {
        _onlyStrategy();
        _;
    }

    modifier whenNotPending() {
        _whenNotPending();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address strategy_, address config_, address gasStation_, address marketKey_)
        external
        initializer
    {
        address asset = address(IBasisStrategy(strategy_).asset());

        if (marketKey_ == address(0) || gasStation_ == address(0)) {
            revert Errors.InvalidMarket();
        }

        address dataStore = IGmxConfig(config_).dataStore();
        address reader = IGmxConfig(config_).reader();
        Market.Props memory market = IReader(reader).getMarket(dataStore, marketKey_);
        // assuming short position open
        if ((market.longToken != asset && market.shortToken != asset)) {
            revert Errors.InvalidInitializationAssets();
        }

        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        $.gasStation = gasStation_;
        $.oracle = IBasisStrategy(strategy_).oracle();
        $.config = config_;
        $.strategy = strategy_;
        $.marketToken = market.marketToken;
        $.indexToken = market.indexToken;
        $.longToken = market.longToken;
        $.shortToken = market.shortToken;
        $.collateralToken = asset;
        $.isLong = false;

        // approve strategy to max amount
        IERC20(asset).approve($.strategy, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHedgeManager
    function adjustPosition(AdjustPositionPayload calldata params) external onlyStrategy whenNotPending {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        if (params.sizeDeltaInTokens == 0 && params.collateralDeltaAmount == 0) {
            revert Errors.InvalidAdjustmentParams();
        }
        IGmxConfig _config = config();
        GmxV2Lib.GmxParams memory gmxParams = _getGmxParams(_config);
        address _oracle = $.oracle;
        address _collateralToken = collateralToken();
        uint256 idleCollateralAmount = IERC20(_collateralToken).balanceOf(address(this));
        if (params.isIncrease) {
            if (params.collateralDeltaAmount > idleCollateralAmount) {
                revert Errors.NotEnoughCollateral();
            }

            GmxV2Lib.IncreasePositionResult memory increaseResult;
            if (params.sizeDeltaInTokens > 0) {
                increaseResult = GmxV2Lib.getIncreasePositionResult(gmxParams, _oracle, params.sizeDeltaInTokens);
            }
            if (increaseResult.positionFeeUsd > 0) $.pendingPositionFeeUsdForIncrease = increaseResult.positionFeeUsd;

            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: true,
                    exchangeRouter: _config.exchangeRouter(),
                    orderVault: _config.orderVault(),
                    collateralToken: _collateralToken,
                    collateralDeltaAmount: idleCollateralAmount,
                    sizeDeltaUsd: increaseResult.sizeDeltaUsd,
                    callbackGasLimit: _config.callbackGasLimit(),
                    referralCode: _config.referralCode()
                })
            );
            $.status = Status.INCREASE;
        } else {
            if (params.sizeDeltaInTokens == 0 && params.collateralDeltaAmount <= idleCollateralAmount) {
                IBasisStrategy(strategy()).afterAdjustPosition(
                    AdjustPositionPayload({
                        sizeDeltaInTokens: 0,
                        collateralDeltaAmount: params.collateralDeltaAmount,
                        isIncrease: false
                    })
                );
            } else {
                uint256 collateralDeltaAmount = params.collateralDeltaAmount;
                if (collateralDeltaAmount > 0) {
                    $.decreasingCollateralDeltaAmount = collateralDeltaAmount;
                }
                if (idleCollateralAmount > 0) {
                    (, collateralDeltaAmount) = params.collateralDeltaAmount.trySub(idleCollateralAmount);
                }
                GmxV2Lib.DecreasePositionResult memory decreaseResult = GmxV2Lib.getDecreasePositionResult(
                    gmxParams,
                    _oracle,
                    params.sizeDeltaInTokens,
                    collateralDeltaAmount,
                    config().realizedPnlDiffFactor()
                );

                if (decreaseResult.positionFeeUsdForDecrease > 0) {
                    $.pendingPositionFeeUsdForDecrease = decreaseResult.positionFeeUsdForDecrease;
                }
                if (decreaseResult.positionFeeUsdForIncrease > 0) {
                    $.pendingPositionFeeUsdForIncrease = decreaseResult.positionFeeUsdForIncrease;
                }
                _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: false,
                        exchangeRouter: _config.exchangeRouter(),
                        orderVault: _config.orderVault(),
                        collateralToken: _collateralToken,
                        collateralDeltaAmount: !decreaseResult.isIncreaseCollateral
                            ? decreaseResult.initialCollateralDeltaAmount
                            : 0,
                        sizeDeltaUsd: decreaseResult.sizeDeltaUsdToDecrease,
                        callbackGasLimit: _config.callbackGasLimit(),
                        referralCode: _config.referralCode()
                    })
                );
                if (decreaseResult.sizeDeltaUsdToIncrease > 0) {
                    $.status = Status.DECREASE_TWO_STEP;
                    _createOrder(
                        InternalCreateOrderParams({
                            isLong: isLong(),
                            isIncrease: true,
                            exchangeRouter: _config.exchangeRouter(),
                            orderVault: _config.orderVault(),
                            collateralToken: _collateralToken,
                            collateralDeltaAmount: 0,
                            sizeDeltaUsd: decreaseResult.sizeDeltaUsdToIncrease,
                            callbackGasLimit: _config.callbackGasLimit(),
                            referralCode: _config.referralCode()
                        })
                    );
                } else {
                    $.status = Status.DECREASE_ONE_STEP;
                }
            }
        }

        emit PositionAdjustmentRequested(params.sizeDeltaInTokens, params.collateralDeltaAmount, params.isIncrease);
    }

    /// @dev Realizes the claimable funding or increases collateral if there are idle assets
    ///
    /// @inheritdoc IHedgeManager
    function keep() external onlyStrategy whenNotPending {
        _getGmxV2PositionManagerStorage().status = Status.SETTLE;
        // if there is idle collateral, then increase that amount to settle the claimable funding
        // otherwise, decrease collateral by 1 to settle
        address _collateralToken = collateralToken();
        IGmxConfig _config = config();
        uint256 idleCollateralAmount = IERC20(_collateralToken).balanceOf(address(this));
        if (idleCollateralAmount > 0) {
            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: true,
                    exchangeRouter: _config.exchangeRouter(),
                    orderVault: _config.orderVault(),
                    collateralToken: _collateralToken,
                    collateralDeltaAmount: idleCollateralAmount,
                    sizeDeltaUsd: 0,
                    callbackGasLimit: _config.callbackGasLimit(),
                    referralCode: _config.referralCode()
                })
            );
        } else {
            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: false,
                    exchangeRouter: _config.exchangeRouter(),
                    orderVault: _config.orderVault(),
                    collateralToken: _collateralToken,
                    collateralDeltaAmount: 1,
                    sizeDeltaUsd: 0,
                    callbackGasLimit: _config.callbackGasLimit(),
                    referralCode: _config.referralCode()
                })
            );
        }
    }

    /// @dev Claims all the claimable funding fees.
    /// This is callable by anyone.
    /// Collateral funding amount is transferred to this position manager, otherwise transferred to strategy
    function claimFunding() public {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();

        IExchangeRouter exchangeRouter = IExchangeRouter(config().exchangeRouter());
        address _shortToken = shortToken();
        address _longToken = longToken();
        address _collateralToken = collateralToken();
        IOracle oracle = IOracle($.oracle);
        uint256 claimedFundingUsd;

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

        if (shortTokenAmount > 0) {
            uint256 shortTokePrice = oracle.getAssetPrice(_shortToken);
            claimedFundingUsd += shortTokenAmount * shortTokePrice;
        }

        tokens[0] = _longToken;
        if (_longToken == _collateralToken) {
            uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, address(this));
            longTokenAmount = amounts[0];
        } else {
            uint256[] memory amounts = exchangeRouter.claimFundingFees(markets, tokens, strategy());
            longTokenAmount = amounts[0];
        }

        if (longTokenAmount > 0) {
            uint256 longTokenPrice = oracle.getAssetPrice(_longToken);
            claimedFundingUsd += longTokenAmount * longTokenPrice;
        }

        $.cumulativeClaimedFundingUsd += claimedFundingUsd;

        emit FundingClaimed(_shortToken, shortTokenAmount);
        emit FundingClaimed(_longToken, longTokenAmount);
    }

    /// @dev Claims all the claimable collateral amount.
    /// Note: This amount is stored by account, token, timeKey and
    /// therefore the only way to figure it out is to use GMX events.
    ///
    /// @param token The token address derived from the gmx event: ClaimableCollateralUpdated
    /// @param timeKey The timeKey value derived from the gmx event: ClaimableCollateralUpdated
    function claimCollateral(address token, uint256 timeKey) external {
        IExchangeRouter exchangeRouter = IExchangeRouter(config().exchangeRouter());
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
        _processPendingPositionFee(isIncrease, true);

        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        Status _status = $.status;
        Position.Props memory position = GmxV2Lib.getPosition(_getGmxParams(config()));
        uint256 prevPositionSizeInUsd = isIncrease
            ? position.numbers.sizeInUsd - order.numbers.sizeDeltaUsd
            : position.numbers.sizeInUsd + order.numbers.sizeDeltaUsd;
        address _collateralToken = $.collateralToken;
        uint256 collateralTokenPrice = IOracle($.oracle).getAssetPrice(_collateralToken);

        // use factors from gmx data store instead of position infos
        // because when closing a position, the factors become 0 that resulted in wrong calc
        // calls the infos right after updating them, so becomes latest
        (uint256 fundingFeeAmountPerSize, uint256 cumulativeBorrowingFactor) =
            GmxV2Lib.getSavedFundingAndBorrowingFactors(config().dataStore(), $.marketToken, _collateralToken, $.isLong);

        // cumulate funding fee
        uint256 positionFundingFeeAmountPerSize = $.positionFundingFeeAmountPerSize;
        uint256 fundingFeeAmount =
            GmxV2Lib.getFundingAmount(fundingFeeAmountPerSize, positionFundingFeeAmountPerSize, prevPositionSizeInUsd);
        $.positionFundingFeeAmountPerSize = fundingFeeAmountPerSize;
        $.cumulativeFundingFeeUsd += fundingFeeAmount * collateralTokenPrice;

        // cumulate borrowing fee
        uint256 positionBorrowingFactor = $.positionBorrowingFactor;
        uint256 borrowingFeeUsd =
            GmxV2Lib.getBorrowingFees(cumulativeBorrowingFactor, positionBorrowingFactor, prevPositionSizeInUsd);
        $.positionBorrowingFactor = cumulativeBorrowingFactor;
        $.cumulativeBorrowingFeeUsd += borrowingFeeUsd;

        if (isIncrease && order.numbers.initialCollateralDeltaAmount > 0) {
            $.pendingCollateralAmount = 0;
        }

        if (_status == Status.SETTLE) {
            // doesn't change position size
            $.status = Status.IDLE;
            // notify strategy that keeping has been done
            IBasisStrategy(strategy()).afterAdjustPosition(
                AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: isIncrease})
            );
            claimFunding();
        } else if (_status == Status.INCREASE) {
            _processIncreasePosition(order.numbers.initialCollateralDeltaAmount, position.numbers.sizeInTokens);
            $.status = Status.IDLE;
        } else if (_status == Status.DECREASE_ONE_STEP) {
            _processDecreasePosition(position.numbers.sizeInTokens);
            $.status = Status.IDLE;
        } else if (_status == Status.DECREASE_TWO_STEP) {
            $.status = Status.DECREASE_ONE_STEP;
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
        _processPendingPositionFee(isIncrease, false);

        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        Status _status = $.status;

        if (isIncrease && order.numbers.initialCollateralDeltaAmount > 0) {
            $.pendingCollateralAmount = 0;
        }

        if (_status == Status.IDLE) return;
        if (_status == Status.INCREASE || _status == Status.SETTLE) {
            IBasisStrategy(strategy()).afterAdjustPosition(
                AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: isIncrease})
            );
        } else if (_status == Status.DECREASE_TWO_STEP) {
            $.status = Status.DECREASE_ONE_STEP;
        } else if (_status == Status.DECREASE_ONE_STEP) {
            // in case when the first order was executed successfully or one step decrease order was failed
            // or in case when the order executed in wrong order by gmx was failed
            IBasisStrategy(strategy()).afterAdjustPosition(
                AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: false})
            );
        }
        $.status = Status.IDLE;
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
        (bool success,) = gasStation().call{value: msg.value}("");
        assert(success);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL/PUBLIC VIEWERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHedgeManager
    function positionNetBalance() public view returns (uint256) {
        IGmxConfig _config = config();
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        (uint256 remainingCollateral, uint256 claimableTokenAmount) = GmxV2Lib
            .getRemainingCollateralAndClaimableFundingAmount(_getGmxParams(_config), $.oracle, _config.referralStorage());

        return remainingCollateral + claimableTokenAmount + IERC20(collateralToken()).balanceOf(address(this))
            + $.pendingCollateralAmount;
    }

    /// @inheritdoc IHedgeManager
    function currentLeverage() public view returns (uint256) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        IGmxConfig _config = config();
        return GmxV2Lib.getCurrentLeverage(_getGmxParams(_config), $.oracle, _config.referralStorage());
    }

    /// @inheritdoc IHedgeManager
    function positionSizeInTokens() public view returns (uint256) {
        Position.Props memory position = GmxV2Lib.getPosition(_getGmxParams(config()));
        return position.numbers.sizeInTokens;
    }

    /// @dev Calculates the execution fee that is needed from gmx when increasing and decreasing.
    ///
    /// @return feeIncrease The execution fee for increase
    /// @return feeDecrease The execution fee for decrease
    function getExecutionFee() public view returns (uint256 feeIncrease, uint256 feeDecrease) {
        IGmxConfig _config = config();
        return GmxV2Lib.getExecutionFee(_config.dataStore(), _config.callbackGasLimit());
    }

    /// @dev The current claimable funding amounts that are not accrued
    function getClaimableFundingAmounts()
        external
        view
        returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount)
    {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        IGmxConfig _config = config();
        (claimableLongTokenAmount, claimableShortTokenAmount) =
            GmxV2Lib.getClaimableFundingAmounts(_getGmxParams(_config), $.oracle, _config.referralStorage());
        return (claimableLongTokenAmount, claimableShortTokenAmount);
    }

    /// @dev The accrued claimable token amounts.
    function getAccruedClaimableFundingAmounts()
        external
        view
        returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount)
    {
        IGmxConfig _config = config();
        (claimableLongTokenAmount, claimableShortTokenAmount) =
            GmxV2Lib.getAccruedClaimableFundingAmounts(_getGmxParams(_config));
        return (claimableLongTokenAmount, claimableShortTokenAmount);
    }

    /// @dev The total cumulated funding fee and borrowing fee in usd including next fees.
    function cumulativeFundingAndBorrowingFeesUsd()
        external
        view
        returns (uint256 fundingFeeUsd, uint256 borrowingFeeUsd)
    {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        IGmxConfig _config = config();
        (uint256 nextFundingFeeUsd, uint256 nextBorrowingFeeUsd) =
            GmxV2Lib.getNextFundingAndBorrowingFeesUsd(_getGmxParams(_config), $.oracle, _config.referralStorage());
        fundingFeeUsd = $.cumulativeFundingFeeUsd + nextFundingFeeUsd;
        borrowingFeeUsd = $.cumulativeBorrowingFeeUsd + nextBorrowingFeeUsd;
        return (fundingFeeUsd, borrowingFeeUsd);
    }

    /// @dev Checks if the claimable funding amount is over than max share
    ///      or if idle collateral is bigger than minimum requirement so that
    ///      the position can be settled to add it to position's collateral.
    /// @inheritdoc IHedgeManager
    function needKeep() external view returns (bool) {
        IGmxConfig _config = config();
        address _collateralToken = collateralToken();
        address oralcle = _getGmxV2PositionManagerStorage().oracle;
        uint256 idleCollateralAmount = IERC20(_collateralToken).balanceOf(address(this));
        uint256 idleCollateralAmountUsd = IOracle(oralcle).getAssetPrice(_collateralToken) * idleCollateralAmount;
        if (idleCollateralAmountUsd > MIN_IDLE_COLLATERAL_USD) {
            return true;
        }
        (uint256 remainingCollateral, uint256 claimableTokenAmount) = GmxV2Lib
            .getRemainingCollateralAndClaimableFundingAmount(_getGmxParams(_config), oralcle, _config.referralStorage());
        if (remainingCollateral > 0) {
            return
                claimableTokenAmount.mulDiv(Constants.FLOAT_PRECISION, remainingCollateral) > maxClaimableFundingShare();
        } else {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates increase/decrease GMX order
    function _createOrder(InternalCreateOrderParams memory params) private returns (bytes32) {
        if (params.isIncrease && params.collateralDeltaAmount > 0) {
            _getGmxV2PositionManagerStorage().pendingCollateralAmount = params.collateralDeltaAmount;
            IERC20(params.collateralToken).safeTransfer(params.orderVault, params.collateralDeltaAmount);
        }
        (uint256 increaseExecutionFee, uint256 decreaseExecutionFee) = getExecutionFee();
        uint256 executionFee = params.isIncrease ? increaseExecutionFee : decreaseExecutionFee;
        IGasStation(gasStation()).payGmxExecutionFee(params.exchangeRouter, params.orderVault, executionFee);
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

    /// @dev Used in GMX callback functions.
    function _processIncreasePosition(uint256 initialCollateralDeltaAmount, uint256 sizeInTokens) private {
        AdjustPositionPayload memory callbackParams;
        if (initialCollateralDeltaAmount > 0) {
            // increase collateral
            callbackParams.collateralDeltaAmount = initialCollateralDeltaAmount;
        }
        callbackParams.sizeDeltaInTokens = _recordPositionSize(sizeInTokens);
        callbackParams.isIncrease = true;
        IBasisStrategy(strategy()).afterAdjustPosition(callbackParams);
    }

    /// @dev Used in GMX callback functions.
    function _processDecreasePosition(uint256 sizeInTokens) private {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        AdjustPositionPayload memory callbackParams;
        uint256 decreasingCollateralDeltaAmount = $.decreasingCollateralDeltaAmount;
        if (sizeInTokens == 0) {
            uint256 idleCollateralAmount = IERC20(collateralToken()).balanceOf(address(this));
            callbackParams.collateralDeltaAmount = idleCollateralAmount;
        } else if (decreasingCollateralDeltaAmount > 0) {
            uint256 idleCollateralAmount = IERC20(collateralToken()).balanceOf(address(this));
            callbackParams.collateralDeltaAmount = (idleCollateralAmount < decreasingCollateralDeltaAmount)
                ? idleCollateralAmount
                : decreasingCollateralDeltaAmount;
            $.decreasingCollateralDeltaAmount = 0;
        }
        callbackParams.sizeDeltaInTokens = _recordPositionSize(sizeInTokens);
        IBasisStrategy(strategy()).afterAdjustPosition(callbackParams);
    }

    /// @dev Stores new size and return delta size in tokens
    function _recordPositionSize(uint256 sizeInTokens) private returns (uint256) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        uint256 sizeInTokensBefore = $.sizeInTokensBefore;
        $.sizeInTokensBefore = sizeInTokens;
        uint256 sizeDeltaInTokens =
            sizeInTokens > sizeInTokensBefore ? sizeInTokens - sizeInTokensBefore : sizeInTokensBefore - sizeInTokens;
        return sizeDeltaInTokens;
    }

    /// @dev Processes the pending position fees.
    function _processPendingPositionFee(bool isIncrease, bool isExecuted) private {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        if (isIncrease) {
            uint256 _pendingPositionFeeUsdForIncrease = $.pendingPositionFeeUsdForIncrease;
            if (_pendingPositionFeeUsdForIncrease > 0) {
                $.pendingPositionFeeUsdForIncrease = 0;
                if (isExecuted) $.cumulativePositionFeeUsd += _pendingPositionFeeUsdForIncrease;
            }
        } else {
            uint256 _pendingPositionFeeUsdForDecrease = $.pendingPositionFeeUsdForDecrease;
            if (_pendingPositionFeeUsdForDecrease > 0) {
                $.pendingPositionFeeUsdForDecrease = 0;
                if (isExecuted) $.cumulativePositionFeeUsd += _pendingPositionFeeUsdForDecrease;
            }
        }
    }

    /// @dev Derives a set of gmx params that are need to call gmx smart contracts.
    function _getGmxParams(IGmxConfig _config) private view returns (GmxV2Lib.GmxParams memory) {
        Market.Props memory market = Market.Props({
            marketToken: marketToken(),
            indexToken: indexToken(),
            longToken: longToken(),
            shortToken: shortToken()
        });
        return GmxV2Lib.GmxParams({
            market: market,
            dataStore: _config.dataStore(),
            reader: _config.reader(),
            account: address(this),
            collateralToken: collateralToken(),
            isLong: isLong()
        });
    }

    /*//////////////////////////////////////////////////////////////
                        VALIDATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // @dev Used in modifier which reduces the code size
    function _onlyStrategy() private view {
        if (msg.sender != strategy()) {
            revert Errors.CallerNotStrategy();
        }
    }

    // @dev Used to stop create orders one by on
    function _whenNotPending() private view {
        if (_isPending()) {
            revert Errors.AlreadyPending();
        }
    }

    /// @dev True when a GMX order has been submitted, but not executed.
    function _isPending() private view returns (bool) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.pendingIncreaseOrderKey != bytes32(0) || $.pendingDecreaseOrderKey != bytes32(0);
    }

    /// @dev Validates if the caller is OrderHandler of gmx
    function _validateOrderHandler(bytes32 orderKey, bool isIncrease) private view {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        if (
            msg.sender != config().orderHandler()
                || (isIncrease ? orderKey != $.pendingIncreaseOrderKey : orderKey != $.pendingDecreaseOrderKey)
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

    /// @notice The address of gmx config smart contract.
    function config() public view returns (IGmxConfig) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return IGmxConfig($.config);
    }

    /// @inheritdoc IHedgeManager
    function collateralToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.collateralToken;
    }

    /// @notice The address of strategy.
    function strategy() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.strategy;
    }

    /// @notice The address of the gmx gas station smart contract.
    function gasStation() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.gasStation;
    }

    /// @notice The address of gmx market token where position is opened at.
    function marketToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.marketToken;
    }

    /// @inheritdoc IHedgeManager
    function indexToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.indexToken;
    }

    /// @notice The address of long token of the opened market.
    function longToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.longToken;
    }

    /// @notice The address of short token of the opened market.
    function shortToken() public view returns (address) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.shortToken;
    }

    /// @notice The direction of position.
    function isLong() public view returns (bool) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.isLong;
    }

    /// @notice The max share of claimable funding before it get claimed through keeping.
    function maxClaimableFundingShare() public view returns (uint256) {
        return config().maxClaimableFundingShare();
    }

    /// @notice The gmx increase order key that is in pending.
    function pendingIncreaseOrderKey() public view returns (bytes32) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.pendingIncreaseOrderKey;
    }

    /// @notice The gmx decrease order key that is in pending.
    function pendingDecreaseOrderKey() public view returns (bytes32) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.pendingDecreaseOrderKey;
    }

    /// @inheritdoc IHedgeManager
    function increaseCollateralMinMax() external pure returns (uint256 min, uint256 max) {
        return (0, type(uint256).max);
    }

    /// @inheritdoc IHedgeManager
    function increaseSizeMinMax() external pure returns (uint256 min, uint256 max) {
        return (0, type(uint256).max);
    }

    /// @inheritdoc IHedgeManager
    function decreaseCollateralMinMax() external pure returns (uint256 min, uint256 max) {
        return (0, type(uint256).max);
    }

    /// @inheritdoc IHedgeManager
    function decreaseSizeMinMax() external pure returns (uint256 min, uint256 max) {
        return (0, type(uint256).max);
    }

    /// @inheritdoc IHedgeManager
    function limitDecreaseCollateral() external view returns (uint256) {
        return config().limitDecreaseCollateral();
    }

    /// @notice The total cumulated position fee in usd.
    function cumulativePositionFeeUsd() external view returns (uint256) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.cumulativePositionFeeUsd;
    }

    /// @notice The total claimed funding fee in usd.
    function cumulativeClaimedFundingUsd() external view returns (uint256) {
        GmxV2PositionManagerStorage storage $ = _getGmxV2PositionManagerStorage();
        return $.cumulativeClaimedFundingUsd;
    }
}
