// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {ForkTest} from "test/base/ForkTest.sol";
import {MockPriceFeed} from "test/mock/MockPriceFeed.sol";

import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";
import {StrategyConfig} from "src/StrategyConfig.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";

import {GmxHandler} from "./GmxHandler.sol";

contract GmxInvariants is StdInvariant, ForkTest {
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address forwarder = makeAddr("forwarder");

    address constant asset = USDC; // USDC
    address constant product = WETH; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0.01 ether;
    uint256 constant exitCost = 0.02 ether;
    bool constant isLong = false;
    uint256 constant targetLeverage = 3 ether;
    uint256 constant minLeverage = 2 ether;
    uint256 constant maxLeverage = 5 ether;
    uint256 constant safeMarginLeverage = 20 ether;

    uint256 constant MAX_DEPOSIT = 100_000_000 * 1e6;

    BasisStrategy strategy;
    LogarithmVault vault;

    GmxHandler handler;

    function setUp() public {
        _forkArbitrum(0);

        vm.startPrank(owner);
        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        LogarithmOracle oracle = LogarithmOracle(oracleProxy);
        vm.label(address(oracle), "oracle");

        // mock uniswap
        _mockUniswapPool(UNISWAPV3_WETH_USDC, oracleProxy);

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
        // _mockChainlinkPriceFeed(assetPriceFeed);
        address mockPriceFeed = address(new MockPriceFeed());

        (uint80 roundID, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IPriceFeed(assetPriceFeed).latestRoundData();
        uint8 decimals = IPriceFeed(assetPriceFeed).decimals();
        vm.etch(assetPriceFeed, mockPriceFeed.code);
        MockPriceFeed(assetPriceFeed).setOracleData(roundID, answer, startedAt, updatedAt, answeredInRound, decimals);

        // _mockChainlinkPriceFeed(productPriceFeed);
        (roundID, answer, startedAt, updatedAt, answeredInRound) = IPriceFeed(productPriceFeed).latestRoundData();
        decimals = IPriceFeed(productPriceFeed).decimals();
        vm.etch(productPriceFeed, mockPriceFeed.code);
        MockPriceFeed(productPriceFeed).setOracleData(roundID, answer, startedAt, updatedAt, answeredInRound, decimals);

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        address vaultImpl = address(new LogarithmVault());
        address vaultProxy = address(
            new ERC1967Proxy(
                vaultImpl,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector, owner, asset, entryCost, exitCost, "tt", "tt"
                )
            )
        );
        vault = LogarithmVault(vaultProxy);
        vm.label(address(vault), "vault");

        StrategyConfig config = new StrategyConfig();
        config.initialize(owner);

        // deploy strategy
        address strategyImpl = address(new BasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    address(config),
                    product,
                    address(vault),
                    oracle,
                    operator,
                    targetLeverage,
                    minLeverage,
                    maxLeverage,
                    safeMarginLeverage,
                    pathWeth
                )
            )
        );
        strategy = BasisStrategy(strategyProxy);
        strategy.setForwarder(forwarder);
        vm.label(address(strategy), "strategy");

        vault.setStrategy(address(strategy));
        vault.setDepositLimits(MAX_DEPOSIT, MAX_DEPOSIT);
        vm.stopPrank();

        handler = new GmxHandler(strategy, owner, operator, forwarder);

        targetContract(address(handler));
    }

    function invariant_sharePriceShouldBeAroundOne() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;
        uint256 sharePrice = Math.mulDiv(totalAssets, 1e6, totalSupply);
        assertApproxEqRel(sharePrice, 1e6, 0.01 ether, "share price");
    }

    function invariant_leverageShouldBeBetweenMinAndMaxWhenUpkeepNotNeeded() public view {
        (bool upkeepNeeded,) = strategy.checkUpkeep("");
        if (!upkeepNeeded) {
            uint256 currLeverage = IPositionManager(strategy.positionManager()).currentLeverage();
            assertTrue(currLeverage >= minLeverage, "minLeverage");
            assertTrue(currLeverage <= maxLeverage, "maxLeverage");
        }
    }

    function invariant_utilizationAmountsShouldBeExclusive() public view {
        (uint256 utilization, uint256 deutilization) = strategy.pendingUtilizations();
        assertFalse(utilization > 0 && deutilization > 0, "exclusive");
    }
}
