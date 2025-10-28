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

address constant operator = 0x00602eCED20b217747f87b6EE08D64a8FD214a64;
address constant agent = 0x9a66B886995274E0914a202EC73E376cfb0EFB2D;
address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
address constant committer = 0xB065eeEd0f9403AdacC7706726d98471995ACE76;
address constant securityManager = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;

contract ArbDeploy is Script {
    // vault params
    uint256 constant entryCost = 0.001 ether; // 0.1% entry cost
    uint256 constant exitCost = 0.001 ether; // 0.1% exit cost
    string constant vaultName = "BasisOS USDC-VIRTUAL Hyperliquid";
    string constant vaultSymbol = "basisos-usdc-virtual-hl";
    // Strategy Addresses
    address constant asset = ArbAddresses.USDC; // USDC
    address constant product = ArbAddresses.VIRTUAL; // VIRTUAL
    address constant assetPriceFeed = ArbAddresses.CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0xFF71AcB229dEB9B29bd4993930cC13661c156e21; // Custom VIRTUAL-USD price feed
    uint256 constant feedHeartbeat = 24 * 3600;
    // strategy params
    uint256 constant targetLeverage = 3 ether;
    uint256 constant minLeverage = 1 ether;
    uint256 constant maxLeverage = 4 ether;
    uint256 constant safeMarginLeverage = 4.5 ether;

    address feeRecipient = 0xF27cAf44644a4c774CDB2e6acC786c6B0fCB8dB2;
    uint256 managementFee = 0.02 ether; // 2% management fee
    uint256 performanceFee = 0.2 ether; // 20% performance fee
    uint256 hurdleRate = 0.1095 ether; // 10.95% hurdle rate
    uint256 userDepositLimit = type(uint256).max;
    uint256 vaultDepositLimit = 4_000_000 * 1e6;

    uint256 constant BASE_CHAIN_ID = 8453;

    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast( /* privateKey */ );

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
                committer: committer,
                securityManager: securityManager,
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
                dstChainId: BASE_CHAIN_ID
            })
        );

        vm.stopBroadcast();
    }
}

contract BaseDeploy is Script {
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
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast( /* privateKey */ );

        // deploy BrotherSwapper
        DeployHelper.DeployBrotherSwapperParams memory swapperDeployParams = DeployHelper.DeployBrotherSwapperParams({
            beacon: Base.BEACON_BROTHER_SWAPPER,
            owner: owner,
            operator: operator,
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
    // predeployed contracts
    XSpotManager xSpotManager = XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_VIRTUAL);
    bytes32 swapper = AddressCast.addressToBytes32(Base.BROTHER_SWAPPER_HL_USDC_VIRTUAL);

    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast( /* privateKey */ );
        XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_VIRTUAL).setSwapper(swapper);
    }
}
