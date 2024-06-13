// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IBaseOrderUtils} from "src/externals/gmx-v2/interfaces/IBaseOrderUtils.sol";
import {IOrderCallbackReceiver} from "src/externals/gmx-v2/interfaces/IOrderCallbackReceiver.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {EventUtils} from "src/externals/gmx-v2/libraries/EventUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Order} from "src/externals/gmx-v2/libraries/Order.sol";

import {IBasisGmxFactory} from "src/interfaces/IBasisGmxFactory.sol";
import {IBasisStrategy} from "src/interfaces/IBasisStrategy.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IKeeper} from "src/interfaces/IKeeper.sol";

import {Errors} from "src/libraries/Errors.sol";
import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";

import {FactoryDeployable} from "src/common/FactoryDeployable.sol";

/// @title A gmx position manager
/// @author Logarithm Labs
/// @dev this contract must be deployed only by the factory
contract GmxV2PositionManager is IOrderCallbackReceiver, UUPSUpgradeable, FactoryDeployable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant PRECISION = 1e18;
    string constant API_VERSION = "0.0.1";

    enum Status {
        IDLE,
        INCREASING,
        DECREASING,
        DEC_INC_SIZE, // decrease and then increase size
        DEC_INC_COLLATERAL, // decrease and then increase collateral
        KEEPING
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
        address strategy;
        address keeper;
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
        address collateralToken;
        bool isLong;
        uint256 maxClaimableFundingShare;
        uint256 maxHedgeDeviation;
        // state
        Status status;
        // bytes32 activeRequestId;
        bytes32 pendingIncreaseOrderKey;
        bytes32 pendingDecreaseOrderKey;
        uint256 pendingCollateralAmount;
        uint256 nextCollateralIncreaseAmount;
        // state for calcuating execution cost
        uint256 pendingPositionFeeUsd;
        uint256 spotExecutionPrice;
        uint256 sizeInTokensBefore;
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
    event PositionSizeIncreased(uint256 indexed sizeDeltaInTokens);

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

    function initialize(address strategy_, address keeper_) external initializer {
        if (keeper_ == address(0)) {
            revert Errors.ZeroAddress();
        }
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
        $.strategy = strategy_;
        $.keeper = keeper_;
        $.marketToken = market.marketToken;
        $.indexToken = market.indexToken;
        $.longToken = market.longToken;
        $.shortToken = market.shortToken;
        $.collateralToken = asset;
        $.isLong = false;

        $.maxClaimableFundingShare = 1e16; // 1%
        $.maxHedgeDeviation = 1e15; // 0.1%

        // approve strategy to max amount
        IERC20(asset).approve($.strategy, type(uint256).max);
    }

    function _authorizeUpgrade(address) internal virtual override onlyFactory {}

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev send back eth to the strategy
    receive() external payable {
        (bool success,) = keeper().call{value: msg.value}("");
        assert(success);
    }

    function setMaxClaimableFundingShare(uint256 _maxClaimableFundingShare) external onlyFactory {
        require(_maxClaimableFundingShare < 1 ether);
        _getGmxV2PositionManagerStorage().maxClaimableFundingShare = _maxClaimableFundingShare;
    }

    function setMaxHedgeDeviation(uint256 _maxDeviation) external onlyFactory {
        require(_maxDeviation < 1 ether);
        _getGmxV2PositionManagerStorage().maxHedgeDeviation = _maxDeviation;
    }

    function adjustPosition(
        uint256 sizeDeltaInTokens,
        uint256 spotExecutionPrice,
        uint256 collateralDeltaAmount,
        bool isIncrease
    ) external onlyStrategy whenNotPending returns (bytes32) {
        address _factory = factory();
        GmxV2Lib.GetPosition memory positionParams = _getPositionParams(_factory);
        GmxV2Lib.GetPrices memory pricesParams = _getPricesParams(_factory);

        uint256 idleCollateralAmount = IERC20(collateralToken()).balanceOf(address(this));

        if (isIncrease) {
            if (collateralDeltaAmount > idleCollateralAmount) {
                revert Error.NotEnoughCollateral();
            }

            if (idleCollateralAmount > 0) {
                IERC20(collateralToken()).safeTransfer(IBasisGmxFactory(_factory).orderVault(), idleCollateralAmount);
                _getGmxV2PositionManagerStorage().pendingCollateralAmount = idleCollateralAmount;
            }

            uint256 sizeDeltaUsd;
            if (sizeDeltaInTokens > 0) {
                uint256 positionFeeUsd;
                (sizeDeltaUsd, positionFeeUsd) =
                    GmxV2Lib.getSizeDeltaUsdForIncrease(positionParams, pricesParams, sizeDeltaInTokens);

                if (positionFeeUsd > 0) {
                    // record position fee
                    // once order is confirmed, can't calc the exact fee because open interest are changed.
                    _getGmxV2PositionManagerStorage().pendingPositionFeeUsd = positionFeeUsd;
                }
            }
            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: true,
                    exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                    orderVault: IBasisGmxFactory(_factory).orderVault(),
                    collateralToken: collateralToken(),
                    collateralDeltaAmount: idleCollateralAmount,
                    sizeDeltaUsd: sizeDeltaUsd,
                    callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                    referralCode: IBasisGmxFactory(_factory).referralCode()
                })
            );
            _getGmxV2PositionManagerStorage().status = Status.INCREASING;
        } else {
            if (spotExecutionPrice > 0) {
                _recordExecutionCostCalcInfo(positionParams, spotExecutionPrice);
            }

            // if(idleCollateralAmount > collateralDeltaAmount) {
            //     collateralDeltaAmount = 0;
            // } else {
            //     collateralDeltaAmount -= idleCollateralAmount;
            // }

            // if (sizeDeltaInTokens == 0 && collateralDeltaAmount == 0) {
            //     IBasisStrategy(strategy()).afterDecreasePositionCollateral(idleCollateralAmount, true);
            //     IBasisStrategy(strategy()).
            // }

            (
                bool isIncreaseCollateral,
                uint256 initialcollateralDeltaAmount,
                uint256 sizeDeltaUsdToDecrease,
                uint256 sizeDeltaUsdToIncrease,
                uint256 positionFeeUsd
            ) = GmxV2Lib.getDecreasePositionResult(
                positionParams, pricesParams, sizeDeltaInTokens, collateralDeltaAmount
            );

            if (positionFeeUsd > 0) {
                // record position fee
                // once order is confirmed, can't calc the exact fee because open interest are changed.
                _getGmxV2PositionManagerStorage().pendingPositionFeeUsd = positionFeeUsd;
            }

            _createOrder(
                InternalCreateOrderParams({
                    isLong: isLong(),
                    isIncrease: false,
                    exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                    orderVault: IBasisGmxFactory(_factory).orderVault(),
                    collateralToken: collateralToken(),
                    collateralDeltaAmount: !isIncreaseCollateral ? initialcollateralDeltaAmount : 0,
                    sizeDeltaUsd: sizeDeltaUsdToDecrease,
                    callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                    referralCode: IBasisGmxFactory(_factory).referralCode()
                })
            );

            if (sizeDeltaUsdToIncrease > 0) {
                _getGmxV2PositionManagerStorage().status = Status.DEC_INC_SIZE;
                _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: true,
                        exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                        orderVault: IBasisGmxFactory(_factory).orderVault(),
                        collateralToken: collateralToken(),
                        collateralDeltaAmount: 0,
                        sizeDeltaUsd: sizeDeltaUsdToIncrease,
                        callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                        referralCode: IBasisGmxFactory(_factory).referralCode()
                    })
                );
            } else if (isIncreaseCollateral) {
                _getGmxV2PositionManagerStorage().status = Status.DEC_INC_COLLATERAL;
                _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: true,
                        exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                        orderVault: IBasisGmxFactory(_factory).orderVault(),
                        collateralToken: collateralToken(),
                        collateralDeltaAmount: initialcollateralDeltaAmount,
                        sizeDeltaUsd: 0,
                        callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                        referralCode: IBasisGmxFactory(_factory).referralCode()
                    })
                );
            } else {
                _getGmxV2PositionManagerStorage().status = Status.DECREASING;
            }
        }

        return bytes32(0);
    }

    /// @notice claim funding or adjust size as needed
    function performUpkeep(bytes calldata performData) external onlyKeeper whenNotPending returns (bytes32) {
        (bool settleNeeded, bool adjustNeeded) = abi.decode(performData, (bool, bool));
        if (settleNeeded) {
            claimFunding();
        }
        if (adjustNeeded) {
            (, int256 sizeDeltaInTokens) = _checkAdjustPositionSize();
            address _factory = factory();
            if (sizeDeltaInTokens < 0) {
                uint256 sizeDeltaUsd =
                    GmxV2Lib.getSizeDeltaUsdForDecrease(_getPositionParams(_factory), uint256(-sizeDeltaInTokens));
                _getGmxV2PositionManagerStorage().status = Status.KEEPING;
                return _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: false,
                        exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                        orderVault: IBasisGmxFactory(_factory).orderVault(),
                        collateralToken: collateralToken(),
                        collateralDeltaAmount: 0,
                        sizeDeltaUsd: sizeDeltaUsd,
                        callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                        referralCode: IBasisGmxFactory(_factory).referralCode()
                    })
                );
            } else {
                uint256 sizeDeltaUsd = GmxV2Lib.getSizeDeltaUsdForIncrease(
                    _getPositionParams(_factory), _getPricesParams(_factory), uint256(-sizeDeltaInTokens)
                );
                return _createOrder(
                    InternalCreateOrderParams({
                        isLong: isLong(),
                        isIncrease: true,
                        exchangeRouter: IBasisGmxFactory(_factory).exchangeRouter(),
                        orderVault: IBasisGmxFactory(_factory).orderVault(),
                        collateralToken: collateralToken(),
                        collateralDeltaAmount: 0,
                        sizeDeltaUsd: sizeDeltaUsd,
                        callbackGasLimit: IBasisGmxFactory(_factory).callbackGasLimit(),
                        referralCode: IBasisGmxFactory(_factory).referralCode()
                    })
                );
            }
        }
        return bytes32(0);
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
    function afterOrderExecution(
        bytes32 key,
        Order.Props calldata order,
        EventUtils.EventLogData calldata /*eventData*/
    ) external override {
        bool isIncrease = order.numbers.orderType == Order.OrderType.MarketIncrease;
        _validateOrderHandler(key, isIncrease);
        _setPendingOrderKey(bytes32(0), isIncrease);
        if (_getGmxV2PositionManagerStorage().status == Status.KEEPING) {
            _getGmxV2PositionManagerStorage().status = Status.IDLE;
        } else {
            if (isIncrease) {
                if (_getGmxV2PositionManagerStorage().status == Status.INCREASING) {
                    if (order.numbers.initialCollateralDeltaAmount > 0) {
                        // increase collateral
                        _getGmxV2PositionManagerStorage().pendingCollateralAmount = 0;
                        IBasisStrategy(strategy()).afterIncreasePositionCollateral(
                            order.numbers.initialCollateralDeltaAmount, true
                        );
                    }
                    if (order.numbers.sizeDeltaInTokens > 0) {
                        IBasisStrategy(strategy()).afterIncreasePositionSize(order.numbers.sizeDeltaInTokens, true);
                    }
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                } else if (_getGmxV2PositionManagerStorage().status == Status.DEC_INC_SIZE) {
                    IBasisStrategy(strategy()).afterDecreasePositionCollateral(
                        IERC20(collateralToken()).balanceOf(address(this)), true
                    );
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                } else if (_getGmxV2PositionManagerStorage().status == Status.DEC_INC_COLLATERAL) {
                    IBasisStrategy(strategy()).afterDecreasePositionCollateral(
                        IERC20(collateralToken()).balanceOf(address(this)), true
                    );
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                }
                _getGmxV2PositionManagerStorage().status = Status.IDLE;
            } else {
                uint256 executionCostAmount;
                uint256 spotExecutionPrice = _getGmxV2PositionManagerStorage().spotExecutionPrice;
                // spotExecutionPrice > 0 means adjust sizes that needs the execution cost calc
                if (spotExecutionPrice > 0) {
                    uint256 collateralTokenPrice =
                        IOracle(IBasisGmxFactory(factory()).oracle()).getAssetPrice(collateralToken());
                    uint256 _sizeInTokensBefore = _getGmxV2PositionManagerStorage().sizeInTokensBefore;
                    uint256 _sizeInTokensAfter = GmxV2Lib.getPositionSizeInTokens(_getPositionParams(factory()));
                    uint256 sizeDeltaInTokens =
                        isIncrease ? _sizeInTokensAfter - _sizeInTokensBefore : _sizeInTokensBefore - _sizeInTokensAfter;
                    // executionCostInUsd = (spotExecutionPrice - hedgeExectuionPrice) * sizeDelta
                    // or = (hedgeExectuionPrice - spotExecutionPrice) * sizeDelta
                    // sizeDeltaUsd = hedgeExectuionPrice * sizeDelta
                    int256 executionCostInUsd =
                        order.numbers.sizeDeltaUsd.toInt256() - (spotExecutionPrice * sizeDeltaInTokens).toInt256();
                    uint256 pendingPositionFeeUsd = _getGmxV2PositionManagerStorage().pendingPositionFeeUsd;
                    _getGmxV2PositionManagerStorage().pendingPositionFeeUsd = 0;
                    executionCostAmount = (
                        executionCostInUsd < 0
                            ? pendingPositionFeeUsd
                            : uint256(executionCostInUsd) + pendingPositionFeeUsd
                    ) / collateralTokenPrice;
                    _wipeExecutionCostCalcInfo();
                }
                if (_getGmxV2PositionManagerStorage().status == Status.DECREASING) {
                    if (order.numbers.sizeDeltaInTokens > 0) {
                        IBasisStrategy(strategy()).afterDecreasePositionSize(
                            order.numbers.sizeDeltaInTokens, executionCostAmount, true
                        );
                    }
                    if (order.numbers.initialCollateralDeltaAmount > 0) {
                        IBasisStrategy(strategy()).afterDecreasePositionCollateral(
                            IERC20(collateralToken()).balanceOf(address(this)), true
                        );
                    }
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                    _getGmxV2PositionManagerStorage().status = Status.IDLE;
                } else {
                    if (order.numbers.sizeDeltaInTokens > 0) {
                        IBasisStrategy(strategy()).afterDecreasePositionSize(
                            order.numbers.sizeDeltaInTokens, executionCostAmount, true
                        );
                    }
                }
            }
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
        _wipeExecutionCostCalcInfo();

        if (_getGmxV2PositionManagerStorage().status == Status.KEEPING) {
            _getGmxV2PositionManagerStorage().status = Status.IDLE;
        } else {
            if (isIncrease) {
                if (_getGmxV2PositionManagerStorage().status == Status.INCREASING) {
                    if (order.numbers.initialCollateralDeltaAmount > 0) {
                        // increase collateral
                        _getGmxV2PositionManagerStorage().pendingCollateralAmount = 0;
                        IBasisStrategy(strategy()).afterIncreasePositionCollateral(0, false);
                    }
                    if (order.numbers.sizeDeltaInTokens > 0) {
                        IBasisStrategy(strategy()).afterIncreasePositionSize(0, false);
                    }
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                } else if (_getGmxV2PositionManagerStorage().status == Status.DEC_INC_SIZE) {
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                } else if (_getGmxV2PositionManagerStorage().status == Status.DEC_INC_COLLATERAL) {
                    IBasisStrategy(strategy()).afterDecreasePositionCollateral(0, false);
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                }
                _getGmxV2PositionManagerStorage().status = Status.IDLE;
            } else {
                if (_getGmxV2PositionManagerStorage().status == Status.DECREASING) {
                    if (order.numbers.sizeDeltaInTokens > 0) {
                        IBasisStrategy(strategy()).afterDecreasePositionSize(0, 0, false);
                    }
                    if (order.numbers.initialCollateralDeltaAmount > 0) {
                        IBasisStrategy(strategy()).afterDecreasePositionCollateral(0, false);
                    }
                    IBasisStrategy(strategy()).afterExecuteRequest(bytes32(0));
                    _getGmxV2PositionManagerStorage().status = Status.IDLE;
                } else {
                    IBasisStrategy(strategy()).afterDecreasePositionSize(0, 0, false);
                }
            }
        }
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

    /// @notice total asset token amount that can be claimable from gmx position when closing it
    ///
    /// @dev this amount includes the pending asset token amount and idle assets
    function positionNetBalance() public view returns (uint256) {
        address _factory = factory();
        uint256 positionNetAmount = GmxV2Lib.getPositionNetAmount(
            _getPositionParams(_factory), _getPricesParams(_factory), IBasisGmxFactory(_factory).referralStorage()
        );
        return positionNetAmount + IERC20(collateralToken()).balanceOf(address(this))
            + _getGmxV2PositionManagerStorage().pendingCollateralAmount;
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
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        bool settleNeeded = _checkSettle();
        (bool adjustNeeded,) = _checkAdjustPositionSize();
        upkeepNeeded = (settleNeeded || adjustNeeded) && !_isPending();
        performData = abi.encode(settleNeeded, adjustNeeded);
        return (upkeepNeeded, performData);
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
        return $.keeper;
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

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev create increase/decrease order
    function _createOrder(InternalCreateOrderParams memory params) private returns (bytes32) {
        (uint256 increaseExecutionFee, uint256 decreaseExecutionFee) = getExecutionFee();
        uint256 executionFee = params.isIncrease ? increaseExecutionFee : decreaseExecutionFee;
        IKeeper(keeper()).payGmxExecutionFee(params.exchangeRouter, params.orderVault, executionFee);
        address[] memory swapPath;
        bytes32 orderKey = IExchangeRouter(params.exchangeRouter).createOrder(
            IBaseOrderUtils.CreateOrderParams({
                addresses: IBaseOrderUtils.CreateOrderParamsAddresses({
                    receiver: address(this), // the receiver of reduced collateral
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    market: marketToken(),
                    initialCollateralToken: params.collateralToken,
                    swapPath: swapPath
                }),
                numbers: IBaseOrderUtils.CreateOrderParamsNumbers({
                    sizeDeltaUsd: params.sizeDeltaUsd,
                    initialCollateralDeltaAmount: params.collateralDelta, // The amount of tokens to withdraw for decrease orders
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
        isNeed = deviation > _getGmxV2PositionManagerStorage().maxHedgeDeviation;
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
        return _getGmxV2PositionManagerStorage().pendingIncreaseOrderKey != bytes32(0)
            || _getGmxV2PositionManagerStorage().pendingDecreaseOrderKey != bytes32(0);
    }

    /// @dev validate if the caller is OrderHandler of gmx
    function _validateOrderHandler(bytes32 orderKey, bool isIncrease) private view {
        if (
            msg.sender != IBasisGmxFactory(factory()).orderHandler()
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

    /// @dev called only when increasing and decreasing sizes
    function _recordExecutionCostCalcInfo(GmxV2Lib.GetPosition memory positionParams, uint256 spotExecutionPrice)
        private
    {
        _getGmxV2PositionManagerStorage().spotExecutionPrice = spotExecutionPrice;
        _getGmxV2PositionManagerStorage().sizeInTokensBefore = GmxV2Lib.getPositionSizeInTokens(positionParams);
    }

    function _wipeExecutionCostCalcInfo() private {
        _getGmxV2PositionManagerStorage().spotExecutionPrice = 0;
        _getGmxV2PositionManagerStorage().sizeInTokensBefore = 0;
    }
}
