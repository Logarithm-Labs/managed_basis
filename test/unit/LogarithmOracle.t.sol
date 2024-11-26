// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ArbSysMock} from "test/mock/ArbSysMock.sol";
import {ArbGasInfoMock} from "test/mock/ArbGasInfoMock.sol";
import {MockPriceFeed} from "test/mock/MockPriceFeed.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {ForkTest} from "test/base/ForkTest.sol";

contract LogarithmOracleTest is ForkTest {
    LogarithmOracle public oracle;

    address owner = makeAddr("owner");

    address constant asset = ArbiAddresses.USDC; // USDC
    address constant product = ArbiAddresses.WETH; // WETH
    address constant assetPriceFeed = ArbiAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbiAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed

    function setUp() public {
        _forkArbitrum(0);
        vm.startPrank(owner);
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
}
