// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arbitrum, Bsc} from "script/utils/ProtocolAddresses.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {BscAddresses} from "script/utils/BscAddresses.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {ILogarithmMessenger} from "src/messenger/ILogarithmMessenger.sol";

contract ArbUpdateMessengerScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    XSpotManager gmxSpotManager = XSpotManager(Arbitrum.X_SPOT_MANAGER_GMX_USDC_DOGE);
    XSpotManager hlSpotManager = XSpotManager(Arbitrum.X_SPOT_MANAGER_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        gmxSpotManager.setMessenger(ArbiAddresses.LOGARITHM_MESSENGER);
        hlSpotManager.setMessenger(ArbiAddresses.LOGARITHM_MESSENGER);
    }
}

contract BscUpdateMessengerScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    BrotherSwapper gmxSwapper = BrotherSwapper(Bsc.BROTHER_SWAPPER_GMX);
    BrotherSwapper hlSwapper = BrotherSwapper(Bsc.BROTHER_SWAPPER_HL);

    function run() public {
        vm.startBroadcast();
        gmxSwapper.setMessenger(BscAddresses.LOGARITHM_MESSENGER);
        hlSwapper.setMessenger(BscAddresses.LOGARITHM_MESSENGER);
    }
}
