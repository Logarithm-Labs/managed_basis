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
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {MockStrategy} from "test/mock/MockStrategy.sol";

import {GmxV2PositionManager} from "src/position/gmx/GmxV2PositionManager.sol";
import {GmxConfig} from "src/position/gmx/GmxConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {GmxGasStation} from "src/position/gmx/GmxGasStation.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";

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
        _forkArbitrum(237215502);
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

        // deploy positionManager beacon
        address positionManagerBeacon = DeployHelper.deployBeacon(address(new GmxV2PositionManager()), owner);
        // deploy positionMnager beacon proxy
        address gmxPositionManagerProxy;
        // = address(
        //     new BeaconProxy(
        //         positionManagerBeacon,
        //         abi.encodeWithSelector(
        //             GmxV2PositionManager.initialize.selector,
        //             address(strategy),
        //             address(config),
        //             address(gmxGasStation),
        //             GMX_ETH_USDC_MARKET
        //         )
        //     )
        // );
        positionManager = GmxV2PositionManager(payable(gmxPositionManagerProxy));
        vm.label(address(positionManager), "positionManager");
        gmxGasStation.registerPositionManager(address(positionManager), true);
        vm.stopPrank();
    }

    modifier afterHavingPosition() {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 300 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        _;
    }

    function test_marketToken() public view {
        address marketToken = positionManager.marketToken();
        assertEq(marketToken, GMX_ETH_USDC_MARKET);
    }

    function test_indexToken() public view {
        address indexToken = positionManager.indexToken();
        assertEq(indexToken, product);
    }

    function test_longToken() public view {
        address longToken = positionManager.longToken();
        assertEq(longToken, product);
    }

    function test_shortToken() public view {
        address shortToken = positionManager.shortToken();
        assertEq(shortToken, asset);
    }

    function test_collateralToken() public view {
        address collateralToken = positionManager.collateralToken();
        assertEq(collateralToken, asset);
    }

    function test_adjustPosition_increasePosition() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 300 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(address(oracle));
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertEq(positionInfo.position.numbers.collateralAmount, 297644214);
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
    }

    function test_adjustPosition_increasePosition_lessThanIdleCollateral() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(address(oracle));
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertEq(positionInfo.position.numbers.collateralAmount, 297644214);
    }

    function test_revert_adjustPosition_increasePosition_biggerThanIdleCollateral() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        vm.expectRevert(Errors.NotEnoughCollateral.selector);
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 400 * USDC_PRECISION,
                isIncrease: true
            })
        );
    }

    function test_whenNotPending() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        vm.expectRevert(Errors.AlreadyPending.selector);
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );
    }

    function test_adjustPosition_decreasePositionSize() public afterHavingPosition {
        vm.startPrank(address(strategy));
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens - 0.5 ether
        );
    }

    function test_adjustPosition_afterIncreasePositionSize() public afterHavingPosition {
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: 0,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            strategy.sizeDeltaInTokens(),
            positionInfoAfter.position.numbers.sizeInTokens - positionInfoBefore.position.numbers.sizeInTokens
        );
    }

    function test_adjustPosition_afterIncreasePositionCollateral() public afterHavingPosition {
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 200 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: 200 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            strategy.collateralDelta(),
            positionInfoAfter.position.numbers.collateralAmount - positionInfoBefore.position.numbers.collateralAmount
        );
    }

    function test_adjustPosition_afterDecreasePositionSize() public afterHavingPosition {
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        assertEq(
            strategy.sizeDeltaInTokens(),
            positionInfoBefore.position.numbers.sizeInTokens - positionInfoAfter.position.numbers.sizeInTokens
        );
    }

    function test_positionNetBalance_withoutPositionOpened() public view {
        uint256 positionNetBalance = positionManager.positionNetBalance();
        assertEq(positionNetBalance, 0);
    }

    function test_positionNetBalance() public afterHavingPosition {
        uint256 positionNetBalance = positionManager.positionNetBalance();
        assertEq(positionNetBalance, 294599096);
    }

    function test_positionNetBalance_whenPending() public afterHavingPosition {
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 1 ether,
                collateralDeltaAmount: 0,
                isIncrease: true
            })
        );
        assertEq(positionManager.positionNetBalance(), positionNetBalanceBefore + 300 * USDC_PRECISION);
    }

    function test_adjustPosition_decreasePositionCollateral_whenPendingCollateralNotEngouh()
        public
        afterHavingPosition
    {
        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);

        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);

        uint256 collateralDelta = 200 * USDC_PRECISION;
        uint256 sizeDeltaInTokens = 0.25 ether;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 400 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 1001 / 1000);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd < 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
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
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        assertNotEq(IERC20(USDC).balanceOf(address(positionManager)), 0);
    }

    function test_adjustPosition_decreasePosition_whenDeltaCollateralIsBiggerThanRealizedPnl()
        public
        afterHavingPosition
    {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 300 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens + 0.5 ether,
            positionInfoBefore.position.numbers.sizeInTokens
        );
        assertEq(strategy.sizeDeltaInTokens(), 0.5 ether);
        // assertEq(IERC20(USDC).balanceOf(address(positionManager)), 0);
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.9999 ether);
        assertEq(collateralDelta, strategy.collateralDelta());
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
    }

    function test_adjustPosition_decreasePosition_whenNegativePnl() public afterHavingPosition {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 1001 / 1000);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd < 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 600 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
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
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 0.5 ether,
                collateralDeltaAmount: collateralDelta,
                isIncrease: false
            })
        );
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
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
        // assertEq(IERC20(USDC).balanceOf(address(positionManager)), 0);
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.9999 ether);
        assertEq(collateralDelta, strategy.collateralDelta());
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
    }

    function test_getClaimableFundingAmounts() public afterHavingPosition {
        _moveTimestampWithPriceFeed(3600);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 1, isIncrease: false})
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        (claimableLongAmount, claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter + 1 < positionNetBalanceBefore);
    }

    function test_claimFunding() public afterHavingPosition {
        _moveTimestampWithPriceFeed(24 * 3600);
        uint256 collateralBalanceBefore = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        uint256 productBalacneBefore = IERC20(positionManager.longToken()).balanceOf(address(strategy));
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        (uint256 accruedClaimableLongAmountBefore, uint256 accruedClaimableShortAmountBefore) =
            positionManager.getAccruedClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        address anyone = makeAddr("anyone");
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 1, isIncrease: false})
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        (uint256 accruedClaimableLongAmount, uint256 accruedClaimableShortAmount) =
            positionManager.getAccruedClaimableFundingAmounts();
        (uint256 claimableLongAmountAfter, uint256 claimableShortAmountAfter) =
            positionManager.getClaimableFundingAmounts();
        vm.startPrank(anyone);
        positionManager.claimFunding();
        (uint256 accruedClaimableLongAmountAfter, uint256 accruedClaimableShortAmountAfter) =
            positionManager.getAccruedClaimableFundingAmounts();
        assertTrue(claimableLongAmountAfter == 0);
        assertTrue(claimableShortAmountAfter == 0);
        assertTrue(accruedClaimableLongAmountBefore == 0);
        assertTrue(accruedClaimableShortAmountBefore == 0);
        assertTrue(accruedClaimableLongAmountAfter == 0);
        assertTrue(accruedClaimableShortAmountAfter == 0);
        uint256 collateralBalanceAfter = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        uint256 productBalacneAfter = IERC20(positionManager.longToken()).balanceOf(address(strategy));
        assertApproxEqRel(collateralBalanceAfter - collateralBalanceBefore, claimableShortAmount, 0.99999 ether);
        assertEq(productBalacneAfter - productBalacneBefore, claimableLongAmount);
        assertEq(collateralBalanceAfter - collateralBalanceBefore, accruedClaimableShortAmount);
        assertEq(productBalacneAfter - productBalacneBefore, accruedClaimableLongAmount);
    }

    function test_needKeep_idle() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 5 * USDC_PRECISION);
        vm.startPrank(address(owner));
        bool result = positionManager.needKeep();
        assertFalse(result);

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 10 * USDC_PRECISION);
        result = positionManager.needKeep();
        assertTrue(result);
    }

    function test_needKeep_funding() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(address(owner));
        GmxConfig(address(positionManager.config())).setMaxClaimableFundingShare(0.0001 ether);
        bool result = positionManager.needKeep();
        assertTrue(result);
    }

    function test_performUpkeep_keep_decreaseCollateral() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(address(owner));
        GmxConfig(address(positionManager.config())).setMaxClaimableFundingShare(0.0001 ether);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        bool result = positionManager.needKeep();
        assertTrue(result);
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        assertTrue(idleCollateralAmount == 0);
        vm.startPrank(address(strategy));
        positionManager.keep();
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter < positionNetBalanceBefore);
        assertApproxEqRel(idleCollateralAmount, claimableShortAmount, 0.99999 ether);
        (claimableLongAmount, claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
    }

    function test_performUpkeep_keep_increaseCollateral() public afterHavingPosition {
        _moveTimestampWithPriceFeed(2 * 24 * 3600);
        vm.startPrank(address(owner));
        GmxConfig(address(positionManager.config())).setMaxClaimableFundingShare(0.0001 ether);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        bool result = positionManager.needKeep();
        assertTrue(result);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        assertTrue(idleCollateralAmount == 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.keep();
        uint256 positionNetBalancePending = positionManager.positionNetBalance();
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter < positionNetBalanceBefore);
        assertTrue(positionNetBalanceBefore == positionNetBalancePending);
        idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        assertApproxEqRel(idleCollateralAmount, claimableShortAmount, 0.99999 ether);
        (claimableLongAmount, claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
    }

    function test_positionFee_decreasePosition() public afterHavingPosition {
        uint256 sizeDeltaInTokens = 0.25 ether;
        // int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        // _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        // assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        uint256 accumulatedPositionFeeBefore = positionManager.cumulativePositionFeeUsd();
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));

        uint256 accumulatedPositionFeeAfter = positionManager.cumulativePositionFeeUsd();
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo(address(oracle));
        // assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        uint256 accumulatedPositionFeeBefore = positionManager.cumulativePositionFeeUsd();
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDeltaInTokens,
                collateralDeltaAmount: 0,
                isIncrease: true
            })
        );
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo(address(oracle));

        uint256 accumulatedPositionFeeAfter = positionManager.cumulativePositionFeeUsd();
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
        IERC20(USDC).transfer(address(positionManager), 30_000_000 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: 10_000 ether,
                collateralDeltaAmount: 30_000_000 * USDC_PRECISION,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        (uint256 fundingFeeUsd, uint256 borrowingFeeUsd) = positionManager.cumulativeFundingAndBorrowingFeesUsd();
        assertEq(fundingFeeUsd, 0, "funding fee 0");
        assertEq(borrowingFeeUsd, 0, "borrowing fee 0");

        _moveTimestampWithPriceFeed(24 * 3600);
        (fundingFeeUsd, borrowingFeeUsd) = positionManager.cumulativeFundingAndBorrowingFeesUsd();
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(address(oracle));
        uint256 collateralTokenPrice = oracle.getAssetPrice(positionManager.collateralToken());

        assertEq(
            fundingFeeUsd, positionInfo.fees.funding.fundingFeeAmount * collateralTokenPrice, "funding fee is next one"
        );
        assertEq(borrowingFeeUsd, positionInfo.fees.borrowing.borrowingFeeUsd, "borrowing fee is next one");

        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 1, isIncrease: false})
        );
        bytes32 decreaseOrderKey = positionManager.pendingDecreaseOrderKey();
        _executeOrder(decreaseOrderKey);

        (uint256 fundingFeeUsdAfter, uint256 borrowingFeeUsdAfter) =
            positionManager.cumulativeFundingAndBorrowingFeesUsd();

        assertApproxEqRel(fundingFeeUsd, fundingFeeUsdAfter, 0.99999 ether, "funding fee not changed");
        assertEq(borrowingFeeUsd, borrowingFeeUsdAfter, "borrowing fee not changed");
        positionInfo = _getPositionInfo(address(oracle));
        assertEq(positionInfo.fees.funding.fundingFeeAmount, 0, "next funding fee 0");
        assertEq(positionInfo.fees.borrowing.borrowingFeeUsd, 0, "next borrowing fee 0");

        _moveTimestampWithPriceFeed(24 * 3600);
        (uint256 nextFundingFeeUsd, uint256 nextBorrowingFeeUsd) =
            positionManager.cumulativeFundingAndBorrowingFeesUsd();

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
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: type(uint256).max,
                collateralDeltaAmount: 0,
                isIncrease: false
            })
        );
        decreaseOrderKey = positionManager.pendingDecreaseOrderKey();
        _executeOrder(decreaseOrderKey);

        positionInfo = _getPositionInfo(address(oracle));
        assertEq(positionInfo.fees.funding.fundingFeeAmount, 0, "next funding fee 0");
        assertEq(positionInfo.fees.borrowing.borrowingFeeUsd, 0, "next borrowing fee 0");

        (uint256 nextFundingFeeUsdAfter, uint256 nextBorrowingFeeUsdAfter) =
            positionManager.cumulativeFundingAndBorrowingFeesUsd();

        assertApproxEqRel(nextFundingFeeUsd, nextFundingFeeUsdAfter, 0.99999 ether, "funding fee not changed");
        assertEq(nextBorrowingFeeUsd, nextBorrowingFeeUsdAfter, "borrowing fee not changed");
    }

    function test_maxGasCallback() public view {
        uint256 maxGas = IDataStore(GMX_DATA_STORE).getUint(Keys.MAX_CALLBACK_GAS_LIMIT);
        assertEq(maxGas, positionManager.config().callbackGasLimit());
    }

    function test_minSize() public {
        uint256 collateralDelta = USDC_PRECISION / 10;
        uint256 sizeDelta = oracle.convertTokenAmount(asset, product, collateralDelta);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), USDC_PRECISION / 10);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(
            IPositionManager.AdjustPositionPayload({
                sizeDeltaInTokens: sizeDelta,
                collateralDeltaAmount: collateralDelta,
                isIncrease: true
            })
        );
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        assertEq(positionManager.positionNetBalance(), collateralDelta);
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
