// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";

import {ArbGasInfoMock} from "./mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "./mock/ArbSysMock.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";
import {MockStrategy} from "./mock/MockStrategy.sol";

import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {Config} from "src/Config.sol";
import {ConfigKeys} from "src/libraries/ConfigKeys.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Keeper} from "src/Keeper.sol";
import {Errors} from "src/libraries/Errors.sol";

contract GmxV2PositionManagerTest is StdInvariant, Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");

    uint256 constant USD_PRECISION = 1e30;
    uint256 constant USDC_PRECISION = 1e6;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant USDC_WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address constant WETH_WHALE = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant GMX_KEEPER = 0xE47b36382DC50b90bCF6176Ddb159C4b9333A7AB;
    address constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_EXCHANGE_ROUTER = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;
    address constant GMX_ORDER_HANDLER = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;
    address constant GMX_ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address constant GMX_READER = 0xdA5A70c885187DaA71E7553ca9F728464af8d2ad;
    address constant GMX_ETH_USDC_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0.01 ether;
    uint256 constant exitCost = 0.02 ether;
    bool constant isLong = false;

    uint256 constant targetLeverage = 3 ether;

    GmxV2PositionManager positionManager;
    MockStrategy strategy;
    LogarithmOracle oracle;
    Keeper keeper;
    uint256 increaseFee;
    uint256 decreaseFee;

    function setUp() public {
        _forkArbitrum();
        vm.startPrank(owner);
        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        oracle = LogarithmOracle(oracleProxy);

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

        // deploy config
        Config config = new Config();
        config.initialize(owner);

        config.setAddress(ConfigKeys.GMX_EXCHANGE_ROUTER, GMX_EXCHANGE_ROUTER);
        config.setAddress(ConfigKeys.GMX_DATA_STORE, GMX_DATA_STORE);
        config.setAddress(ConfigKeys.GMX_ORDER_HANDLER, GMX_ORDER_HANDLER);
        config.setAddress(ConfigKeys.GMX_ORDER_VAULT, GMX_ORDER_VAULT);
        config.setAddress(ConfigKeys.GMX_REFERRAL_STORAGE, IOrderHandler(GMX_ORDER_HANDLER).referralStorage());
        config.setAddress(ConfigKeys.GMX_READER, GMX_READER);
        config.setAddress(ConfigKeys.ORACLE, address(oracle));

        config.setAddress(ConfigKeys.gmxMarketKey(asset, product), GMX_ETH_USDC_MARKET);

        config.setUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT, 2_000_000);

        strategy = new MockStrategy();

        // deploy keeper
        address keeperImpl = address(new Keeper());
        address keeperProxy = address(
            new ERC1967Proxy(keeperImpl, abi.encodeWithSelector(Keeper.initialize.selector, owner, address(config)))
        );
        keeper = Keeper(payable(keeperProxy));

        config.setAddress(ConfigKeys.KEEPER, address(keeper));

        // deploy positionManager impl
        address positionManagerImpl = address(new GmxV2PositionManager());
        // deploy positionManager beacon
        address positionManagerBeacon = address(new UpgradeableBeacon(positionManagerImpl, owner));
        // deploy positionMnager beacon proxy
        address positionManagerProxy = address(
            new BeaconProxy(
                positionManagerBeacon,
                abi.encodeWithSelector(
                    GmxV2PositionManager.initialize.selector, owner, address(strategy), address(config)
                )
            )
        );
        positionManager = GmxV2PositionManager(payable(positionManagerProxy));

        strategy.setPositionManager(positionManagerProxy);

        config.setBool(ConfigKeys.isPositionManagerKey(address(positionManager)), true);

        // topup keeper with some native token, in practice, its don't through keeper
        vm.deal(address(keeper), 1 ether);
        vm.stopPrank();
        (increaseFee, decreaseFee) = positionManager.getExecutionFee();
        assert(increaseFee > 0);
        assert(decreaseFee > 0);
    }

    modifier afterHavingPosition() {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(1 ether, 300 * USDC_PRECISION, true);
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
        positionManager.adjustPosition(1 ether, 300 * USDC_PRECISION, true);
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo();
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertEq(positionInfo.position.numbers.collateralAmount, 297826210);
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
    }

    function test_adjustPosition_increasePosition_lessThanIdleCollateral() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(1 ether, 200 * USDC_PRECISION, true);
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo();
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertEq(positionInfo.position.numbers.collateralAmount, 297826210);
    }

    function test_revert_adjustPosition_increasePosition_biggerThanIdleCollateral() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        vm.expectRevert(Errors.NotEnoughCollateral.selector);
        positionManager.adjustPosition(1 ether, 400 * USDC_PRECISION, true);
    }

    function test_whenNotPending() public {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(1 ether, 200 * USDC_PRECISION, true);

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        vm.expectRevert(Errors.AlreadyPending.selector);
        positionManager.adjustPosition(1 ether, 200 * USDC_PRECISION, true);
    }

    function test_adjustPosition_decreasePositionSize() public afterHavingPosition {
        vm.startPrank(address(strategy));
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        positionManager.adjustPosition(0.5 ether, 0, false);
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens - 0.5 ether
        );
    }

    function test_adjustPosition_afterIncreasePositionSize() public afterHavingPosition {
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0.5 ether, 0, true);
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        assertEq(
            strategy.sizeDeltaInTokens(),
            positionInfoAfter.position.numbers.sizeInTokens - positionInfoBefore.position.numbers.sizeInTokens
        );
    }

    function test_adjustPosition_afterIncreasePositionCollateral() public afterHavingPosition {
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 200 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, 200 * USDC_PRECISION, true);
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        assertEq(
            strategy.collateralDelta(),
            positionInfoAfter.position.numbers.collateralAmount - positionInfoBefore.position.numbers.collateralAmount
        );
    }

    function test_adjustPosition_afterDecreasePositionSize() public afterHavingPosition {
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0.5 ether, 0, false);
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        assertEq(
            strategy.sizeDeltaInTokens(),
            positionInfoBefore.position.numbers.sizeInTokens - positionInfoAfter.position.numbers.sizeInTokens
        );
    }

    function test_positionNetBalance() public afterHavingPosition {
        uint256 positionNetBalance = positionManager.positionNetBalance();
        assertEq(positionNetBalance, 294995464);
    }

    function test_positionNetBalance_whenPending() public afterHavingPosition {
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(1 ether, 0, true);
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, collateralDelta, false);
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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

    function test_adjustPosition_decreasePositionCollateral_whenInitCollateralEngouh() public afterHavingPosition {
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, collateralDelta, false);
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, collateralDelta, false);
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        assertApproxEqRel(collateralDelta, strategy.collateralDelta(), 0.99999 ether);
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, collateralDelta, false);
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        assertApproxEqRel(collateralDelta, strategy.collateralDelta(), 0.99999 ether);
    }

    function test_adjustPosition_decreasePositionCollateral_whenNegativePnl() public afterHavingPosition {
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 100 * USDC_PRECISION);
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 1001 / 1000);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd < 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, collateralDelta, false);
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
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
        positionManager.adjustPosition(0.5 ether, collateralDelta, false);
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        assertApproxEqRel(collateralDelta, strategy.collateralDelta(), 0.99999 ether);
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0.5 ether, collateralDelta, false);
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd < 0);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0.5 ether, collateralDelta, false);
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(
            positionInfoAfter.position.numbers.sizeInTokens,
            positionInfoBefore.position.numbers.sizeInTokens - 0.5 ether
        );
        assertApproxEqRel(positionNetBalanceAfter, positionNetBalanceBefore - collateralDelta, 0.99999 ether);
        assertEq(strategyBalanceAfter - strategyBalanceBefore, strategy.collateralDelta());
        assertApproxEqRel(collateralDelta, strategy.collateralDelta(), 0.99999 ether);
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
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
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
        positionManager.adjustPosition(0.5 ether, collateralDelta, false);
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
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
        _moveTimestamp(3600);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, 1, false);
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        (claimableLongAmount, claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter + 1 == positionNetBalanceBefore);
    }

    function test_claimFunding() public afterHavingPosition {
        _moveTimestamp(24 * 3600);
        uint256 collateralBalanceBefore = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        uint256 productBalacneBefore = IERC20(positionManager.longToken()).balanceOf(address(strategy));
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        address anyone = makeAddr("anyone");
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(0, 1, false);
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        vm.startPrank(anyone);
        positionManager.claimFunding();
        (uint256 claimableLongAmountAfter, uint256 claimableShortAmountAfter) =
            positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmountAfter == 0);
        assertTrue(claimableShortAmountAfter == 0);
        uint256 collateralBalanceAfter = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        uint256 productBalacneAfter = IERC20(positionManager.longToken()).balanceOf(address(strategy));
        assertApproxEqRel(collateralBalanceAfter - collateralBalanceBefore, claimableShortAmount, 0.99999 ether);
        assertEq(productBalacneAfter - productBalacneBefore, claimableLongAmount);
    }

    function test_checkSettle_idle() public afterHavingPosition {
        _moveTimestamp(2 * 24 * 3600);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 5 * USDC_PRECISION);
        vm.startPrank(address(owner));
        bool result = positionManager.checkSettle();
        assertFalse(result);

        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 10 * USDC_PRECISION);
        result = positionManager.checkSettle();
        assertTrue(result);
    }

    function test_checkSettle_funding() public afterHavingPosition {
        _moveTimestamp(2 * 24 * 3600);
        vm.startPrank(address(owner));
        positionManager.setMaxClaimableFundingShare(0.0001 ether);
        bool result = positionManager.checkSettle();
        assertTrue(result);
    }

    function test_performUpkeep_settle_decreaseCollateral() public afterHavingPosition {
        _moveTimestamp(2 * 24 * 3600);
        vm.startPrank(address(owner));
        positionManager.setMaxClaimableFundingShare(0.0001 ether);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        bool result = positionManager.checkSettle();
        assertTrue(result);
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        assertTrue(idleCollateralAmount == 0);
        vm.startPrank(address(strategy));
        positionManager.settle();
        assertNotEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        assertEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter > positionNetBalanceBefore);
        assertApproxEqRel(idleCollateralAmount, claimableShortAmount, 0.99999 ether);
        (claimableLongAmount, claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
    }

    function test_performUpkeep_settle_increaseCollateral() public afterHavingPosition {
        _moveTimestamp(2 * 24 * 3600);
        vm.startPrank(address(owner));
        positionManager.setMaxClaimableFundingShare(0.0001 ether);
        (uint256 claimableLongAmount, uint256 claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount > 0);
        assertTrue(claimableShortAmount > 0);
        bool result = positionManager.checkSettle();
        assertTrue(result);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        uint256 positionNetBalanceBefore = positionManager.positionNetBalance();
        uint256 idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        assertTrue(idleCollateralAmount == 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.settle();
        uint256 positionNetBalancePending = positionManager.positionNetBalance();
        assertNotEq(positionManager.pendingIncreaseOrderKey(), bytes32(0));
        assertEq(positionManager.pendingDecreaseOrderKey(), bytes32(0));
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        uint256 positionNetBalanceAfter = positionManager.positionNetBalance();
        assertTrue(positionNetBalanceAfter > positionNetBalanceBefore);
        assertTrue(positionNetBalanceBefore == positionNetBalancePending);
        idleCollateralAmount = IERC20(positionManager.collateralToken()).balanceOf(address(positionManager));
        assertApproxEqRel(idleCollateralAmount, claimableShortAmount, 0.99999 ether);
        (claimableLongAmount, claimableShortAmount) = positionManager.getClaimableFundingAmounts();
        assertTrue(claimableLongAmount == 0);
        assertTrue(claimableShortAmount == 0);
    }

    function _forkArbitrum() internal {
        uint256 arbitrumFork = vm.createFork(vm.rpcUrl("arbitrum_one"));
        vm.selectFork(arbitrumFork);
        vm.rollFork(213168025);

        // L2 contracts explicitly reference 0x64 for the ArbSys precompile
        // and 0x6C for the ArbGasInfo precompile
        // We'll replace it with the mock
        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);
    }

    function _mockChainlinkPriceFeed(address priceFeed) internal {
        (uint80 roundID, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IPriceFeed(priceFeed).latestRoundData();
        uint8 decimals = IPriceFeed(priceFeed).decimals();
        address mockPriceFeed = address(new MockPriceFeed());
        vm.etch(priceFeed, mockPriceFeed.code);
        MockPriceFeed(priceFeed).setOracleData(roundID, answer, startedAt, updatedAt, answeredInRound, decimals);
    }

    function _mockChainlinkPriceFeedAnswer(address priceFeed, int256 answer) internal {
        MockPriceFeed(priceFeed).updatePrice(answer);
    }

    function _moveTimestamp(uint256 deltaTime) internal {
        uint256 targetTimestamp = vm.getBlockTimestamp() + deltaTime;
        vm.warp(targetTimestamp);
        MockPriceFeed(assetPriceFeed).setUpdatedAt(targetTimestamp);
        MockPriceFeed(productPriceFeed).setUpdatedAt(targetTimestamp);
    }

    function _executeOrder(bytes32 key) internal {
        if (key != bytes32(0)) {
            IOrderHandler.SetPricesParams memory oracleParams;
            address indexToken = positionManager.indexToken();
            address longToken = positionManager.longToken();
            address shortToken = positionManager.shortToken();
            if (indexToken == longToken) {
                address[] memory tokens = new address[](2);
                tokens[0] = indexToken;
                tokens[1] = shortToken;
                oracleParams.priceFeedTokens = tokens;
            } else {
                address[] memory tokens = new address[](3);
                tokens[0] = indexToken;
                tokens[1] = longToken;
                tokens[2] = shortToken;
                oracleParams.priceFeedTokens = tokens;
            }
            vm.startPrank(GMX_KEEPER);
            IOrderHandler(0x352f684ab9e97a6321a13CF03A61316B681D9fD2).executeOrder(key, oracleParams);
        }
    }

    function _getPositionInfo() internal view returns (ReaderUtils.PositionInfo memory) {
        return GmxV2Lib.getPositionInfo(
            GmxV2Lib.GmxParams({
                market: Market.Props({
                    marketToken: positionManager.marketToken(),
                    indexToken: positionManager.indexToken(),
                    longToken: positionManager.longToken(),
                    shortToken: positionManager.shortToken()
                }),
                dataStore: GMX_DATA_STORE,
                reader: GMX_READER,
                account: address(positionManager),
                collateralToken: positionManager.collateralToken(),
                isLong: positionManager.isLong()
            }),
            address(oracle),
            IOrderHandler(GMX_ORDER_HANDLER).referralStorage()
        );
    }
}
