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
    // strategy params
    uint256 constant targetLeverage = 6 ether; // 6x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 12 ether; // 12x leverage
    uint256 constant safeMarginLeverage = 20 ether; // 20x leverage

    address[] assetToProductSwapPath = [asset, ArbAddresses.UNI_V3_POOL_WETH_USDC, product];

    function run() public {
        vm.startBroadcast();
        DeployHelper.deployHLVault(
            DeployHelper.DeployHLVaultParams({
                owner: owner,
                name: vaultName,
                symbol: vaultSymbol,
                asset: asset,
                product: product,
                productPriceFeed: productPriceFeed,
                productPriceFeedHeartbeats: feedHeartbeat,
                entryCost: entryCost,
                exitCost: exitCost,
                operator: operator,
                agent: agent,
                targetLeverage: targetLeverage,
                minLeverage: targetLeverage,
                maxLeverage: maxLeverage,
                safeMarginLeverage: safeMarginLeverage,
                assetToProductSwapPath: assetToProductSwapPath
            })
        );
        vm.stopBroadcast();
    }
}
