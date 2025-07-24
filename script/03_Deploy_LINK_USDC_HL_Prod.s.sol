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
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract ArbDeploy is Script {
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
    address constant operator = 0x99e4314C107cc30c1Bbe54259D3Feeb62707563e;
    address constant agent = 0xa8AD2D6624f74A175808eDA525DFa4F2afBaac4e;
    address constant committer = agent;

    // vault params
    uint256 constant entryCost = 0.0035 ether; // 0.35% entry fee
    uint256 constant exitCost = 0.0035 ether; // 0.35% exit fee
    string constant vaultName = "BasisOS USDC-LINK Hyperliquid";
    string constant vaultSymbol = "basisos-usdc-link-hl";
    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.LINK; // LINK
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CHL_LINK_USD_PRICE_FEED; // Chainlink LINK-USD price feed
    uint256 constant feedHeartbeat = 24 * 3600;
    // strategy params
    uint256 constant targetLeverage = 3 ether;
    uint256 constant minLeverage = 1 ether;
    uint256 constant maxLeverage = 5 ether;
    uint256 constant safeMarginLeverage = 9 ether;
    // fee params
    uint256 constant managementFee = 0.02 ether; // 2% management fee
    uint256 constant performanceFee = 0.2 ether; // 20% performance fee
    uint256 constant hurdleRate = 0.05 ether; // 5% hurdle rate
    address constant feeRecipient = 0xF27cAf44644a4c774CDB2e6acC786c6B0fCB8dB2;
    // deposit limits
    uint256 constant userDepositLimit = type(uint256).max;
    uint256 constant vaultDepositLimit = 2_600_000 * 1e6; // 2,600,000 USDC

    address[] assetToProductSwapPath =
        [asset, ArbAddresses.UNI_V3_POOL_WETH_USDC, ArbAddresses.WETH, ArbAddresses.UNI_V3_POOL_LINK_WETH, product];

    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        // vm.createSelectFork("arbitrum_one");
        vm.startBroadcast( /* privateKey */ );

        DeployHelper.DeployHLVaultParams memory params = DeployHelper.DeployHLVaultParams({
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
            committer: committer,
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
        });

        address vault = DeployHelper.deployHLVault(params);
        DeployHelper.validateDeployHLVault(vault, params);

        uint256 balance = IERC20(asset).balanceOf(owner);
        IERC20(asset).approve(vault, balance);
        LogarithmVault(vault).deposit(balance, owner);
        uint256 shares = IERC20(vault).balanceOf(owner);
        console.log("Shares: %s", vm.toString(shares));

        vm.stopBroadcast();
    }
}
