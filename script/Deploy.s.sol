// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {OffChainPositionManager} from "src/position/offchain/OffChainPositionManager.sol";
import {OffChainConfig} from "src/position/offchain/OffChainConfig.sol";
import {GmxV2PositionManager} from "src/position/gmx/GmxV2PositionManager.sol";
import {GmxGasStation} from "src/position/gmx/GmxGasStation.sol";
import {GmxConfig} from "src/position/gmx/GmxConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {DataProvider} from "src/DataProvider.sol";

import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    address constant gmxOperator = 0xe7263f18e278ea0550FaD97DDF898d134483EfC6;
    address constant hlOperator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    // Strategy Addresses
    address constant asset = ArbiAddresses.USDC; // USDC
    address constant product = ArbiAddresses.WETH; // WETH
    address constant assetPriceFeed = ArbiAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbiAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
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
    // GmxGasStation public gmxGasStation = GmxGasStation(payable(0xB758989eeBB4D5EF2da4FbD6E37f898dd1d49b2a));

    function run() public {
        vm.startBroadcast();

        // deploy mock priority provider
        MockPriorityProvider provider = new MockPriorityProvider();
        console.log("Mock PriorityProvider deployed at", address(provider));

        // deploy LogarithmVaultBeacon
        address vaultBeacon = DeployHelper.deployBeacon(address(new LogarithmVault()), owner);
        console.log("Vault Beacon deployed at", vaultBeacon);

        // deploy LogarithmVaultGmx
        DeployHelper.LogarithmVaultDeployParams memory vaultDeployParams = DeployHelper.LogarithmVaultDeployParams(
            vaultBeacon,
            owner,
            asset,
            address(provider),
            entryCost,
            exitCost,
            "Logarithm Basis USDC-WETH GMX (Alpha)",
            "log-b-usdc-weth-gmx-a"
        );
        LogarithmVault vaultGmx = DeployHelper.deployLogarithmVault(vaultDeployParams);
        console.log("Vault GMX deployed at", address(vaultGmx));
        // deploy LogarithmVaultHl
        vaultDeployParams.name = "Logarithm Basis USDC-WETH Hyperliquid (Alpha)";
        vaultDeployParams.symbol = "log-b-usdc-weth-hl-a";
        LogarithmVault vaultHl = DeployHelper.deployLogarithmVault(vaultDeployParams);
        console.log("Vault HL deployed at", address(vaultHl));

        // deploy BasisStrategyConfig
        StrategyConfig strategyConfig = DeployHelper.deployStrategyConfig(owner);
        console.log("Strategy Config deployed at", address(strategyConfig));

        // deploy BasisStrategyBeacon
        address strategyBeacon = DeployHelper.deployBeacon(address(new BasisStrategy()), owner);
        console.log("Strategy Beacon deployed at", strategyBeacon);

        address spotManagerBeacon = DeployHelper.deployBeacon(address(new SpotManager()), owner);
        console.log("SpotManager Beacon deployed at", spotManagerBeacon);

        // deploy BasisStrategy Gmx
        address[] memory assetToProductSwapPath = new address[](3);
        assetToProductSwapPath[0] = ArbiAddresses.USDC;
        assetToProductSwapPath[1] = ArbiAddresses.UNISWAPV3_WETH_USDC;
        assetToProductSwapPath[2] = ArbiAddresses.WETH;
        DeployHelper.BasisStrategyDeployParams memory strategyDeployParams = DeployHelper.BasisStrategyDeployParams(
            owner,
            strategyBeacon,
            address(strategyConfig),
            product,
            address(vaultGmx),
            address(oracle),
            gmxOperator,
            targetLeverage,
            minLeverage,
            maxLeverage,
            safeMarginLeverage
        );
        BasisStrategy strategyGmx = DeployHelper.deployBasisStrategy(strategyDeployParams);
        console.log("Strategy GMX deployed at", address(strategyGmx));

        // deploy Gmx spot manager
        SpotManager gmxSpotManager = DeployHelper.deploySpotManager(
            spotManagerBeacon, owner, address(strategyGmx), asset, product, assetToProductSwapPath
        );
        console.log("SpotManager GMX deployed at", address(gmxSpotManager));

        // deploy BasisStrategy Hl
        strategyDeployParams.vault = address(vaultHl);
        strategyDeployParams.operator = hlOperator;
        BasisStrategy strategyHl = DeployHelper.deployBasisStrategy(strategyDeployParams);
        console.log("Strategy HL deployed at", address(strategyHl));

        // deploy Gmx spot manager
        SpotManager hlSpotManager = DeployHelper.deploySpotManager(
            spotManagerBeacon, owner, address(strategyHl), asset, product, assetToProductSwapPath
        );
        console.log("SpotManager HL deployed at", address(hlSpotManager));

        // deploy GmxConfig
        GmxConfig gmxConfig = DeployHelper.deployGmxConfig(owner);
        console.log("GmxConfig deployed at", address(gmxConfig));

        // deploy GmxGasStation
        GmxGasStation gmxGasStation = DeployHelper.deployGmxGasStation(owner);
        console.log("GmxGasStation deployed at", address(gmxGasStation));

        // deploy GmxPositionManagerBeacon
        address gmxPositionManagerBeacon = DeployHelper.deployBeacon(address(new GmxV2PositionManager()), owner);
        console.log("GmxPositionManager Beacon deployed at", gmxPositionManagerBeacon);

        // deploy GmxPositionManager
        GmxV2PositionManager gmxPositionManager = DeployHelper.deployGmxPositionManager(
            DeployHelper.GmxPositionManagerDeployParams(
                gmxPositionManagerBeacon,
                address(gmxConfig),
                address(strategyGmx),
                address(gmxGasStation),
                ArbiAddresses.GMX_ETH_USDC_MARKET
            )
        );
        console.log("PositionManager GMX deployed at", address(gmxPositionManager));

        // deploy HL Config
        OffChainConfig hlConfig = DeployHelper.deployOffChainConfig(owner);
        hlConfig.setSizeMinMax(increaseSizeMin, increaseSizeMax, decreaseSizeMin, decreaseSizeMax);
        hlConfig.setCollateralMinMax(
            increaseCollateralMin, increaseCollateralMax, decreaseCollateralMin, decreaseCollateralMax
        );
        hlConfig.setLimitDecreaseCollateral(limitDecreaseCollateral);

        // deploy OffChainPositionManagerBeacon
        address offchainPositionManagerBeacon = DeployHelper.deployBeacon(address(new OffChainPositionManager()), owner);
        console.log("OffChainPositionManager Beacon deployed at", offchainPositionManagerBeacon);

        OffChainPositionManager hlPositionManager = DeployHelper.deployOffChainPositionManager(
            DeployHelper.OffChainPositionManagerDeployParams(
                owner,
                address(hlConfig),
                offchainPositionManagerBeacon,
                address(strategyHl),
                agent,
                address(oracle),
                product,
                asset,
                false
            )
        );
        console.log("PositionManager HL deployed at", address(hlPositionManager));

        // deploy DataProvider
        DataProvider dataProvider = new DataProvider();
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategyHl));
        console.log("DataProvider deployed at", address(dataProvider));
    }
}
