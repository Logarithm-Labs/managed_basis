// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // Strategy Addresses
    address constant asset = BscAddresses.USDC; // USDC
    address constant product = BscAddresses.DOGE; // DOGE

    uint256 constant ARB_CHAIN_ID = 42161;

    // predeployed contracts
    bytes32 xSpotManagerGmx = AddressCast.addressToBytes32(Arb.X_SPOT_MANAGER_GMX_USDC_DOGE);
    bytes32 xSpotManagerHL = AddressCast.addressToBytes32(Arb.X_SPOT_MANAGER_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();

        // deploy gasStation
        GasStation gasStation = DeployHelper.deployGasStation(owner);
        console.log("GasStation: ", address(gasStation));

        // deploy BrotherSwapper beacon
        address swapperBeacon = DeployHelper.deployBeacon(address(new BrotherSwapper()), owner);
        console.log("Beacon(BrotherSwapper): ", swapperBeacon);

        address[] memory path = new address[](5);
        path[0] = BscAddresses.USDC;
        path[1] = BscAddresses.PCS_V3_POOL_WBNB_USDC;
        path[2] = BscAddresses.WBNB;
        path[3] = BscAddresses.PCS_V3_POOL_DOGE_WBNB;
        path[4] = BscAddresses.DOGE;

        // deploy BrotherSwapper of GMX
        DeployHelper.DeployBrotherSwapperParams memory swapperDeployParams = DeployHelper.DeployBrotherSwapperParams({
            beacon: swapperBeacon,
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
    }
}
