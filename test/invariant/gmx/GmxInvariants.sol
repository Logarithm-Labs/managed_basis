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

import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {SpotManager} from "src/spot/SpotManager.sol";

import {GmxHandler} from "./GmxHandler.sol";

contract GmxInvariants is StdInvariant, ForkTest {
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address forwarder = makeAddr("forwarder");

    address constant asset = USDC; // USDC
    address constant product = WETH; // WETH
    address constant assetPriceFeed = CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
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
        _mockUniswapPool(UNI_V3_POOL_WETH_USDC, oracleProxy);

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
        pathWeth[1] = UNI_V3_POOL_WETH_USDC;
        pathWeth[2] = WETH;

        address vaultImpl = address(new LogarithmVault());
        address vaultProxy = address(
            new ERC1967Proxy(
                vaultImpl,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector, owner, asset, address(0), entryCost, exitCost, "tt", "tt"
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
                    safeMarginLeverage
                )
            )
        );
        strategy = BasisStrategy(strategyProxy);
        // strategy.setForwarder(forwarder);
        vm.label(address(strategy), "strategy");

        // deploy spot manager
        address spotManagerImpl = address(new SpotManager());
        address spotManagerProxy = address(
            new ERC1967Proxy(
                spotManagerImpl,
                abi.encodeWithSelector(SpotManager.initialize.selector, owner, address(strategy), pathWeth)
            )
        );
        SpotManager spotManager = SpotManager(spotManagerProxy);
        vm.label(address(spotManager), "spotManager");
        strategy.setSpotManager(address(spotManager));

        vault.setStrategy(address(strategy));
        vault.setDepositLimits(MAX_DEPOSIT, MAX_DEPOSIT);
        vm.stopPrank();

        handler = new GmxHandler(strategy, owner, operator, forwarder);

        targetContract(address(handler));
    }

    function invariant_leverageShouldBeBetweenMinAndMaxWhenUpkeepNotNeeded() public view {
        (bool upkeepNeeded,) = strategy.checkUpkeep("");
        IHedgeManager hedgeManager = IHedgeManager(strategy.hedgeManager());
        uint256 sizeInTokens = hedgeManager.positionSizeInTokens();
        uint256 positionBalance = hedgeManager.positionNetBalance();
        BasisStrategy.StrategyStatus status = strategy.strategyStatus();
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        if (
            !upkeepNeeded && sizeInTokens != 0 && status == BasisStrategy.StrategyStatus.IDLE
                && pendingDeutilization == 0 && positionBalance != 0
        ) {
            uint256 currLeverage = hedgeManager.currentLeverage();
            assertTrue(currLeverage >= minLeverage, "minLeverage");
            assertTrue(currLeverage <= maxLeverage, "maxLeverage");
        }
    }

    function invariant_utilizationAmountsShouldBeExclusive() public view {
        (uint256 utilization, uint256 deutilization) = strategy.pendingUtilizations();
        assertFalse(utilization > 0 && deutilization > 0, "exclusive");
    }
}
