// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";

contract ArbDeploy is Script {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    address constant operator = 0xe7263f18e278ea0550FaD97DDF898d134483EfC6;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    // vault params
    uint256 constant entryCost = 0.005 ether; // 0.5% entry fee
    uint256 constant exitCost = 0.005 ether; // 0.5% exit fee
    string constant vaultName = "Logarithm Basis USDC-WETH Hyperliquid (Alpha)";
    string constant vaultSymbol = "log-b-usdc-weth-hl-a";
    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.WETH; // WETH
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
    uint256 constant feedHeartbeat = 24 * 3600;
    bool constant isLong = false;
    // strategy params
    uint256 constant targetLeverage = 6 ether; // 6x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 12 ether; // 12x leverage
    uint256 constant safeMarginLeverage = 20 ether; // 20x leverage

    address[] assetToProductSwapPath = [asset, ArbAddresses.UNI_V3_POOL_WETH_USDC, product];

    function run() public {
        vm.startBroadcast();

        // configure oracle
        LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        uint256[] memory heartbeats = new uint256[](1);
        assets[0] = product;
        feeds[0] = productPriceFeed;
        heartbeats[0] = feedHeartbeat;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        console.log("Product oracle configured!");

        // deploy LogarithmVault
        DeployHelper.LogarithmVaultDeployParams memory vaultDeployParams = DeployHelper.LogarithmVaultDeployParams({
            beacon: Arb.BEACON_VAULT,
            owner: owner,
            asset: asset,
            priorityProvider: address(0),
            entryCost: entryCost,
            exitCost: exitCost,
            name: vaultName,
            symbol: vaultSymbol
        });
        LogarithmVault vault = DeployHelper.deployLogarithmVault(vaultDeployParams);
        console.log("Vault: ", address(vault));

        // deploy BasisStrategy
        DeployHelper.BasisStrategyDeployParams memory strategyDeployParams = DeployHelper.BasisStrategyDeployParams({
            owner: owner,
            beacon: Arb.BEACON_STRATEGY,
            config: Arb.CONFIG_STRATEGY,
            product: product,
            vault: address(vault),
            oracle: Arb.ORACLE,
            operator: operator,
            targetLeverage: targetLeverage,
            minLeverage: minLeverage,
            maxLeverage: maxLeverage,
            safeMarginLeverage: safeMarginLeverage
        });
        BasisStrategy strategy = DeployHelper.deployBasisStrategy(strategyDeployParams);
        console.log("Strategy: ", address(strategy));

        // deploy SpotManager
        SpotManager spotManager =
            DeployHelper.deploySpotManager(Arb.BEACON_SPOT_MANAGER, owner, address(strategy), assetToProductSwapPath);
        console.log("SpotManager: ", address(spotManager));

        // deploy OffChainPositionManager
        OffChainPositionManager positionManager = DeployHelper.deployOffChainPositionManager(
            DeployHelper.OffChainPositionManagerDeployParams({
                owner: owner,
                config: Arb.CONFIG_HL,
                beacon: Arb.BEACON_OFF_CHAIN_POSITION_MANAGER,
                strategy: address(strategy),
                agent: agent,
                oracle: Arb.ORACLE,
                product: product,
                asset: asset,
                isLong: isLong
            })
        );
        console.log("OffChainPositionManager: ", address(positionManager));

        vm.stopBroadcast();
    }
}
