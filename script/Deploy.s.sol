// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import "forge-std/Script.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployScript is Script {
    address public owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address public keeper = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address public asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address public product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address public assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address public productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed

    uint256 public entryCost = 0;
    uint256 public exitCost = 0;

    bool public isLong = false;

    function run() public {
        vm.startBroadcast();

        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        LogarithmOracle oracle = LogarithmOracle(oracleProxy);
        console.log("Oracle deployed at: %s", oracleProxy);

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
        ManagedBasisStrategy strategy = ManagedBasisStrategy(strategyProxy);
        console.log("Strategy deployed at: %s", address(strategy));

        // set oracle price feed
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);
        assets[0] = asset;
        assets[1] = product;
        feeds[0] = assetPriceFeed;
        feeds[1] = productPriceFeed;
        oracle.setPriceFeeds(assets, feeds);
    }
}
