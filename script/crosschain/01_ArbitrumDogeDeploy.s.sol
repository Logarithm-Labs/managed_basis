// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {DataProvider} from "src/DataProvider.sol";

import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";

/// @dev should validate if oracle is set for all tokens including the gmx virtual index tokens.
contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    address constant gmxOperator = 0xe7263f18e278ea0550FaD97DDF898d134483EfC6;
    address constant hlOperator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant forwarder = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.DOGE; // DOGE
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CHL_DOGE_USD_PRICE_FEED; // Chainlink DOGE-USD price feed
    bool constant isLong = false;

    // vault params
    uint256 constant entryCost = 0.005 ether; // 0.5% entry fee
    uint256 constant exitCost = 0.005 ether; // 0.5% exit fee

    // strategy params for gmx
    uint256 constant gmxTargetLeverage = 6 ether; // 6x leverage
    uint256 constant gmxMinLeverage = 2 ether; // 2x leverage
    uint256 constant gmxMaxLeverage = 12 ether; // 12x leverage
    uint256 constant gmxSafeMarginLeverage = 20 ether; // 20x leverage

    // strategy params for hl
    uint256 constant hlTargetLeverage = 3 ether; // 3x leverage
    uint256 constant hlMinLeverage = 1 ether; // 1x leverage
    uint256 constant hlMaxLeverage = 5 ether; // 5x leverage
    uint256 constant hlSafeMarginLeverage = 8 ether; // 8x leverage

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

    uint256 constant BSC_CHAIN_ID = 56;

    function run() public {
        vm.startBroadcast();

        LogarithmOracle oracle = DeployHelper.deployLogarithmOracle(owner);

        // configure oracle for DOGE
        address[] memory assets = new address[](3);
        address[] memory feeds = new address[](3);
        uint256[] memory heartbeats = new uint256[](3);
        assets[0] = ArbAddresses.USDC;
        assets[1] = ArbAddresses.WETH;
        assets[2] = ArbAddresses.DOGE;
        feeds[0] = ArbAddresses.CHL_USDC_USD_PRICE_FEED;
        feeds[1] = ArbAddresses.CHL_ETH_USD_PRICE_FEED;
        feeds[2] = ArbAddresses.CHL_DOGE_USD_PRICE_FEED;
        heartbeats[0] = 24 * 3600;
        heartbeats[1] = 24 * 3600;
        heartbeats[2] = 24 * 3600;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        console.log("Oracle: ", address(oracle));

        // deploy mock priority provider
        MockPriorityProvider provider = new MockPriorityProvider();
        console.log("Mock PriorityProvider: ", address(provider));

        // deploy LogarithmVaultBeacon
        address vaultBeacon = DeployHelper.deployBeacon(address(new LogarithmVault()), owner);
        console.log("Beacon(Vault): ", vaultBeacon);

        // deploy LogarithmVaultGmx
        DeployHelper.LogarithmVaultDeployParams memory vaultDeployParams = DeployHelper.LogarithmVaultDeployParams(
            vaultBeacon,
            owner,
            asset,
            address(provider),
            entryCost,
            exitCost,
            "Logarithm Basis USDC-DOGE GMX (Alpha)",
            "log-b-usdc-doge-gmx-a"
        );
        LogarithmVault vaultGmx = DeployHelper.deployLogarithmVault(vaultDeployParams);
        console.log("Vault(GMX)-USDC-DOGE: ", address(vaultGmx));
        // deploy LogarithmVaultHl
        vaultDeployParams.name = "Logarithm Basis USDC-DOGE Hyperliquid (Alpha)";
        vaultDeployParams.symbol = "log-b-usdc-doge-hl-a";
        LogarithmVault vaultHl = DeployHelper.deployLogarithmVault(vaultDeployParams);
        console.log("Vault(HL)-USDC-DOGE: ", address(vaultHl));

        // deploy GasStation
        GasStation gasStation = DeployHelper.deployGasStation(owner);
        console.log("GasStation:", address(gasStation));

        // deploy BasisStrategyConfig
        StrategyConfig strategyConfig = DeployHelper.deployStrategyConfig(owner);
        console.log("Strategy Config: ", address(strategyConfig));

        // deploy BasisStrategyBeacon
        address strategyBeacon = DeployHelper.deployBeacon(address(new BasisStrategy()), owner);
        console.log("Beacon(Strategy): ", strategyBeacon);

        address xSpotManagerBeacon = DeployHelper.deployBeacon(address(new XSpotManager()), owner);
        console.log("Beacon(XSpotManager): ", xSpotManagerBeacon);

        DeployHelper.BasisStrategyDeployParams memory strategyDeployParams = DeployHelper.BasisStrategyDeployParams({
            owner: owner,
            beacon: strategyBeacon,
            config: address(strategyConfig),
            product: product,
            vault: address(vaultGmx),
            oracle: address(oracle),
            operator: gmxOperator,
            targetLeverage: gmxTargetLeverage,
            minLeverage: gmxMinLeverage,
            maxLeverage: gmxMaxLeverage,
            safeMarginLeverage: gmxSafeMarginLeverage
        });
        BasisStrategy strategyGmx = DeployHelper.deployBasisStrategy(strategyDeployParams);
        console.log("Strategy(GMX)-USDC-DOGE: ", address(strategyGmx));

        // deploy Gmx spot manager
        DeployHelper.DeployXSpotManagerParams memory xSpotDeployParams = DeployHelper.DeployXSpotManagerParams({
            beacon: xSpotManagerBeacon,
            owner: owner,
            strategy: address(strategyGmx),
            messenger: ArbAddresses.LOGARITHM_MESSENGER,
            dstChainId: BSC_CHAIN_ID
        });
        XSpotManager gmxXSpotManager = DeployHelper.deployXSpotManager(xSpotDeployParams);
        console.log("XSpotManager(GMX)-USDC-DOGE: ", address(gmxXSpotManager));

        // deploy BasisStrategy Hl
        strategyDeployParams.vault = address(vaultHl);
        strategyDeployParams.operator = hlOperator;
        strategyDeployParams.targetLeverage = hlTargetLeverage;
        strategyDeployParams.minLeverage = hlMinLeverage;
        strategyDeployParams.maxLeverage = hlMaxLeverage;
        strategyDeployParams.safeMarginLeverage = hlSafeMarginLeverage;
        BasisStrategy strategyHl = DeployHelper.deployBasisStrategy(strategyDeployParams);
        console.log("Strategy(HL)-USDC-DOGE: ", address(strategyHl));

        // deploy HL spot manager
        xSpotDeployParams.strategy = address(strategyHl);
        XSpotManager hlXSpotManager = DeployHelper.deployXSpotManager(xSpotDeployParams);
        console.log("XSpotManager(HL)-USDC-DOGE: ", address(hlXSpotManager));

        // deploy GmxConfig
        GmxConfig gmxConfig = DeployHelper.deployGmxConfig(owner);
        console.log("GmxConfig: ", address(gmxConfig));

        // deploy GmxPositionManagerBeacon
        address gmxPositionManagerBeacon = DeployHelper.deployBeacon(address(new GmxV2PositionManager()), owner);
        console.log("Beacon(GmxPositionManager): ", gmxPositionManagerBeacon);

        // deploy GmxPositionManager
        GmxV2PositionManager gmxPositionManager = DeployHelper.deployGmxPositionManager(
            DeployHelper.GmxPositionManagerDeployParams(
                gmxPositionManagerBeacon,
                address(gmxConfig),
                address(strategyGmx),
                address(gasStation),
                ArbAddresses.GMX_DOGE_USDC_MARKET
            )
        );
        console.log("GmxPositionManager-USDC-DOGE: ", address(gmxPositionManager));

        // deploy HL Config
        OffChainConfig hlConfig = DeployHelper.deployOffChainConfig(owner);
        hlConfig.setSizeMin(increaseSizeMin, decreaseSizeMin);
        hlConfig.setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        hlConfig.setLimitDecreaseCollateral(limitDecreaseCollateral);
        console.log("OffChainConfig: ", address(hlConfig));

        // deploy OffChainPositionManagerBeacon
        address offchainPositionManagerBeacon = DeployHelper.deployBeacon(address(new OffChainPositionManager()), owner);
        console.log("Beacon(OffChainPositionManager): ", offchainPositionManagerBeacon);

        OffChainPositionManager hlPositionManager = DeployHelper.deployOffChainPositionManager(
            DeployHelper.OffChainPositionManagerDeployParams({
                owner: owner,
                config: address(hlConfig),
                beacon: offchainPositionManagerBeacon,
                strategy: address(strategyHl),
                agent: agent,
                oracle: address(oracle),
                product: product,
                asset: asset,
                isLong: false
            })
        );
        console.log("OffChainPositionManager-USDC-DOGE", address(hlPositionManager));

        // deploy DataProvider
        DataProvider dataProvider = new DataProvider();
        console.log("DataProvider:", address(dataProvider));
    }
}
