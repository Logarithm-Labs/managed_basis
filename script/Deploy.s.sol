// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import "forge-std/Script.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    AccumulatedBasisStrategy public strategy;
    OffChainPositionManager public positionManager;
    LogarithmOracle public oracle;

    address public operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address public agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;
    address public owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

    address public asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address public product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address public assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address public productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed

    uint256 public entryCost = 0;
    uint256 public exitCost = 0;

    uint256 public targetLeverage = 3 * 1e18;

    bool public isLong = false;

    function run() public {
        vm.startBroadcast();

        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        oracle = LogarithmOracle(oracleProxy);
        require(oracle.owner() == owner, "DeployScript: oracle owner mismatch");
        console.log("Oracle deployed at: %s", address(oracle));

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

        // deploy strategy
        address strategyImpl = address(new AccumulatedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    AccumulatedBasisStrategy.initialize.selector,
                    asset,
                    product,
                    oracle,
                    operator,
                    targetLeverage,
                    entryCost,
                    exitCost
                )
            )
        );
        strategy = AccumulatedBasisStrategy(strategyProxy);
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

        // set position manager
        strategy.setPositionManager(address(positionManager));
    }
}
