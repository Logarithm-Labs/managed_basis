// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";

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
    address constant operator = 0xC3AcB9dF13095E7A27919D78aD8323CF7717Bb16;
    address constant agent = 0xA184231aAE8DE21E7FcD962746Ef350CbB650FbD;

    // vault params
    uint256 constant entryCost = 0.004 ether; // 0.4% entry fee
    uint256 constant exitCost = 0.004 ether; // 0.4% exit fee
    string constant vaultName = "Logarithm Basis USDC-DOGE Hyperliquid (Alpha)";
    string constant vaultSymbol = "log-b-usdc-doge-hl-a";
    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.DOGE; // DOGE
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CHL_DOGE_USD_PRICE_FEED; // Chainlink DOGE-USD price feed
    uint256 constant feedHeartbeat = 24 * 3600;
    // strategy params
    uint256 constant targetLeverage = 4 ether;
    uint256 constant minLeverage = 1 ether;
    uint256 constant maxLeverage = 7 ether;
    uint256 constant safeMarginLeverage = 15 ether;

    uint256 constant BSC_CHAIN_ID = 56;

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);

        DeployHelper.deployHLVaultX(
            DeployHelper.DeployHLVaultXParams({
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
                dstChainId: BSC_CHAIN_ID
            })
        );

        vm.stopBroadcast();
    }
}

contract BscDeploy is Script {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    address[] assetToProductSwapPath = [
        BscAddresses.USDC,
        BscAddresses.PCS_V3_POOL_WBNB_USDC,
        BscAddresses.WBNB,
        BscAddresses.PCS_V3_POOL_DOGE_WBNB,
        BscAddresses.DOGE
    ];

    uint256 constant ARB_CHAIN_ID = 42161;

    // Strategy Addresses
    address constant asset = BscAddresses.USDC; // USDC
    address constant product = BscAddresses.DOGE; // DOGE

    // predeployed contracts
    bytes32 xSpotManager = AddressCast.addressToBytes32(Arb.X_SPOT_MANAGER_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();

        // deploy BrotherSwapper
        DeployHelper.DeployBrotherSwapperParams memory swapperDeployParams = DeployHelper.DeployBrotherSwapperParams({
            beacon: Bsc.BEACON_BROTHER_SWAPPER,
            owner: owner,
            asset: asset,
            product: product,
            messenger: BscAddresses.LOGARITHM_MESSENGER,
            spotManager: xSpotManager,
            dstChainId: ARB_CHAIN_ID,
            assetToProductSwapPath: assetToProductSwapPath
        });
        BrotherSwapper swapper = DeployHelper.deployBrotherSwapper(swapperDeployParams);
        console.log("BrotherSwapper: ", address(swapper));

        vm.stopBroadcast();
    }
}

contract ConfigXSpot is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // predeployed contracts
    XSpotManager xSpotManager = XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_DOGE);
    bytes32 swapper = AddressCast.addressToBytes32(Bsc.BROTHER_SWAPPER_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_DOGE).setSwapper(swapper);

        // hlXSpotManager.setBuyReqGasLimit(1_000_000);
        // hlXSpotManager.setBuyResGasLimit(800_000);
        // hlXSpotManager.setSellReqGasLimit(1_000_000);
        // hlXSpotManager.setSellResGasLimit(800_000);
    }
}
