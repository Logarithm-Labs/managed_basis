// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import "forge-std/Script.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    ManagedBasisStrategy strategy;
    OffChainPositionManager public positionManager;
    LogarithmOracle public oracle = LogarithmOracle(0x949C9908Cd6C2F0Bca623355f4C5BaF157c3fb70);

    address public operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address public agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;
    address public owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address public forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;

    address public asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address public product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address public assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address public productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant UNISWAPV3_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    uint256 public entryCost = 0;
    uint256 public exitCost = 0;

    uint256 constant targetLeverage = 3 ether;
    uint256 constant minLeverage = 2 ether;
    uint256 constant maxLeverage = 5 ether;
    uint256 constant safeMarginLeverage = 10 ether;

    uint256 increaseSizeMin = 15 * 1e6
    uint256 increaseSizeMax = type(uint256).max
    uint256 decreaseSizeMin = 15 * 1e6
    uint256 decreaseSizeMax = type(uint256).max

    uint256 increaseCollateralMin = 5 * 1e6;
    uint256 increaseCollateralMax = type(uint256).max;
    uint256 decreaseCollateralMin = 10 * 1e6;
    uint256 decreaseCollateralMax = type(uint256).max;

    bool public isLong = false;

    function run() public {
        vm.startBroadcast();

        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        oracle = LogarithmOracle(oracleProxy);

        require(oracle.owner() == owner, "DeployScript: oracle owner mismatch");
        console.log("Oracle deployed at: %s", address(strategy));

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

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        // deploy strategy
        address strategyImpl = address(new ManagedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    ManagedBasisStrategy.initialize.selector,
                    "tt",
                    "tt",
                    asset,
                    product,
                    oracle,
                    operator,
                    targetLeverage,
                    minLeverage,
                    maxLeverage,
                    safeMarginLeverage,
                    entryCost,
                    exitCost,
                    pathWeth
                )
            )
        );
        strategy = ManagedBasisStrategy(strategyProxy);
        require(strategy.owner() == owner, "DeployScript: strategy owner mismatch");
        console.log("Strategy deployed at: %s", address(strategy));

        // deploy position manager
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
        positionManager = OffChainPositionManager(positionManagerProxy);

        require(positionManager.owner() == owner, "DeployScript: position manager owner mismatch");
        console.log("Position manager deployed at: %s", address(positionManager));

        // configure position manager
        positionManager.setSizeMinMax(increaseSizeMin, increaseSizeMax, decreaseSizeMin, decreaseSizeMax);
        positionManager.setCollateralMinMax(increaseCollateralMin, increaseCollateralMax, decreaseCollateralMin, decreaseCollateralMax);

        // set position manager
        strategy.setForwarder(forwarder);
        strategy.setPositionManager(address(positionManager));
    }
}
