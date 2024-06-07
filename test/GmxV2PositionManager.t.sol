// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";

import {ArbGasInfoMock} from "./mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "./mock/ArbSysMock.sol";
import {MockFactory} from "./mock/MockFactory.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";

import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Keeper} from "src/Keeper.sol";
import {Errors} from "src/libraries/Errors.sol";

contract GmxV2PositionManagerTest is StdInvariant, Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");

    uint256 constant USD_PRECISION = 1e30;
    uint256 constant USDC_PRECISION = 1e6;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address constant gmxKeeper = 0xE47b36382DC50b90bCF6176Ddb159C4b9333A7AB;
    address constant gmxController = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;

    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0.01 ether;
    uint256 constant exitCost = 0.02 ether;
    bool constant isLong = false;

    uint256 constant targetLeverage = 3 ether;

    GmxV2PositionManager positionManager;
    ManagedBasisStrategy strategy;
    LogarithmOracle oracle;
    Keeper keeper;
    address factory;
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

        factory = address(new MockFactory(oracleProxy));
        vm.stopPrank();

        vm.startPrank(factory);
        // deploy keeper
        address keeperImpl = address(new Keeper());
        address keeperProxy =
            address(new ERC1967Proxy(keeperImpl, abi.encodeWithSelector(Keeper.initialize.selector, address(factory))));
        keeper = Keeper(payable(keeperProxy));

        // deploy strategy
        address strategyImpl = address(new ManagedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    ManagedBasisStrategy.initialize.selector, asset, product, owner, oracle, entryCost, exitCost, isLong
                )
            )
        );
        strategy = ManagedBasisStrategy(strategyProxy);

        // deploy positionManager
        address positionManagerImpl = address(new GmxV2PositionManager());
        address positionManagerProxy = address(
            new ERC1967Proxy(
                positionManagerImpl, abi.encodeWithSelector(GmxV2PositionManager.initialize.selector, address(strategy))
            )
        );
        positionManager = GmxV2PositionManager(payable(positionManagerProxy));
        positionManager.setKeeper(address(keeper));
        keeper.registerPositionManager(address(positionManager));
        strategy.setPositionManager(positionManagerProxy);
        vm.stopPrank();

        // trnasfer usdc to strategy assuming there are funds deposited
        vm.startPrank(usdcWhale);
        IERC20(USDC).transfer(address(strategy), 100000 * (10 ** IERC20(USDC).decimals()));

        // topup strategy with some native token, in practice, its don't through keeper
        vm.deal(address(keeper), 1 ether);
        vm.stopPrank();
        (increaseFee, decreaseFee) = positionManager.getExecutionFee();
        assert(increaseFee > 0);
        assert(decreaseFee > 0);
    }

    modifier afterOrderCreated() {
        vm.startPrank(address(strategy));
        positionManager.increasePositionCollateral(300 * USDC_PRECISION);
        positionManager.increasePositionSize(1 ether, 0);
        vm.stopPrank();
        _;
    }

    modifier afterHavingPosition() {
        vm.startPrank(address(strategy));
        positionManager.increasePositionCollateral(300 * USDC_PRECISION);
        bytes32 orderKey = positionManager.increasePositionSize(1 ether, 0);
        vm.startPrank(gmxKeeper);
        _executeOrder(orderKey);
        _;
    }

    function test_marketToken() public view {
        address marketToken = positionManager.marketToken();
        assertEq(marketToken, MockFactory(factory).marketKey(asset, product));
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

    function test_increasePosition_creatOrder() public {
        vm.startPrank(address(strategy));
        positionManager.increasePositionCollateral(300 * USDC_PRECISION);
        bytes32 orderKey = positionManager.increasePositionSize(1 ether, 0);
        assertTrue(orderKey != bytes32(0));
    }

    function test_increasePositionCollateral_revert_whenCallingFromOtherThanStrategy() public {
        address anyone = makeAddr("anyone");
        vm.deal(anyone, 1 ether);
        vm.expectRevert(Errors.CallerNotStrategy.selector);
        vm.startPrank(anyone);
        positionManager.increasePositionCollateral(300 * USDC_PRECISION);
    }

    function test_increasePosition_executeOrder() public {
        uint256 usdcBalanceOfStartegyBefore = IERC20(USDC).balanceOf(address(strategy));
        vm.startPrank(address(strategy));
        positionManager.increasePositionCollateral(300 * USDC_PRECISION);
        bytes32 orderKey = positionManager.increasePositionSize(1 ether, 0);
        vm.startPrank(gmxKeeper);
        _executeOrder(orderKey);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo();
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1 ether, 0.99999 ether);
        assertEq(positionInfo.position.numbers.collateralAmount, 297826210);
        uint256 usdcBalanceOfStartegyAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(usdcBalanceOfStartegyBefore - usdcBalanceOfStartegyAfter, 300 * USDC_PRECISION);
    }

    // function test_increasePosition_cancelOrder() public {
    //     uint256 usdcBalanceOfStartegyBefore = IERC20(USDC).balanceOf(address(strategy));
    //     vm.startPrank(address(strategy));
    //     positionManager.increasePositionCollateral(300 * USDC_PRECISION);
    //     bytes32 orderKey = positionManager.increasePositionSize(1 ether, 0);
    //     assertEq(usdcBalanceOfStartegyBefore - 300 * USDC_PRECISION, IERC20(USDC).balanceOf(address(strategy)));
    //     vm.startPrank(gmxKeeper);
    //     _executeOrder(orderKey);
    //     uint256 usdcBalanceOfStartegyAfter = IERC20(USDC).balanceOf(address(strategy));
    //     assertEq(usdcBalanceOfStartegyBefore, usdcBalanceOfStartegyAfter);
    // }

    // function test_increasePosition_revert_createOrder() public afterOrderCreated {
    //     vm.startPrank(address(strategy));
    //     vm.expectRevert(Errors.AlreadyPending.selector);
    //     positionManager.increasePositionCollateral(300 * USDC_PRECISION);
    //     bytes32 orderKey = positionManager.increasePositionSize(1 ether, 0);
    // }

    // function test_decreasePosition_creatOrder() public afterHavingPosition {
    //     vm.startPrank(address(strategy));
    //     bytes32 orderKey = positionManager.decreasePosition{}(100 * USDC_PRECISION, 0.7 ether);
    //     assertTrue(orderKey != bytes32(0));
    // }

    // function test_decreasePosition_revert_creatOrder() public afterHavingPosition {
    //     vm.startPrank(address(strategy));
    //     bytes32 orderKey = positionManager.decreasePosition{}(100 * USDC_PRECISION, 0.7 ether);
    //     assertTrue(orderKey != bytes32(0));
    //     vm.expectRevert(Errors.AlreadyPending.selector);
    //     positionManager.decreasePosition{}(100 * USDC_PRECISION, 0.7 ether);
    // }

    // function test_decreasePosition_executeOrder() public afterHavingPosition {
    //     uint256 usdcBalanceOfStartegyBefore = IERC20(USDC).balanceOf(address(strategy));
    //     ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
    //     vm.startPrank(address(strategy));
    //     bytes32 orderKey = positionManager.decreasePosition{}(100 * USDC_PRECISION, 0.5 ether);
    //     _executeOrder(orderKey);
    //     ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo();
    //     assertEq(
    //         positionInfo.position.numbers.sizeInTokens, positionInfoBefore.position.numbers.sizeInTokens - 0.5 ether
    //     );
    //     assertEq(positionInfo.position.numbers.collateralAmount, 196411004);
    //     uint256 usdcBalanceOfStartegyAfter = IERC20(USDC).balanceOf(address(strategy));
    //     assertEq(usdcBalanceOfStartegyBefore + 100 * USDC_PRECISION, usdcBalanceOfStartegyAfter);
    // }

    function test_totalAssets() public afterHavingPosition {
        uint256 totalAssets = positionManager.totalAssets();
        assertEq(totalAssets, 294995464);
    }

    // function test_totalAssets_whenPending() public afterHavingPosition {
    //     uint256 totalAssetsBefore = positionManager.totalAssets();
    //     vm.startPrank(address(strategy));
    //     positionManager.increasePosition(300 * USDC_PRECISION, 1 ether);
    //     assertEq(positionManager.totalAssets(), totalAssetsBefore + 300 * USDC_PRECISION);
    // }

    // function test_totalAssets_afterExecution() public afterHavingPosition {
    //     vm.startPrank(address(strategy));
    //     bytes32 orderKey = positionManager.increasePosition(300 * USDC_PRECISION, 1 ether);
    //     _executeOrder(orderKey);
    //     assertEq(positionManager.totalAssets(), 589989774);
    // }

    function test_decreasePositionCollateral_createOrders() public afterHavingPosition {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        vm.startPrank(address(strategy));
        positionManager.decreasePositionCollateral(200 * USDC_PRECISION);
    }

    function test_decreasePositionCollateral_whenInitCollateralEngouh() public afterHavingPosition {
        uint256 collateralDelta = 200 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 totalAssetsBefore = positionManager.totalAssets();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        (bytes32 increaseKey, bytes32 decreaseKey) = positionManager.decreasePositionCollateral(collateralDelta);
        _executeOrder(decreaseKey);
        _executeOrder(increaseKey);
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        uint256 totalAssetsAfter = positionManager.totalAssets();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        assertEq(positionInfoAfter.position.numbers.sizeInUsd, positionInfoBefore.position.numbers.sizeInUsd);
        assertEq(positionInfoAfter.position.numbers.sizeInTokens, positionInfoBefore.position.numbers.sizeInTokens);
        assertEq(
            positionInfoAfter.position.numbers.collateralAmount,
            positionInfoBefore.position.numbers.collateralAmount - collateralDelta
        );
        assertEq(positionInfoAfter.pnlAfterPriceImpactUsd, positionInfoBefore.pnlAfterPriceImpactUsd);
        assertEq(totalAssetsAfter, totalAssetsBefore - collateralDelta);
        assertEq(strategyBalanceAfter, strategyBalanceBefore + collateralDelta);
    }

    function test_decreasePositionCollateral_whenInitialCollateralNotSufficient() public afterHavingPosition {
        uint256 collateralDelta = 300 * USDC_PRECISION;
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 9 / 10);
        ReaderUtils.PositionInfo memory positionInfoBefore = _getPositionInfo();
        uint256 totalAssetsBefore = positionManager.totalAssets();
        uint256 strategyBalanceBefore = IERC20(USDC).balanceOf(address(strategy));
        console.log("-------before-------");
        console.log("size in usd", positionInfoBefore.position.numbers.sizeInUsd);
        console.log("size in token", positionInfoBefore.position.numbers.sizeInTokens);
        console.log("collateral", positionInfoBefore.position.numbers.collateralAmount);
        console.log("pnl", uint256(positionInfoBefore.pnlAfterPriceImpactUsd));
        console.log("total asssets", totalAssetsBefore);
        console.log("balance", strategyBalanceBefore);
        assertTrue(positionInfoBefore.pnlAfterPriceImpactUsd > 0);
        vm.startPrank(address(strategy));
        (bytes32 decreaseKey, bytes32 increaseKey) = positionManager.decreasePositionCollateral(collateralDelta);
        _executeOrder(decreaseKey);
        _executeOrder(increaseKey);
        ReaderUtils.PositionInfo memory positionInfoAfter = _getPositionInfo();
        uint256 totalAssetsAfter = positionManager.totalAssets();
        uint256 strategyBalanceAfter = IERC20(USDC).balanceOf(address(strategy));
        console.log("-------after-------");
        console.log("size in usd", positionInfoAfter.position.numbers.sizeInUsd);
        console.log("size in token", positionInfoAfter.position.numbers.sizeInTokens);
        console.log("collateral", positionInfoAfter.position.numbers.collateralAmount);
        console.log("pnl", uint256(positionInfoAfter.pnlAfterPriceImpactUsd));
        console.log("total asssets", totalAssetsAfter);
        console.log("balance", strategyBalanceAfter);
        // assertEq(positionInfoAfter.position.numbers.sizeInUsd, positionInfoBefore.position.numbers.sizeInUsd);
        // assertEq(positionInfoAfter.position.numbers.sizeInTokens, positionInfoBefore.position.numbers.sizeInTokens);
        // assertEq(
        //     positionInfoAfter.position.numbers.collateralAmount,
        //     positionInfoBefore.position.numbers.collateralAmount - collateralDelta
        // );
        // assertEq(positionInfoAfter.pnlAfterPriceImpactUsd, positionInfoBefore.pnlAfterPriceImpactUsd);
        // assertEq(totalAssetsAfter, totalAssetsBefore - collateralDelta);
        // assertEq(strategyBalanceAfter, strategyBalanceBefore + collateralDelta);
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
            vm.startPrank(gmxKeeper);
            IOrderHandler(MockFactory(factory).orderHandler()).executeOrder(key, oracleParams);
        }
    }

    function _getPositionInfo() internal view returns (ReaderUtils.PositionInfo memory) {
        return GmxV2Lib.getPositionInfo(
            GmxV2Lib.GetPosition({
                dataStore: MockFactory(factory).dataStore(),
                reader: MockFactory(factory).reader(),
                marketToken: positionManager.marketToken(),
                account: address(positionManager),
                collateralToken: positionManager.collateralToken(),
                isLong: positionManager.isLong()
            }),
            GmxV2Lib.GetPrices({
                market: Market.Props({
                    marketToken: positionManager.marketToken(),
                    indexToken: positionManager.indexToken(),
                    longToken: positionManager.longToken(),
                    shortToken: positionManager.shortToken()
                }),
                oracle: address(oracle)
            }),
            MockFactory(factory).referralStorage()
        );
    }
}
