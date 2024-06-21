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
import {MockStrategy} from "./mock/MockStrategy.sol";

import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Keeper} from "src/Keeper.sol";
import {Errors} from "src/libraries/Errors.sol";

contract KeeperTest is StdInvariant, Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address forwarder = makeAddr("forwarder");

    uint256 constant USD_PRECISION = 1e30;
    uint256 constant USDC_PRECISION = 1e6;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address constant wethWhale = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
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
    MockStrategy strategy;
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
        keeper.setForwarderAddress(forwarder);

        strategy = new MockStrategy();

        // deploy positionManager
        address positionManagerImpl = address(new GmxV2PositionManager());
        address positionManagerProxy = address(
            new ERC1967Proxy(
                positionManagerImpl,
                abi.encodeWithSelector(GmxV2PositionManager.initialize.selector, address(strategy), address(keeper))
            )
        );
        positionManager = GmxV2PositionManager(payable(positionManagerProxy));
        keeper.registerPositionManager(address(positionManager));
        strategy.setPositionManager(positionManagerProxy);
        vm.stopPrank();

        // topup strategy with some native token, in practice, its don't through keeper
        vm.deal(address(keeper), 1 ether);
        vm.stopPrank();
        (increaseFee, decreaseFee) = positionManager.getExecutionFee();
        assert(increaseFee > 0);
        assert(decreaseFee > 0);
    }

    modifier afterHavingPosition() {
        vm.startPrank(usdcWhale);
        IERC20(USDC).transfer(address(positionManager), 300 * USDC_PRECISION);
        vm.startPrank(address(strategy));
        positionManager.adjustPosition(1 ether, 0, 300 * USDC_PRECISION, true);
        bytes32 increaseOrderKey = positionManager.pendingIncreaseOrderKey();
        _executeOrder(increaseOrderKey);
        _;
    }

    function test_checkUpkeep() public afterHavingPosition {
        vm.startPrank(wethWhale);
        IERC20(product).transfer(address(strategy), 1.5 ether);
        (bool upkeepNeeded,) = keeper.checkUpkeep(abi.encode(address(positionManager)));
        assertTrue(upkeepNeeded);
    }

    function test_performUpkeep() public afterHavingPosition {
        vm.startPrank(wethWhale);
        IERC20(product).transfer(address(strategy), 1.5 ether);
        (bool upkeepNeeded, bytes memory data) = keeper.checkUpkeep(abi.encode(address(positionManager)));
        assertTrue(upkeepNeeded);
        vm.startPrank(forwarder);
        keeper.performUpkeep(data);
        assertTrue(positionManager.pendingIncreaseOrderKey() != bytes32(0));
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo();
        assertApproxEqRel(positionInfo.position.numbers.sizeInTokens, 1.5 ether, 0.999999 ether);
    }

    function test_performUpkeep_revert() public afterHavingPosition {
        vm.startPrank(wethWhale);
        IERC20(product).transfer(address(strategy), 1.5 ether);
        (bool upkeepNeeded, bytes memory data) = keeper.checkUpkeep(abi.encode(address(positionManager)));
        assertTrue(upkeepNeeded);
        vm.startPrank(makeAddr("anyone"));
        vm.expectRevert(Errors.UnAuthorizedForwarder.selector);
        keeper.performUpkeep(data);
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
            vm.startPrank(gmxKeeper);
            IOrderHandler(MockFactory(factory).orderHandler()).executeOrder(key, oracleParams);
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
                dataStore: MockFactory(factory).dataStore(),
                reader: MockFactory(factory).reader(),
                account: address(positionManager),
                collateralToken: positionManager.collateralToken(),
                isLong: positionManager.isLong()
            }),
            address(oracle),
            MockFactory(factory).referralStorage()
        );
    }
}
