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
    address constant operator = 0xBD3F4f622df9690e9202d6c8D7Fbdf2763D0B89f;
    address constant agent = 0x0473174dA33598Aad43357644bFDf79f9d3167bA;

    // vault params
    uint256 constant entryCost = 0.005 ether; // 0.5% entry fee
    uint256 constant exitCost = 0.005 ether; // 0.5% exit fee
    string constant vaultName = "Logarithm Basis USDC-VIRTUAL Hyperliquid (Alpha)";
    string constant vaultSymbol = "log-b-usdc-virtual-hl-a";
    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.VIRTUAL; // VIRTUAL
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = ArbAddresses.CUSTOM_VIRTUAL_USD_PRICE_FEED; // Custom VIRTUAL-USD price feed
    uint256 constant feedHeartbeat = 24 * 3600;
    bool constant isLong = false;
    // strategy params
    uint256 constant targetLeverage = 4 ether; // 4x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 6 ether; // 6x leverage
    uint256 constant safeMarginLeverage = 6 ether; // 6x leverage

    uint256 constant BASE_CHAIN_ID = 8453;

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

        // deploy XSpotManager
        // deploy Gmx spot manager
        DeployHelper.DeployXSpotManagerParams memory xSpotDeployParams = DeployHelper.DeployXSpotManagerParams({
            beacon: Arb.BEACON_X_SPOT_MANAGER,
            owner: owner,
            strategy: address(strategy),
            messenger: ArbAddresses.LOGARITHM_MESSENGER,
            dstChainId: BASE_CHAIN_ID
        });
        XSpotManager xSpotManager = DeployHelper.deployXSpotManager(xSpotDeployParams);
        console.log("XSpotManager: ", address(xSpotManager));

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

contract BaseDeploy is Script {
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
