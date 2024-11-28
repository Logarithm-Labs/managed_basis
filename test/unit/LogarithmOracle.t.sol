// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/oracle/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArbSysMock} from "test/mock/ArbSysMock.sol";
import {ArbGasInfoMock} from "test/mock/ArbGasInfoMock.sol";
import {MockPriceFeed} from "test/mock/MockPriceFeed.sol";

import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";

contract LogarithmOracleTest is Test {
    LogarithmOracle public oracle;

    address owner = makeAddr("owner");

    address constant asset = ArbiAddresses.USDC; // USDC
    address constant product = ArbiAddresses.WETH; // WETH
    address constant assetPriceFeed = ArbiAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbiAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed

    address constant gmxDogeVirtualAsset = 0xC4da4c24fd591125c3F47b340b6f4f76111883d8;

    function setUp() public {
        _forkArbitrum();
        vm.startPrank(owner);
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

    function test_getAssetPrice() public view {
        uint256 assetPrice = oracle.getAssetPrice(asset);
        console.log("assetPrice: ", assetPrice);

        uint256 productPrice = oracle.getAssetPrice(product);
        console.log("productPrice: ", productPrice);
    }

    function test_convertTokenAmount() public view {
        uint256 assetAmount = 10_000 * 1e6;
        uint256 productAmount = oracle.convertTokenAmount(asset, product, assetAmount);
        console.log("productAmount: ", productAmount);
    }

    function test_setPriceFeeds_decimals() public {
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        uint8[] memory decimals = new uint8[](1);
        assets[0] = gmxDogeVirtualAsset;
        feeds[0] = assetPriceFeed;
        decimals[0] = uint8(8);
        oracle.setPriceFeeds(assets, feeds);
        assertEq(oracle.assetDecimals(gmxDogeVirtualAsset), 0);
        oracle.setAssetDecimals(assets, decimals);
        assertEq(oracle.assetDecimals(gmxDogeVirtualAsset), 8);
    }
}
