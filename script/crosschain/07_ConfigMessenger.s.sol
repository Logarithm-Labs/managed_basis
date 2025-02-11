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
import {ILogarithmMessenger} from "src/messenger/ILogarithmMessenger.sol";

contract ArbConfigScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    uint256 constant BSC_CHAIN_ID = 56;
    uint32 constant BSC_EID = uint32(30102);
    ILogarithmMessenger messenger = ILogarithmMessenger(ArbAddresses.LOGARITHM_MESSENGER);
    GasStation gasStation = GasStation(payable(Arb.GAS_STATION));

    function run() public {
        vm.startBroadcast();

        // gasStation.registerManager(address(messenger), true);
        // messenger.authorize(Arb.X_SPOT_MANAGER_GMX_USDC_DOGE);
        messenger.authorize(Arb.X_SPOT_MANAGER_HL_USDC_DOGE);

        messenger.updateGasStation(Arb.GAS_STATION);

        messenger.registerDstMessenger(
            BSC_CHAIN_ID, BSC_EID, AddressCast.addressToBytes32(BscAddresses.LOGARITHM_MESSENGER)
        );

        messenger.registerStargate(ArbAddresses.USDC, ArbAddresses.STARGATE_POOL_USDC);
    }
}

contract BscConfigScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    uint256 constant ARB_CHAIN_ID = 42161;
    uint32 constant ARB_EID = uint32(30110);
    ILogarithmMessenger messenger = ILogarithmMessenger(BscAddresses.LOGARITHM_MESSENGER);
    GasStation gasStation = GasStation(payable(Bsc.GAS_STATION));

    function run() public {
        vm.startBroadcast();

        gasStation.registerManager(address(messenger), true);
        // messenger.authorize(Bsc.BROTHER_SWAPPER_GMX);
        messenger.authorize(Bsc.BROTHER_SWAPPER_HL_USDC_DOGE);

        messenger.updateGasStation(Bsc.GAS_STATION);

        messenger.registerDstMessenger(
            ARB_CHAIN_ID, ARB_EID, AddressCast.addressToBytes32(ArbAddresses.LOGARITHM_MESSENGER)
        );

        messenger.registerStargate(BscAddresses.USDC, BscAddresses.STARGATE_POOL_USDC);
    }
}
