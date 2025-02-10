// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";

contract ArbDeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    uint256 constant BSC_CHAIN_ID = 56;

    function run() public {
        vm.startBroadcast();
        UpgradeableBeacon(Arb.BEACON_X_SPOT_MANAGER).upgradeTo(address(new XSpotManager()));

        // deploy Gmx spot manager
        DeployHelper.DeployXSpotManagerParams memory xSpotDeployParams = DeployHelper.DeployXSpotManagerParams({
            beacon: Arb.BEACON_X_SPOT_MANAGER,
            owner: owner,
            strategy: Arb.STRATEGY_GMX_USDC_DOGE,
            messenger: ArbAddresses.LOGARITHM_MESSENGER,
            dstChainId: BSC_CHAIN_ID
        });
        XSpotManager gmxXSpotManager = DeployHelper.deployXSpotManager(xSpotDeployParams);
        console.log("XSpotManager(GMX)-USDC-DOGE: ", address(gmxXSpotManager));

        // deploy HL spot manager
        xSpotDeployParams.strategy = Arb.STRATEGY_HL_USDC_DOGE;
        XSpotManager hlXSpotManager = DeployHelper.deployXSpotManager(xSpotDeployParams);
        console.log("XSpotManager(HL)-USDC-DOGE: ", address(hlXSpotManager));

        // register messenger to gas station
        GasStation(payable(Arb.GAS_STATION)).registerManager(ArbAddresses.LOGARITHM_MESSENGER, true);
    }
}

contract BscDeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    uint256 constant ARB_CHAIN_ID = 42161;
    // Strategy Addresses
    address constant asset = BscAddresses.USDC; // USDC
    address constant product = BscAddresses.DOGE; // DOGE

    // predeployed contracts
    bytes32 xSpotManagerGmx = AddressCast.addressToBytes32(Arb.X_SPOT_MANAGER_GMX_USDC_DOGE);
    bytes32 xSpotManagerHL = AddressCast.addressToBytes32(Arb.X_SPOT_MANAGER_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        UpgradeableBeacon(Bsc.BEACON_BROTHER_SWAPPER).upgradeTo(address(new BrotherSwapper()));

        address[] memory path = new address[](5);
        path[0] = BscAddresses.USDC;
        path[1] = BscAddresses.PCS_V3_POOL_WBNB_USDC;
        path[2] = BscAddresses.WBNB;
        path[3] = BscAddresses.PCS_V3_POOL_DOGE_WBNB;
        path[4] = BscAddresses.DOGE;

        // deploy BrotherSwapper of GMX
        DeployHelper.DeployBrotherSwapperParams memory swapperDeployParams = DeployHelper.DeployBrotherSwapperParams({
            beacon: Bsc.BEACON_BROTHER_SWAPPER,
            owner: owner,
            asset: asset,
            product: product,
            messenger: BscAddresses.LOGARITHM_MESSENGER,
            spotManager: xSpotManagerGmx,
            dstChainId: ARB_CHAIN_ID,
            assetToProductSwapPath: path
        });
        BrotherSwapper swapperGmx = DeployHelper.deployBrotherSwapper(swapperDeployParams);
        console.log("BrotherSwapper(GMX): ", address(swapperGmx));

        // deploy BrotherSwapper of HL
        swapperDeployParams.spotManager = xSpotManagerHL;
        BrotherSwapper swapperHL = DeployHelper.deployBrotherSwapper(swapperDeployParams);
        console.log("BrotherSwapper(HL): ", address(swapperHL));

        // register messenger to gas station
        GasStation(payable(Bsc.GAS_STATION)).registerManager(BscAddresses.LOGARITHM_MESSENGER, true);
    }
}
