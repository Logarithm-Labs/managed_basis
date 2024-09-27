// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {OffChainPositionManager} from "src/position/offchain/OffChainPositionManager.sol";
import {OffChainConfig} from "src/position/offchain/OffChainConfig.sol";
import {GmxV2PositionManager} from "src/position/gmx/GmxV2PositionManager.sol";
import {GmxGasStation} from "src/position/gmx/GmxGasStation.sol";
import {GmxConfig} from "src/position/gmx/GmxConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {DataProvider} from "src/DataProvider.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    // swap addresses
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant UNISWAPV3_WETH_USDC = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    // GMX Addresses
    address constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_EXCHANGE_ROUTER = 0x69C527fC77291722b52649E45c838e41be8Bf5d5;
    address constant GMX_ORDER_HANDLER = 0xB0Fc2a48b873da40e7bc25658e5E6137616AC2Ee;
    address constant GMX_ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address constant GMX_READER = 0x5Ca84c34a381434786738735265b9f3FD814b824;
    address constant GMX_ETH_USDC_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address constant GMX_KEEPER = 0xE47b36382DC50b90bCF6176Ddb159C4b9333A7AB;
    address constant CHAINLINK_PRICE_FEED_PROVIDER = 0x527FB0bCfF63C47761039bB386cFE181A92a4701;

    // Strategy Addresses
    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    bool constant isLong = false;

    // vault params
    uint256 constant entryCost = 0.005 ether; // 0.5% entry fee
    uint256 constant exitCost = 0.005 ether; // 0.5% exit fee

    // strategy params
    uint256 constant targetLeverage = 6 ether; // 6x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 12 ether; // 12x leverage
    uint256 constant safeMarginLeverage = 20 ether; // 20x leverage

    // position manager params
    uint256 constant increaseSizeMin = 15 * 1e6;
    uint256 constant increaseSizeMax = type(uint256).max;
    uint256 constant decreaseSizeMin = 15 * 1e6;
    uint256 constant decreaseSizeMax = type(uint256).max;

    uint256 constant increaseCollateralMin = 5 * 1e6;
    uint256 constant increaseCollateralMax = type(uint256).max;
    uint256 constant decreaseCollateralMin = 10 * 1e6;
    uint256 constant decreaseCollateralMax = type(uint256).max;
    uint256 constant limitDecreaseCollateral = 50 * 1e6;

    // predeployed contracts
    LogarithmOracle public oracle = LogarithmOracle(0x26aD95BDdc540ac3Af223F3eB6aA07C13d7e08c9);
    GmxGasStation public gmxGasStation = GmxGasStation(payable(0xB758989eeBB4D5EF2da4FbD6E37f898dd1d49b2a));

    function run() public {
        vm.startBroadcast();
        // // deploy LogarithmOracle
        // address oracleImpl = address(new LogarithmOracle());
        // address oracleProxy =
        //     address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        // LogarithmOracle oracle = LogarithmOracle(oracleProxy);
        // address oracleOwner = oracle.owner();
        // require(oracleOwner == owner, "Oracle owner is not the expected owner");

        // // set oracle price feed
        // address[] memory assets = new address[](2);
        // address[] memory feeds = new address[](2);
        // uint256[] memory heartbeats = new uint256[](2);
        // assets[0] = asset;
        // assets[1] = product;
        // feeds[0] = assetPriceFeed;
        // feeds[1] = productPriceFeed;
        // heartbeats[0] = 24 * 3600;
        // heartbeats[1] = 24 * 3600;
        // oracle.setPriceFeeds(assets, feeds);
        // oracle.setHeartbeats(feeds, heartbeats);

        // console.log("Oracle deployed at", address(oracle));

        // deploy LogarithmVaultBeacon
        address vaultImpl = address(new LogarithmVault());
        address vaultBeacon = address(new UpgradeableBeacon(vaultImpl, owner));
        require(
            UpgradeableBeacon(vaultBeacon).implementation() == vaultImpl,
            "VaultBeacon implementation is not the expected implementation"
        );
        require(UpgradeableBeacon(vaultBeacon).owner() == owner, "VaultBeacon owner is not the expected owner");
        console.log("Vault Beacon deployed at", vaultBeacon);

        // deploy LogarithmVaultGmx
        address vaultProxy = address(
            new BeaconProxy(
                vaultBeacon,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector,
                    owner,
                    asset,
                    entryCost,
                    exitCost,
                    "Logarithm Basis USDC-WETH GMX (Alpha)",
                    "log-b-usdc-weth-gmx-a"
                )
            )
        );
        LogarithmVault vaultGmx = LogarithmVault(vaultProxy);
        require(vaultGmx.owner() == owner, "Vault owner is not the expected owner");
        console.log("Vault GMX deployed at", address(vaultGmx));

        // deploy LogarithmVaultHl
        vaultProxy = address(
            new BeaconProxy(
                vaultBeacon,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector,
                    owner,
                    asset,
                    entryCost,
                    exitCost,
                    "Logarithm Basis USDC-WETH Hyperliquid (Alpha)",
                    "log-b-usdc-weth-hl-a"
                )
            )
        );
        LogarithmVault vaultHl = LogarithmVault(vaultProxy);
        require(vaultHl.owner() == owner, "Vault owner is not the expected owner");
        console.log("Vault HL deployed at", address(vaultHl));

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        // deploy BasisStrategyConfig
        address strategyConfigImpl = address(new StrategyConfig());
        address strategyConfigProxy = address(
            new ERC1967Proxy(strategyConfigImpl, abi.encodeWithSelector(StrategyConfig.initialize.selector, owner))
        );
        StrategyConfig strategyConfig = StrategyConfig(strategyConfigProxy);
        require(strategyConfig.owner() == owner, "Config owner is not the expected owner");
        console.log("Strategy Config deployed at", address(strategyConfig));

        // deploy BasisStrategyBeacon
        address strategyImpl = address(new BasisStrategy());
        address strategyBeacon = address(new UpgradeableBeacon(strategyImpl, owner));
        require(
            UpgradeableBeacon(strategyBeacon).implementation() == strategyImpl,
            "StrategyBeacon implementation is not the expected implementation"
        );
        require(UpgradeableBeacon(strategyBeacon).owner() == owner, "StrategyBeacon owner is not the expected owner");
        console.log("Strategy Beacon deployed at", strategyBeacon);

        // deploy BasisStrategy Gmx
        address strategyProxy = address(
            new BeaconProxy(
                strategyBeacon,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    address(strategyConfig),
                    product,
                    address(vaultGmx),
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

        BasisStrategy strategyGmx = BasisStrategy(strategyProxy);
        require(strategyGmx.owner() == owner, "Strategy owner is not the expected owner");
        console.log("Strategy GMX deployed at", address(strategyGmx));

        // deploy BasisStrategy Hl
        strategyProxy = address(
            new BeaconProxy(
                strategyBeacon,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    address(strategyConfig),
                    product,
                    address(vaultHl),
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

        BasisStrategy strategyHl = BasisStrategy(strategyProxy);
        require(strategyHl.owner() == owner, "Strategy owner is not the expected owner");
        console.log("Strategy GMX deployed at", address(strategyHl));

        // deploy GmxConfig
        address gmxConfigImpl = address(new GmxConfig());
        address gmxConfigProxy = address(
            new ERC1967Proxy(
                gmxConfigImpl,
                abi.encodeWithSelector(GmxConfig.initialize.selector, owner, GMX_EXCHANGE_ROUTER, GMX_READER)
            )
        );
        GmxConfig gmxConfig = GmxConfig(gmxConfigProxy);
        require(gmxConfig.owner() == owner, "GmxConfig owner is not the expected owner");
        console.log("GmxConfig deployed at", address(gmxConfig));

        // deploy GmxPositionManagerBeacon
        address gmxPositionManagerImpl = address(new GmxV2PositionManager());
        address gmxPositionManagerBeacon = address(new UpgradeableBeacon(gmxPositionManagerImpl, owner));
        require(
            UpgradeableBeacon(gmxPositionManagerBeacon).implementation() == gmxPositionManagerImpl,
            "GmxPositionManagerBeacon implementation is not the expected implementation"
        );
        require(
            UpgradeableBeacon(gmxPositionManagerBeacon).owner() == owner,
            "GmxPositionManagerBeacon owner is not the expected owner"
        );
        console.log("GmxPositionManager Beacon deployed at", gmxPositionManagerBeacon);

        // deploy GmxPositionManager
        address gmxPositionManagerProxy = address(
            new BeaconProxy(
                gmxPositionManagerBeacon,
                abi.encodeWithSelector(
                    GmxV2PositionManager.initialize.selector,
                    strategyGmx,
                    address(gmxConfig),
                    address(gmxGasStation),
                    GMX_ETH_USDC_MARKET
                )
            )
        );
        GmxV2PositionManager gmxPositionManager = GmxV2PositionManager(payable(gmxPositionManagerProxy));
        console.log("PositionManager GMX deployed at", address(gmxPositionManager));

        // deploy Hypeliquid Config
        address hlConfigImpl = address(new OffChainConfig());
        address hlConfigProxy =
            address(new ERC1967Proxy(hlConfigImpl, abi.encodeWithSelector(OffChainConfig.initialize.selector, owner)));
        OffChainConfig hlConfig = OffChainConfig(hlConfigProxy);
        require(hlConfig.owner() == owner, "Hypeliquid Config owner is not the expected owner");
        hlConfig.setSizeMinMax(increaseSizeMin, increaseSizeMax, decreaseSizeMin, decreaseSizeMax);
        hlConfig.setCollateralMinMax(
            increaseCollateralMin, increaseCollateralMax, decreaseCollateralMin, decreaseCollateralMax
        );
        hlConfig.setLimitDecreaseCollateral(limitDecreaseCollateral);

        // deploy OffChainPositionManagerBeacon
        address offchainPositionManagerImpl = address(new OffChainPositionManager());
        address offchainPositionManagerBeacon = address(new UpgradeableBeacon(offchainPositionManagerImpl, owner));
        require(
            UpgradeableBeacon(offchainPositionManagerBeacon).implementation() == offchainPositionManagerImpl,
            "PositionManagerBeacon implementation is not the expected implementation"
        );
        require(
            UpgradeableBeacon(offchainPositionManagerBeacon).owner() == owner,
            "PositionManagerBeacon owner is not the expected owner"
        );
        console.log("PositionManager Beacon deployed at", offchainPositionManagerBeacon);

        address hlPositionManagerProxy = address(
            new BeaconProxy(
                offchainPositionManagerBeacon,
                abi.encodeWithSelector(
                    OffChainPositionManager.initialize.selector,
                    address(strategyHl),
                    agent,
                    address(oracle),
                    product,
                    asset,
                    false
                )
            )
        );
        OffChainPositionManager hlPositionManager = OffChainPositionManager(hlPositionManagerProxy);
        require(hlPositionManager.owner() == owner, "PositionManager owner is not the expected owner");
        require(hlPositionManager.agent() == agent, "PositionManager agent is not the expected agent");
        require(hlPositionManager.oracle() == address(oracle), "PositionManager oracle is not the expected oracle");
        console.log("PositionManager Hypeliquid deployed at", address(hlPositionManager));

        // configure
        vaultGmx.setStrategy(address(strategyGmx));
        strategyGmx.setPositionManager(address(gmxPositionManager));
        require(vaultGmx.strategy() == address(strategyGmx), "Vault strategy is not the expected strategy");
        require(
            strategyGmx.positionManager() == address(gmxPositionManager),
            "Strategy positionManager is not the expected positionManager"
        );

        vaultHl.setStrategy(address(strategyHl));
        strategyHl.setPositionManager(address(hlPositionManager));
        require(vaultHl.strategy() == address(strategyHl), "Vault strategy is not the expected strategy");
        require(
            strategyHl.positionManager() == address(hlPositionManager),
            "Strategy positionManager is not the expected positionManager"
        );

        // deploy DataProvider
        DataProvider dataProvider = new DataProvider();
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategyHl));
        console.log("DataProvider deployed at", address(dataProvider));
    }
}
