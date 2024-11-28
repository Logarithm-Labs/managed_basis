// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {GmxV2Test} from "test/base/GmxV2Test.sol";

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderPositionUtils} from "src/externals/gmx-v2/libraries/ReaderPositionUtils.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {MockStrategy} from "test/mock/MockStrategy.sol";

import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {GmxGasStation} from "src/hedge/gmx/GmxGasStation.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";

import {DeployHelper} from "script/utils/DeployHelper.sol";

contract GmxV2PositionManagerTest is GmxV2Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");

    uint256 constant USD_PRECISION = 1e30;

    address constant asset = USDC; // USDC
    address constant product = WETH; // WETH
    address constant assetPriceFeed = CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0.01 ether;
    uint256 constant exitCost = 0.02 ether;
    bool constant isLong = false;

    uint256 constant targetLeverage = 3 ether;

    MockStrategy strategy;
    LogarithmOracle oracle;
    GmxGasStation gmxGasStation;

    function setUp() public {
        _forkArbitrum(0);
        vm.startPrank(owner);
        // deploy oracle
        oracle = DeployHelper.deployLogarithmOracle(owner);

        // set oracle price feed
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);
        uint256[] memory heartbeats = new uint256[](2);
        assets[0] = asset;
        assets[1] = product;
        feeds[0] = assetPriceFeed;
        feeds[1] = productPriceFeed;
        heartbeats[0] = 24 * 3600;
        heartbeats[1] = 24 * 3600;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        _mockChainlinkPriceFeed(assetPriceFeed);
        _mockChainlinkPriceFeed(productPriceFeed);

        strategy = new MockStrategy(address(oracle));

        // deploy config
        GmxConfig config = DeployHelper.deployGmxConfig(owner);
        vm.label(address(config), "config");

        // deploy gmxGasStation
        gmxGasStation = DeployHelper.deployGmxGasStation(owner);
        vm.label(address(gmxGasStation), "gmxGasStation");

        // topup gmxGasStation with some native token, in practice, its don't through gmxGasStation
        vm.deal(address(gmxGasStation), 10000 ether);

        // deploy hedgeManager beacon
        address hedgeManagerBeacon = DeployHelper.deployBeacon(address(new GmxV2PositionManager()), owner);
        // deploy positionMnager beacon proxy
        address gmxPositionManagerProxy = address(
            new BeaconProxy(
                hedgeManagerBeacon,
                abi.encodeWithSelector(
                    GmxV2PositionManager.initialize.selector,
                    address(strategy),
                    address(config),
                    address(gmxGasStation),
                    GMX_ETH_USDC_MARKET
                )
            )
        );
        hedgeManager = GmxV2PositionManager(payable(gmxPositionManagerProxy));
        vm.label(address(hedgeManager), "hedgeManager");
        gmxGasStation.registerPositionManager(address(hedgeManager), true);
        vm.stopPrank();
    }

    modifier afterHavingPosition() {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 300 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        _;
    }

    function test_marketToken() public view {
        address marketToken = hedgeManager.marketToken();
        assertEq(marketToken, GMX_ETH_USDC_MARKET);
    }

    function test_indexToken() public view {
        address indexToken = hedgeManager.indexToken();
        assertEq(indexToken, product);
    }

    function test_longToken() public view {
        address longToken = hedgeManager.longToken();
        assertEq(longToken, product);
    }

    function test_shortToken() public view {
        address shortToken = hedgeManager.shortToken();
        assertEq(shortToken, asset);
    }

    function test_collateralToken() public view {
        address collateralToken = hedgeManager.collateralToken();
        assertEq(collateralToken, asset);
    }

    function test_adjustPosition_increasePosition() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 300 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderPositionUtils.PositionInfo memory positionInfo = _getPositionInfo(address(oracle));
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertApproxEqRel(positionInfo.position.numbers.collateralAmount, 300 * USDC_PRECISION, 0.9 ether);
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
    }

    function test_adjustPosition_increasePosition_lessThanIdleCollateral() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderPositionUtils.PositionInfo memory positionInfo = _getPositionInfo(address(oracle));
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertApproxEqRel(positionInfo.position.numbers.collateralAmount, 300 * USDC_PRECISION, 0.9 ether);
    }

    function test_revert_adjustPosition_increasePosition_biggerThanIdleCollateral() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        vm.expectRevert(Errors.NotEnoughCollateral.selector);
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 400 * USDC_PRECISION,
                isIncrease: true
            })
        );
    }

    function test_whenNotPending() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        vm.expectRevert(Errors.AlreadyPending.selector);
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );
    }

    function test_adjustPosition_decreasePositionSize() public afterHavingPosition {
        vm.startPrank(address(strategy));
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens - 0.5 ether
        );
    }

    function test_adjustPosition_afterIncreasePositionSize() public afterHavingPosition {
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: 0,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            strategy.sizeDeltaInTokens(),
            positionInfoAfter.position.numbers.sizeInTokens - positionInfoBefore.position.numbers.sizeInTokens
        );
    }

    function test_adjustPosition_afterIncreasePositionCollateral() public afterHavingPosition {
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 200 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            strategy.collateralDelta(),
            positionInfoAfter.position.numbers.collateralAmount - positionInfoBefore.position.numbers.collateralAmount
        );
    }

    function test_adjustPosition_afterDecreasePositionSize() public afterHavingPosition {
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            strategy.sizeDeltaInTokens(),
            positionInfoBefore.position.numbers.sizeInTokens - positionInfoAfter.position.numbers.sizeInTokens
        );
    }

    function test_positionNetBalance_withoutPositionOpened() public view {
        uint256 positionNetBalance = hedgeManager.positionNetBalance();
        assertEq(positionNetBalance, 0);
    }

    function test_positionNetBalance() public afterHavingPosition {
        uint256 positionNetBalance = hedgeManager.positionNetBalance();
        assertGt(positionNetBalance, 0);
    }

    function test_positionNetBalance_whenPending() public afterHavingPosition {
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({sizeDeltaInTokens: 1 ether, collateralDeltaAmount: 0, isIncrease: true})
        );
        assertEq(hedgeManager.positionNetBalance(), positionNetBalanceBefore + 300 * USDC_PRECISION);
    }

    function test_adjustPosition_decreasePositionCollateral_whenPendingCollateralNotEngouh()
        public
        afterHavingPosition
    {
        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);

        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(positionInfoAfter.position.numbers.sizeInUsd, positionInfoBefore.position.numbers.sizeInUsd);
        assertEq(positionInfoAfter.position.numbers.sizeInTokens, positionInfoBefore.position.numbers.sizeInTokens);
        assertEq(
            positionInfoAfter.position.numbers.collateralAmount,
            positionInfoBefore.position.numbers.collateralAmount - 100 * USDC_PRECISION
        );
        assertEq(positionInfoAfter.pnlAfterPriceImpactUsd, positionInfoBefore.pnlAfterPriceImpactUsd);
        assertEq(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta);
        assertEq(strategyBalanceAfter, strategyBalanceBefore + collateralDelta);
        assertEq(collateralDelta, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePositionCollateralAndSize_whenPositivePnl() public afterHavingPosition {
        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);

        uint256 collateralDelta = 200 * USDC_PRECISION;
        uint256 sizeDeltaInTokens = 0.25 ether;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens - sizeDeltaInTokens,
            "positionSizeInTokens"
        );
        assertEq(strategy.collateralDelta(), collateralDelta);
    }

    function test_adjustPosition_decreasePositionCollateral_whenInitCollateralEngouh() public afterHavingPosition {
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(positionInfoAfter.position.numbers.sizeInUsd, positionInfoBefore.position.numbers.sizeInUsd);
        assertEq(positionInfoAfter.position.numbers.sizeInTokens, positionInfoBefore.position.numbers.sizeInTokens);
        assertEq(
            positionInfoAfter.position.numbers.collateralAmount,
            positionInfoBefore.position.numbers.collateralAmount - collateralDelta
        );
        assertEq(positionInfoAfter.pnlAfterPriceImpactUsd, positionInfoBefore.pnlAfterPriceImpactUsd);
        assertEq(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta);
        assertEq(strategyBalanceAfter, strategyBalanceBefore + collateralDelta);
        assertEq(collateralDelta, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePositionCollateral_whenInitCollateralNotEnough() public afterHavingPosition {
        uint256 collateralDelta = 300 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertApproxEqRel(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens,
            0.999999 ether
        );
        assertTrue(
            positionInfoAfter.position.numbers.collateralAmount < positionInfoBefore.position.numbers.collateralAmount
        );
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.99 ether);
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
        assertEq(collateralDelta, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePositionCollateral_whenInitCollateralNotEnoughWithIdle()
        public
        afterHavingPosition
    {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 400 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertApproxEqRel(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens,
            0.999999 ether
        );
        assertTrue(
            positionInfoAfter.position.numbers.collateralAmount < positionInfoBefore.position.numbers.collateralAmount
        );
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.99 ether);
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
        assertEq(collateralDelta, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePositionCollateral_whenNegativePnl() public afterHavingPosition {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 1001 / 1000);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd < 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));

        assertEq(positionInfoAfter.position.numbers.sizeInTokens, positionInfoBefore.position.numbers.sizeInTokens);
        assertEq(
            positionInfoBefore.position.numbers.collateralAmount - positionInfoAfter.position.numbers.collateralAmount,
            100 * USDC_PRECISION
        );
        assertEq(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta);
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
        assertEq(collateralDelta, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePosition_whenDeltaCollateralIsSmallerThanRealizedPnl()
        public
        afterHavingPosition
    {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        console.log("-------before-------");
        console.log("size in usd", positionInfoBefore.position.numbers.sizeInUsd);
        console.log("size in token", positionInfoBefore.position.numbers.sizeInTokens);
        console.log("collateral", positionInfoBefore.position.numbers.collateralAmount);
        console.log("pnl", uint256(positionInfoBefore.pnlAfterPriceImpactUsd));
        console.log("total asssets", positionNetBalanceBefore);
        console.log("balance", strategyBalanceBefore);
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        console.log("-------after-------");
        console.log("size in usd", positionInfoAfter.position.numbers.sizeInUsd);
        console.log("size in token", positionInfoAfter.position.numbers.sizeInTokens);
        console.log("collateral", positionInfoAfter.position.numbers.collateralAmount);
        console.log("pnl", uint256(positionInfoAfter.pnlAfterPriceImpactUsd));
        console.log("total asssets", positionNetBalanceAfter);
        console.log("balance", strategyBalanceAfter);
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens + 0.5 ether,
            positionInfoBefore.position.numbers.sizeInTokens
        );
        assertEq(strategy.sizeDeltaInTokens(), 0.5 ether);
        assertEq(
            positionInfoAfter.position.numbers.collateralAmount, positionInfoBefore.position.numbers.collateralAmount
        );
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.9999 ether);
        assertEq(collateralDelta, strategy.collateralDelta());
        assertNotEq(IERC20(USDC).balanceOf(address(hedgeManager)), 0);
    }

    function test_adjustPosition_decreasePosition_whenDeltaCollateralIsBiggerThanRealizedPnl()
        public
        afterHavingPosition
    {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 300 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens + 0.5 ether,
            positionInfoBefore.position.numbers.sizeInTokens
        );
        assertEq(strategy.sizeDeltaInTokens(), 0.5 ether);
        // assertEq(IERC20(USDC).balanceOf(address(hedgeManager)), 0);
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.9999 ether);
        assertEq(collateralDelta, strategy.collateralDelta());
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePosition_whenNegativePnl() public afterHavingPosition {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 1001 / 1000);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd < 0);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens - 0.5 ether
        );
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.99999 ether);
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
        assertEq(collateralDelta, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePosition_whenDeltaCollateralIsBiggerThanRealizedPnlAndInitCallateral()
        public
        afterHavingPosition
    {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 600 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        console.log("-------before-------");
        console.log("size in usd", positionInfoBefore.position.numbers.sizeInUsd);
        console.log("size in token", positionInfoBefore.position.numbers.sizeInTokens);
        console.log("collateral", positionInfoBefore.position.numbers.collateralAmount);
        console.log("pnl", uint256(positionInfoBefore.pnlAfterPriceImpactUsd));
        console.log("total asssets", positionNetBalanceBefore);
        console.log("balance", strategyBalanceBefore);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        console.log("-------after-------");
        console.log("size in usd", positionInfoAfter.position.numbers.sizeInUsd);
        console.log("size in token", positionInfoAfter.position.numbers.sizeInTokens);
        console.log("collateral", positionInfoAfter.position.numbers.collateralAmount);
        console.log("pnl", uint256(positionInfoAfter.pnlAfterPriceImpactUsd));
        console.log("total asssets", positionNetBalanceAfter);
        console.log("balance", strategyBalanceAfter);
        assertApproxEqRel(
            positionInfoAfter.position.numbers.sizeInTokens + 0.5 ether,
            positionInfoBefore.position.numbers.sizeInTokens,
            0.99999 ether
        );
        assertApproxEqRel(strategy.sizeDeltaInTokens(), 0.5 ether, 0.99999 ether);
        // assertEq(IERC20(USDC).balanceOf(address(hedgeManager)), 0);
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.9999 ether);
        assertEq(collateralDelta, strategy.collateralDelta());
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
    }

    function test_getClaimableFundingAmounts() public afterHavingPosition {
        _moveTimestampWithPriceFeed(3600);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 1, isIncrease: false})
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        (claimableLongAmount, claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        console.log("balance before", positionNetBalanceBefore);
        console.log("balance after", positionNetBalanceAfter);
    }

    function test_claimFunding() public afterHavingPosition {
        _moveTimestampWithPriceFeed(24 * 3600);
        uint256 collateralBalanceBefore = IERC20(hedgeManager.collateralToken()).balanceOf(address(hedgeManager));
        uint256 productBalacneBefore = IERC20(hedgeManager.longToken()).balanceOf(address(strategy));
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        (uint256 accruedClaimableLongAmountBefore, uint256 accruedClaimableShortAmountBefore) =
            hedgeManager.getAccruedClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        address anyone = makeAddr("anyone");
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 1, isIncrease: false})
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        (uint256 accruedClaimableLongAmount, uint256 accruedClaimableShortAmount) =
            hedgeManager.getAccruedClaimableFundingAmounts();
        (uint256 claimableLongAmountAfter, uint256 claimableShortAmountAfter) =
            hedgeManager.getClaimableFundingAmounts();
        vm.startPrank(anyone);
        hedgeManager.claimFunding();
        (uint256 accruedClaimableLongAmountAfter, uint256 accruedClaimableShortAmountAfter) =
            hedgeManager.getAccruedClaimableFundingAmounts();
        assertTrue(claimableLongAmountAfter == 0);
        assertTrue(claimableShortAmountAfter == 0);
        assertTrue(accruedClaimableLongAmountBefore == 0);
        assertTrue(accruedClaimableShortAmountBefore == 0);
        assertTrue(accruedClaimableLongAmountAfter == 0);
        assertTrue(accruedClaimableShortAmountAfter == 0);
        uint256 collateralBalanceAfter = IERC20(hedgeManager.collateralToken()).balanceOf(address(hedgeManager));
        uint256 productBalacneAfter = IERC20(hedgeManager.longToken()).balanceOf(address(strategy));
        assertApproxEqRel(collateralBalanceAfter - collateralBalanceBefore, claimableShortAmount, 0.99999 ether);
        assertEq(productBalacneAfter - productBalacneBefore, claimableLongAmount);
        assertEq(collateralBalanceAfter - collateralBalanceBefore, accruedClaimableShortAmount);
        assertEq(productBalacneAfter - productBalacneBefore, accruedClaimableLongAmount);
    }

    function test_needKeep_idle() public afterHavingPosition {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 5 * USDC_PRECISION);
        vm.startPrank(address(owner));
        bool result = hedgeManager.needKeep();
        assertFalse(result);

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 10 * USDC_PRECISION);
        result = hedgeManager.needKeep();
        assertTrue(result);
    }

    function test_needKeep_funding() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(address(owner));
        GmxConfig(address(hedgeManager.config())).setMaxClaimableFundingShare(0.0001 ether);
        bool result = hedgeManager.needKeep();
        assertTrue(result);
    }

    function test_performUpkeep_keep_decreaseCollateral() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(address(owner));
        GmxConfig(address(hedgeManager.config())).setMaxClaimableFundingShare(0.0001 ether);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        bool result = hedgeManager.needKeep();
        assertTrue(result);
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 idleCollateralAmount = IERC20(hedgeManager.collateralToken()).balanceOf(address(hedgeManager));
        assertTrue(idleCollateralAmount == 0);
        vm.startPrank(address(strategy));
        hedgeManager.keep();
        assertNotEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        assertEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        idleCollateralAmount = IERC20(hedgeManager.collateralToken()).balanceOf(address(hedgeManager));
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter < positionNetBalanceBefore);
        assertApproxEqRel(idleCollateralAmount, claimableShortAmount, 0.99999 ether);
        (claimableLongAmount, claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
    }

    function test_performUpkeep_keep_increaseCollateral() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(address(owner));
        GmxConfig(address(hedgeManager.config())).setMaxClaimableFundingShare(0.0001 ether);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        bool result = hedgeManager.needKeep();
        assertTrue(result);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 300 * USDC_PRECISION);
        uint256 positionNetBalanceBefore = hedgeManager.positionNetBalance();
        uint256 idleCollateralAmount = IERC20(hedgeManager.collateralToken()).balanceOf(address(hedgeManager));
        assertTrue(idleCollateralAmount == 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.keep();
        uint256 positionNetBalancePending = hedgeManager.positionNetBalance();
        assertNotEq(hedgeManager.pendingIncreaseOrderKey(), bytes32(0));
        assertEq(hedgeManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        uint256 positionNetBalanceAfter = hedgeManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter < positionNetBalanceBefore);
        assertTrue(positionNetBalanceBefore == positionNetBalancePending);
        idleCollateralAmount = IERC20(hedgeManager.collateralToken()).balanceOf(address(hedgeManager));
        assertApproxEqRel(idleCollateralAmount, claimableShortAmount, 0.99999 ether);
        (claimableLongAmount, claimableShortAmount) = hedgeManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
    }

    function test_positionFee_decreasePosition() public afterHavingPosition {
        uint256 sizeDeltaInTokens = 0.25 ether;
        // int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        // _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        // assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        uint256 accumulatedPositionFeeBefore = hedgeManager.cumulativePositionFeeUsd();
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));

        uint256 accumulatedPositionFeeAfter = hedgeManager.cumulativePositionFeeUsd();
        uint256 sizeDeltaUsd =
            positionInfoBefore.position.numbers.sizeInUsd - positionInfoAfter.position.numbers.sizeInUsd;

        uint256 deltaFee = accumulatedPositionFeeAfter - accumulatedPositionFeeBefore;
        (uint256 positiveFactor,) = _getPositionFeeFactors();
        // uint256 expectedFeeForNeg = Precision.applyFactor(sizeDeltaUsd, negativeFactor);
        uint256 expectedFeeForPos = Precision.applyFactor(sizeDeltaUsd, positiveFactor);

        assertEq(deltaFee, expectedFeeForPos);
    }

    function test_positionFee_IncreasePosition() public afterHavingPosition {
        uint256 sizeDeltaInTokens = 0.1 ether;
        // int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        // _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderPositionUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        // assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        uint256 accumulatedPositionFeeBefore = hedgeManager.cumulativePositionFeeUsd();
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: 0,
                isIncrease: true
            })
        );
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
        ReaderPositionUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));

        uint256 accumulatedPositionFeeAfter = hedgeManager.cumulativePositionFeeUsd();
        uint256 sizeDeltaUsd =
            positionInfoAfter.position.numbers.sizeInUsd - positionInfoBefore.position.numbers.sizeInUsd;

        uint256 deltaFee = accumulatedPositionFeeAfter - accumulatedPositionFeeBefore;
        (, uint256 negativeFactor) = _getPositionFeeFactors();
        uint256 expectedFeeForNeg = Precision.applyFactor(sizeDeltaUsd, negativeFactor);
        // uint256 expectedFeeForPos = Precision.applyFactor(sizeDeltaUsd, positiveFactor);

        assertEq(deltaFee, expectedFeeForNeg);
    }

    function test_fundingAndBorrowingFees() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), 30_000_000 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: 10 ether,
                collateralDeltaAmount: 30_000 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        (uint256 fundingFeeUsd, uint256 borrowingFeeUsd) = hedgeManager.cumulativeFundingAndBorrowingFeesUsd();
        assertEq(fundingFeeUsd, 0, "funding fee 0");
        assertEq(borrowingFeeUsd, 0, "borrowing fee 0");

        _moveTimestampWithPriceFeed(24 * 3600);
        (fundingFeeUsd, borrowingFeeUsd) = hedgeManager.cumulativeFundingAndBorrowingFeesUsd();
        ReaderPositionUtils.PositionInfo memory positionInfo = _getPositionInfo(address(oracle));
        uint256 collateralTokenPrice = oracle.getAssetPrice(hedgeManager.collateralToken());

        assertEq(
            fundingFeeUsd, positionInfo.fees.funding.fundingFeeAmount * collateralTokenPrice, "funding fee is next one"
        );
        assertEq(borrowingFeeUsd, positionInfo.fees.borrowing.borrowingFeeUsd, "borrowing fee is next one");

        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 1, isIncrease: false})
        );
        bytes32 decreaseOrderKey = hedgeManager.pendingDecreaseOrderKey();
        _executeOrder(decreaseOrderKey);

        (uint256 fundingFeeUsdAfter, uint256 borrowingFeeUsdAfter) = hedgeManager.cumulativeFundingAndBorrowingFeesUsd();

        assertApproxEqRel(fundingFeeUsd, fundingFeeUsdAfter, 0.99999 ether, "funding fee not changed");
        assertEq(borrowingFeeUsd, borrowingFeeUsdAfter, "borrowing fee not changed");
        positionInfo = _getPositionInfo(address(oracle));
        assertEq(positionInfo.fees.funding.fundingFeeAmount, 0, "next funding fee 0");
        assertEq(positionInfo.fees.borrowing.borrowingFeeUsd, 0, "next borrowing fee 0");

        _moveTimestampWithPriceFeed(24 * 3600);
        (uint256 nextFundingFeeUsd, uint256 nextBorrowingFeeUsd) = hedgeManager.cumulativeFundingAndBorrowingFeesUsd();

        positionInfo = _getPositionInfo(address(oracle));
        assertEq(
            nextFundingFeeUsd,
            fundingFeeUsdAfter + positionInfo.fees.funding.fundingFeeAmount * collateralTokenPrice,
            "funding fee is next one"
        );
        assertEq(
            nextBorrowingFeeUsd,
            borrowingFeeUsdAfter + positionInfo.fees.borrowing.borrowingFeeUsd,
            "borrowing fee is next one"
        );

        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: type(uint256).max,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        decreaseOrderKey = hedgeManager.pendingDecreaseOrderKey();
        _executeOrder(decreaseOrderKey);

        positionInfo = _getPositionInfo(address(oracle));
        assertEq(positionInfo.fees.funding.fundingFeeAmount, 0, "next funding fee 0");
        assertEq(positionInfo.fees.borrowing.borrowingFeeUsd, 0, "next borrowing fee 0");

        (uint256 nextFundingFeeUsdAfter, uint256 nextBorrowingFeeUsdAfter) =
            hedgeManager.cumulativeFundingAndBorrowingFeesUsd();

        assertApproxEqRel(nextFundingFeeUsd, nextFundingFeeUsdAfter, 0.99999 ether, "funding fee not changed");
        assertEq(nextBorrowingFeeUsd, nextBorrowingFeeUsdAfter, "borrowing fee not changed");
    }

    function test_maxGasCallback() public view {
        uint256 maxGas = IDataStore(GMX_DATA_STORE).getUint(Keys.MAX_CALLBACK_GAS_LIMIT);
        assertEq(maxGas, hedgeManager.config().callbackGasLimit());
    }

    function test_minSize() public {
        uint256 collateralDelta = USDC_PRECISION / 10;
        uint256 sizeDelta = oracle.convertTokenAmount(asset, product, collateralDelta);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(hedgeManager), USDC_PRECISION / 10);
        vm.startPrank(address(strategy));
        hedgeManager.adjustPosition(
            IHedgeManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDelta,
                collateralDeltaAmount: collateralDelta,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = hedgeManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        assertEq(hedgeManager.positionNetBalance(), collateralDelta);
    }

    function test_getPosition() public afterHavingPosition {
        console.log("sizeInUsd", _getPositionInfo(address(oracle)).position.numbers.sizeInUsd);
    }

    function _moveTimestampWithPriceFeed(uint256 deltaTime) internal {
        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = assetPriceFeed;
        priceFeeds[1] = productPriceFeed;
        _moveTimestamp(deltaTime, priceFeeds);
    }

    function _getPositionFeeFactors() internal view returns (uint256 positiveFactor, uint256 negativeFactor) {
        positiveFactor = IDataStore(GMX_DATA_STORE).getUint(Keys.positionFeeFactorKey(GMX_ETH_USDC_MARKET, true));
        negativeFactor = IDataStore(GMX_DATA_STORE).getUint(Keys.positionFeeFactorKey(GMX_ETH_USDC_MARKET, false));
    }
}
