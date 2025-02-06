// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract DeployHyperScript is Script {
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    address public oracle = 0x26aD95BDdc540ac3Af223F3eB6aA07C13d7e08c9;

    UpgradeableBeacon public vaultBeacon = UpgradeableBeacon(0x6e77994e0bADCF3421d1Fb0Fb8b523FCe0c989Ee);
    UpgradeableBeacon public strategyBeacon = UpgradeableBeacon(0x8BDB3Ece7e238E96Cbe3645dfAd01DD5f160F587);
    address public strategyConfig = 0x424B0AE1e84F184D43D099A7a7951fbB70AC180c;

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
    address constant UNI_V3_POOL_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

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

        // deploy new vault
        address vaultProxy = address(
            new BeaconProxy(
                address(vaultBeacon),
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector, owner, asset, entryCost, exitCost, "tt-h", "tt-h"
                )
            )
        );
        require(LogarithmVault(vaultProxy).owner() == owner, "LogarithmVault owner is not the expected owner");
        console.log("LogarithmVaultHyper deployed at", vaultProxy);

        // upgrade strategy beacon
        address strategyImpl = address(new BasisStrategy());
        UpgradeableBeacon(strategyBeacon).upgradeTo(strategyImpl);

        // set manual swap path
        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNI_V3_POOL_WETH_USDC;
        pathWeth[2] = WETH;

        // deploy strategy
        address strategyProxy = address(
            new BeaconProxy(
                address(strategyBeacon),
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    address(strategyConfig),
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
        console.log("BasisStrategyHyper deployed at", strategyProxy);

        // deploy off chain config
        address offChainConfigImpl = address(new OffChainConfig());
        address offChainConfigProxy = address(
            new ERC1967Proxy(offChainConfigImpl, abi.encodeWithSelector(OffChainConfig.initialize.selector, owner))
        );
        require(OffChainConfig(offChainConfigProxy).owner() == owner, "OffChainConfig owner is not the expected owner");
        console.log("OffChainConfig deployed at", offChainConfigProxy);

        // deploy position manager
        address hedgeManagerImpl = address(new OffChainPositionManager());
        address hedgeManagerBeacon = address(new UpgradeableBeacon(hedgeManagerImpl, owner));
        require(
            UpgradeableBeacon(hedgeManagerBeacon).owner() == owner,
            "PositionManagerBeacon owner is not the expected owner"
        );
        console.log("OffChainPositionManagerBeacon deployed at", hedgeManagerBeacon);

        address hedgeManagerProxy = address(
            new BeaconProxy(
                hedgeManagerBeacon,
                abi.encodeWithSelector(
                    OffChainPositionManager.initialize.selector,
                    offChainConfigProxy,
                    address(strategyProxy),
                    agent,
                    address(oracle),
                    false
                )
            )
        );
        require(
            OffChainPositionManager(hedgeManagerProxy).owner() == owner,
            "OffChainPositionManager owner is not the expected owner"
        );
        console.log("OffChainPositionManager deployed at", hedgeManagerProxy);

        // config
        LogarithmVault(vaultProxy).setStrategy(strategyProxy);
        BasisStrategy(strategyProxy).setHedgeManager(hedgeManagerProxy);
        // BasisStrategy(strategyProxy).setForwarder(forwarder);
        OffChainConfig(offChainConfigProxy).setSizeMin(increaseSizeMin, decreaseSizeMin);
        OffChainConfig(offChainConfigProxy).setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        OffChainConfig(offChainConfigProxy).setLimitDecreaseCollateral(limitDecreaseCollateral);
    }
}
