// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arb, Bsc, Base} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";
import {BaseAddresses} from "script/utils/BaseAddresses.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {ILogarithmMessenger} from "src/messenger/ILogarithmMessenger.sol";

uint256 constant BSC_CHAIN_ID = 56;
uint32 constant BSC_EID = uint32(30102);
uint256 constant ARB_CHAIN_ID = 42161;
uint32 constant ARB_EID = uint32(30110);
uint256 constant BASE_CHAIN_ID = 8453;
uint32 constant BASE_EID = uint32(30184);

contract ArbConfigScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    ILogarithmMessenger messenger = ILogarithmMessenger(ArbAddresses.LOGARITHM_MESSENGER);
    GasStation gasStation = GasStation(payable(Arb.GAS_STATION));

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);

        gasStation.registerManager(address(messenger), true);

        messenger.authorize(Arb.X_SPOT_MANAGER_HL_USDC_DOGE);
        messenger.authorize(Arb.X_SPOT_MANAGER_HL_USDC_VIRTUAL);
        messenger.updateGasStation(Arb.GAS_STATION);
        messenger.registerDstMessenger(
            BSC_CHAIN_ID, BSC_EID, AddressCast.addressToBytes32(BscAddresses.LOGARITHM_MESSENGER)
        );
        messenger.registerDstMessenger(
            BASE_CHAIN_ID, BASE_EID, AddressCast.addressToBytes32(BaseAddresses.LOGARITHM_MESSENGER)
        );
        messenger.registerStargate(ArbAddresses.USDC, ArbAddresses.STARGATE_POOL_USDC);
    }
}

contract BscConfigScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    ILogarithmMessenger messenger = ILogarithmMessenger(BscAddresses.LOGARITHM_MESSENGER);
    GasStation gasStation = GasStation(payable(Bsc.GAS_STATION));

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("bnb_smart_chain");
        vm.startBroadcast(privateKey);

        gasStation.registerManager(address(messenger), true);
        messenger.authorize(Bsc.BROTHER_SWAPPER_HL_USDC_DOGE);
        messenger.updateGasStation(Bsc.GAS_STATION);
        messenger.registerDstMessenger(
            ARB_CHAIN_ID, ARB_EID, AddressCast.addressToBytes32(ArbAddresses.LOGARITHM_MESSENGER)
        );
        messenger.registerStargate(BscAddresses.USDC, BscAddresses.STARGATE_POOL_USDC);
    }
}

contract BaseConfigScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;
    ILogarithmMessenger messenger = ILogarithmMessenger(BaseAddresses.LOGARITHM_MESSENGER);
    GasStation gasStation = GasStation(payable(Base.GAS_STATION));

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("base");
        vm.startBroadcast(privateKey);

        gasStation.registerManager(address(messenger), true);
        messenger.authorize(Base.BROTHER_SWAPPER_HL_USDC_VIRTUAL);
        messenger.updateGasStation(Base.GAS_STATION);
        messenger.registerDstMessenger(
            ARB_CHAIN_ID, ARB_EID, AddressCast.addressToBytes32(ArbAddresses.LOGARITHM_MESSENGER)
        );
        messenger.registerStargate(BaseAddresses.USDC, BaseAddresses.STARGATE_POOL_USDC);

        vm.stopBroadcast();
    }
}
