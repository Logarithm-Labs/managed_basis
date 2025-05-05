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
    address constant operator = 0x78057a43dDc57792340BC19E50e1011F8DAdEd01;
    address constant agent = 0xA2a7e3a770c38aAe24F175a38281f74731Fe477E;

    // vault params
    uint256 constant entryCost = 0.0035 ether; // 0.35% entry fee
    uint256 constant exitCost = 0.0035 ether; // 0.2% exit fee
    string constant vaultName = "Logarithm Basis USDC-WETH Hyperliquid (Alpha)";
    string constant vaultSymbol = "log-b-usdc-weth-hl-a";
    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.WETH; // WETH
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
    uint256 constant feedHeartbeat = 24 * 3600;
    // strategy params
    uint256 constant targetLeverage = 5 ether;
    uint256 constant minLeverage = 1 ether;
    uint256 constant maxLeverage = 9 ether;
    uint256 constant safeMarginLeverage = 20 ether; // 20x leverage

    address feeRecipient = address(0);
    uint256 managementFee = 0;
    uint256 performanceFee = 0;
    uint256 hurdleRate = 0;
    uint256 userDepositLimit = type(uint256).max;
    uint256 vaultDepositLimit = type(uint256).max;

    address[] assetToProductSwapPath = [asset, ArbAddresses.UNI_V3_POOL_WETH_USDC, product];

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
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
                minLeverage: minLeverage,
                maxLeverage: maxLeverage,
                safeMarginLeverage: safeMarginLeverage,
                feeRecipient: feeRecipient,
                managementFee: managementFee,
                performanceFee: performanceFee,
                hurdleRate: hurdleRate,
                userDepositLimit: userDepositLimit,
                vaultDepositLimit: vaultDepositLimit,
                assetToProductSwapPath: assetToProductSwapPath
            })
        );
        vm.stopBroadcast();
    }
}
