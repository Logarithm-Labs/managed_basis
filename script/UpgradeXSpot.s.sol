// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arbitrum} from "script/utils/ProtocolAddresses.sol";

contract UpgradeXSpotScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(Arbitrum.BEACON_X_SPOT_MANAGER);
    XSpotManager hlSpot = XSpotManager(Arbitrum.X_SPOT_MANAGER_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        beacon.upgradeTo(address(new XSpotManager()));
        hlSpot.reinitialize();
    }
}
