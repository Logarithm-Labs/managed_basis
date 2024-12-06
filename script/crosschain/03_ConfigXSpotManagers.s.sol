// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {Arbitrum, Bsc} from "script/utils/ProtocolAddresses.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // predeployed contracts
    XSpotManager gmxXSpotManager = XSpotManager(Arbitrum.X_SPOT_MANAGER_GMX_USDC_DOGE);
    XSpotManager hlXSpotManager = XSpotManager(Arbitrum.X_SPOT_MANAGER_HL_USDC_DOGE);
    bytes32 gmxSwapper = AddressCast.addressToBytes32(Bsc.BROTHER_SWAPPER_GMX);
    bytes32 hlSwapper = AddressCast.addressToBytes32(Bsc.BROTHER_SWAPPER_HL);

    function run() public {
        vm.startBroadcast();
        gmxXSpotManager.setSwapper(gmxSwapper);
        hlXSpotManager.setSwapper(hlSwapper);
    }
}
