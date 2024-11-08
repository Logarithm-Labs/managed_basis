// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {GmxV2PositionManager} from "src/position/gmx/GmxV2PositionManager.sol";
import {GmxConfig} from "src/position/gmx/GmxConfig.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {GmxGasStation} from "src/position/gmx/GmxGasStation.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {DataProvider} from "src/DataProvider.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract DeployGmxScript is Script {
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;

    address public oracle = 0x26aD95BDdc540ac3Af223F3eB6aA07C13d7e08c9;

    UpgradeableBeacon public vaultBeacon = UpgradeableBeacon(0x6e77994e0bADCF3421d1Fb0Fb8b523FCe0c989Ee);

    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH

    uint256 constant entryCost = 0.005 ether; // 0.5% entry fee
    uint256 constant exitCost = 0.005 ether; // 0.5% exit fee

    uint256 constant targetLeverage = 6 ether; // 6x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 12 ether; // 12x leverage
    uint256 constant safeMarginLeverage = 20 ether; // 20x leverage

    address constant GMX_EXCHANGE_ROUTER = 0x69C527fC77291722b52649E45c838e41be8Bf5d5;
    address constant GMX_READER = 0x5Ca84c34a381434786738735265b9f3FD814b824;
    address constant GMX_ETH_USDC_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant UNISWAPV3_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    function run() public {
        vm.startBroadcast();

        // upgrade vault beacon
        address vaultImpl = address(new LogarithmVault());
        vaultBeacon.upgradeTo(vaultImpl);

        // deploy new vault
        address vaultProxy = address(
            new BeaconProxy(
                address(vaultBeacon),
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector, owner, asset, entryCost, exitCost, "tt-g", "tt-g"
                )
            )
        );
        require(LogarithmVault(vaultProxy).owner() == owner, "LogarithmVault owner is not the expected owner");
        console.log("LogarithmVaultGMX deployed at", vaultProxy);

        // deploy strategy config
        address strategyConfigImpl = address(new StrategyConfig());
        address strategyConfigProxy = address(
            new ERC1967Proxy(strategyConfigImpl, abi.encodeWithSelector(StrategyConfig.initialize.selector, owner))
        );
        require(StrategyConfig(strategyConfigProxy).owner() == owner, "StrategyConfig owner is not the expected owner");
        console.log("StrategyConfig deployed at", strategyConfigProxy);

        // deploy strategy beacon
        address strategyImpl = address(new BasisStrategy());
        address strategyBeacon = address(new UpgradeableBeacon(strategyImpl, owner));
        require(UpgradeableBeacon(strategyBeacon).owner() == owner, "StrategyBeacon owner is not the expected owner");
        console.log("StrategyBeaconGMX deployed at", strategyBeacon);

        // set manual swap path
        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        // deploy strategy
        address strategyProxy = address(
            new BeaconProxy(
                address(strategyBeacon),
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    address(strategyConfigProxy),
                    product,
                    address(vaultProxy),
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
        require(BasisStrategy(strategyProxy).owner() == owner, "BasisStrategy owner is not the expected owner");
        console.log("BasisStrategyGMX deployed at", strategyProxy);

        // deploy gmx config
        address gmxConfigImpl = address(new GmxConfig());
        address gmxConfigProxy = address(
            new ERC1967Proxy(
                gmxConfigImpl,
                abi.encodeWithSelector(GmxConfig.initialize.selector, owner, GMX_EXCHANGE_ROUTER, GMX_READER)
            )
        );
        require(GmxConfig(gmxConfigProxy).owner() == owner, "GmxConfig owner is not the expected owner");
        console.log("GmxConfig deployed at", gmxConfigProxy);

        // deploy gas station
        address gasStationImpl = address(new GmxGasStation());
        address gasStationProxy =
            address(new ERC1967Proxy(gasStationImpl, abi.encodeWithSelector(GmxGasStation.initialize.selector, owner)));
        require(
            GmxGasStation(payable(gasStationProxy)).owner() == owner, "GmxGasStation owner is not the expected owner"
        );
        console.log("GmxGasStation deployed at", gasStationProxy);

        // deploy position manager
        address positionManagerImpl = address(new GmxV2PositionManager());
        address positionManagerBeacon = address(new UpgradeableBeacon(positionManagerImpl, owner));
        require(
            UpgradeableBeacon(positionManagerBeacon).owner() == owner,
            "PositionManagerBeacon owner is not the expected owner"
        );
        console.log("GmxPositionManagerBeacon deployed at", positionManagerBeacon);

        address positionManagerProxy;
        // = address(
        //     new BeaconProxy(
        //         positionManagerBeacon,
        //         abi.encodeWithSelector(
        //             GmxV2PositionManager.initialize.selector,
        //             // owner,
        //             address(strategyProxy),
        //             address(gmxConfigProxy),
        //             address(gasStationProxy),
        //             GMX_ETH_USDC_MARKET
        //         )
        //     )
        // );
        // require(
        //     GmxV2PositionManager(payable(positionManagerProxy)).owner() == owner,
        //     "GmxPositionManager owner is not the expected owner"
        // );
        console.log("GmxPositionManager deployed at", positionManagerProxy);

        // config
        LogarithmVault(vaultProxy).setStrategy(strategyProxy);
        BasisStrategy(strategyProxy).setPositionManager(positionManagerProxy);
        GmxGasStation(payable(gasStationProxy)).registerPositionManager(positionManagerProxy, true);
        // BasisStrategy(strategyProxy).setForwarder(forwarder);

        (bool success,) = gasStationProxy.call{value: 0.0004 ether}("");
        require(success, "Failed to send ether to gas station");
    }
}
