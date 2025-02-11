// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {ChainlinkFeedWrapper, ICustomPriceFeed} from "src/oracle/ChainlinkFeedWrapper.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArbSysMock} from "test/mock/ArbSysMock.sol";
import {ArbGasInfoMock} from "test/mock/ArbGasInfoMock.sol";
import {MockPriceFeed} from "test/mock/MockPriceFeed.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {ForkTest} from "test/base/ForkTest.sol";

contract LogarithmOracleTest is ForkTest {
    LogarithmOracle public oracle;

    address owner = makeAddr("owner");

    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.WETH; // WETH
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed

    address constant gmxDogeVirtualAsset = 0xC4da4c24fd591125c3F47b340b6f4f76111883d8;

    function setUp() public {
        _forkArbitrum(0);
        vm.startPrank(owner);
        oracle = DeployHelper.deployLogarithmOracle(owner);

        // set oracle price feed
        address[] memory assets = new address[](3);
        address[] memory feeds = new address[](3);
        uint256[] memory heartbeats = new uint256[](3);
        assets[0] = asset;
        assets[1] = product;
        assets[2] = gmxDogeVirtualAsset;
        feeds[0] = assetPriceFeed;
        feeds[1] = productPriceFeed;
        feeds[2] = productPriceFeed;
        heartbeats[0] = 24 * 3600;
        heartbeats[1] = 24 * 3600;
        heartbeats[2] = 24 * 3600;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
    }

    function test_getAssetPrice() public view {
        uint256 assetPrice = oracle.getAssetPrice(asset);
        console.log("assetPrice: ", assetPrice);

        uint256 productPrice = oracle.getAssetPrice(product);
        console.log("productPrice: ", productPrice);
    }

    function test_getPriceFromCustom() public view {
        ICustomPriceFeed.RoundData memory data =
            ICustomPriceFeed(ArbAddresses.CUSTOM_VIRTUAL_USD_PRICE_FEED).latestRoundData();
        console.logInt(data.price);
    }

    function test_convertTokenAmount() public view {
        uint256 assetAmount = 10_000 * 1e6;
        uint256 productAmount = oracle.convertTokenAmount(asset, product, assetAmount);
        console.log("productAmount: ", productAmount);
    }

    function test_getAssetPrice_withEOA() public {
        address[] memory assets = new address[](1);
        uint8[] memory decimals = new uint8[](1);
        assets[0] = gmxDogeVirtualAsset;
        decimals[0] = 8;
        vm.startPrank(owner);
        oracle.setAssetDecimals(assets, decimals);
        assertEq(oracle.assetDecimals(gmxDogeVirtualAsset), 8);
        uint256 productPrice = oracle.getAssetPrice(gmxDogeVirtualAsset);
        console.log("productPrice: ", productPrice);
    }

    function test_getAssetPrice_revert() public {
        vm.expectRevert();
        oracle.getAssetPrice(gmxDogeVirtualAsset);
    }
}
