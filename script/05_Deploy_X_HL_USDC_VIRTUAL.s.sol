// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {BaseAddresses} from "script/utils/BaseAddresses.sol";
import {Arb, Base} from "script/utils/ProtocolAddresses.sol";
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
import {ChainlinkFeedWrapper} from "src/oracle/ChainlinkFeedWrapper.sol";

contract DeployCLWrapper is Script {
    address customPriceFeedVirtual = 0x3a84cff0574a016F2F735842353845917b2168a7;

    function run() public {
        vm.startBroadcast();
        ChainlinkFeedWrapper wrapper = new ChainlinkFeedWrapper(customPriceFeedVirtual);
        console.log("CustomFeed(VIRTUAL)", address(wrapper));
        vm.stopBroadcast();
    }
}

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
    // strategy params
    uint256 constant targetLeverage = 4 ether; // 4x leverage
    uint256 constant minLeverage = 2 ether; // 2x leverage
    uint256 constant maxLeverage = 6 ether; // 6x leverage
    uint256 constant safeMarginLeverage = 7 ether; // 6x leverage

    uint256 constant BASE_CHAIN_ID = 8453;

    function run() public {
        vm.startBroadcast();

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
                dstChainId: BASE_CHAIN_ID
            })
        );

        vm.stopBroadcast();
    }
}

contract BaseDeploy is Script {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    address[] assetToProductSwapPath = [
        BaseAddresses.USDC,
        BaseAddresses.UNI_V3_POOL_WETH_USDC,
        BaseAddresses.WETH,
        BaseAddresses.UNI_V3_POOL_VIRTUAL_WETH,
        BaseAddresses.VIRTUAL
    ];

    uint256 constant ARB_CHAIN_ID = 42161;

    // Strategy Addresses
    address constant asset = BaseAddresses.USDC; // USDC
    address constant product = BaseAddresses.VIRTUAL; // VIRTUAL

    // predeployed contracts
    bytes32 xSpotManager = AddressCast.addressToBytes32(Arb.X_SPOT_MANAGER_HL_USDC_VIRTUAL);

    function run() public {
        vm.startBroadcast();

        // deploy BrotherSwapper
        DeployHelper.DeployBrotherSwapperParams memory swapperDeployParams = DeployHelper.DeployBrotherSwapperParams({
            beacon: Base.BEACON_BROTHER_SWAPPER,
            owner: owner,
            asset: asset,
            product: product,
            messenger: BaseAddresses.LOGARITHM_MESSENGER,
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
    XSpotManager xSpotManager = XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_VIRTUAL);
    bytes32 swapper = AddressCast.addressToBytes32(Base.BROTHER_SWAPPER_HL_USDC_VIRTUAL);

    function run() public {
        vm.startBroadcast();
        XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_VIRTUAL).setSwapper(swapper);

        // hlXSpotManager.setBuyReqGasLimit(1_000_000);
        // hlXSpotManager.setBuyResGasLimit(800_000);
        // hlXSpotManager.setSellReqGasLimit(1_000_000);
        // hlXSpotManager.setSellResGasLimit(800_000);
    }
}
