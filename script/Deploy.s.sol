// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {DataProvider} from "src/DataProvider.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant UNISWAPV3_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    bool constant isLong = false;

    uint256 constant entryCost = 0.005 ether; // 0.5% entry fee
    uint256 constant exitCost = 0.005 ether; // 0.5% exit fee

    uint256 constant targetLeverage = 6 ether; // 6x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 12 ether; // 12x leverage
    uint256 constant safeMarginLeverage = 20 ether; // 20x leverage

    uint256 constant increaseSizeMin = 15 * 1e6;
    uint256 constant increaseSizeMax = type(uint256).max;
    uint256 constant decreaseSizeMin = 15 * 1e6;
    uint256 constant decreaseSizeMax = type(uint256).max;

    uint256 constant increaseCollateralMin = 5 * 1e6;
    uint256 constant increaseCollateralMax = type(uint256).max;
    uint256 constant decreaseCollateralMin = 10 * 1e6;
    uint256 constant decreaseCollateralMax = type(uint256).max;
    uint256 constant limitDecreaseCollateral = 50 * 1e6;

    function run() public {
        vm.startBroadcast();
        // deploy LogarithmOracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        LogarithmOracle oracle = LogarithmOracle(oracleProxy);
        address oracleOwner = oracle.owner();
        require(oracleOwner == owner, "Oracle owner is not the expected owner");

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

        console.log("Oracle deployed at", address(oracle));

        // deploy LogarithmVault
        address vaultImpl = address(new LogarithmVault());
        address vaultProxy = address(
            new ERC1967Proxy(
                vaultImpl,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector, owner, asset, entryCost, exitCost, "tt", "tt"
                )
            )
        );
        LogarithmVault vault = LogarithmVault(vaultProxy);
        require(vault.owner() == owner, "Vault owner is not the expected owner");

        console.log("Vault deployed at", address(vault));

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        // deploy BasisStrategy
        address strategyImpl = address(new BasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
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

        BasisStrategy strategy = BasisStrategy(strategyProxy);
        require(strategy.owner() == owner, "Strategy owner is not the expected owner");
        console.log("Strategy deployed at", address(strategy));

        // deploy OffChainPositionManager
        address positionManagerImpl = address(new OffChainPositionManager());
        address positionManagerProxy = address(
            new ERC1967Proxy(
                positionManagerImpl,
                abi.encodeWithSelector(
                    OffChainPositionManager.initialize.selector,
                    address(strategy),
                    agent,
                    address(oracle),
                    product,
                    asset,
                    false
                )
            )
        );
        OffChainPositionManager positionManager = OffChainPositionManager(positionManagerProxy);
        require(positionManager.owner() == owner, "PositionManager owner is not the expected owner");
        require(positionManager.agent() == agent, "PositionManager agent is not the expected agent");
        require(positionManager.oracle() == address(oracle), "PositionManager oracle is not the expected oracle");
        console.log("PositionManager deployed at", address(positionManager));

        // configure
        vault.setStrategy(address(strategy));
        strategy.setPositionManager(address(positionManager));
        strategy.setForwarder(forwarder);
        positionManager.setSizeMinMax(increaseSizeMin, increaseSizeMax, decreaseSizeMin, decreaseSizeMax);
        positionManager.setCollateralMinMax(
            increaseCollateralMin, increaseCollateralMax, decreaseCollateralMin, decreaseCollateralMax
        );
        positionManager.setLimitDecreaseCollateral(limitDecreaseCollateral);
        require(vault.strategy() == address(strategy), "Vault strategy is not the expected strategy");
        require(
            strategy.positionManager() == address(positionManager),
            "Strategy positionManager is not the expected positionManager"
        );
        require(strategy.forwarder() == forwarder, "Strategy forwarder is not the expected forwarder");

        // deploy DataProvider
        DataProvider dataProvider = new DataProvider();
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategy));
        console.log("DataProvider deployed at", address(dataProvider));
    }
}
