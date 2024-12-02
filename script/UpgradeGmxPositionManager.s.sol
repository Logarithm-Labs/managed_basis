// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Arbitrum} from "script/utils/ProtocolAddresses.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";

contract UpgradeGmxPositionManagerScript is Script {
    UpgradeableBeacon beaconGmx = UpgradeableBeacon(Arbitrum.BEACON_GMX_POSITION_MANAGER);
    GmxConfig gmxConfig = GmxConfig(Arbitrum.CONFIG_GMX);

    function run() public {
        vm.startBroadcast();
        address newImpl = address(new GmxV2PositionManager());
        beaconGmx.upgradeTo(newImpl);
        // gmxConfig.updateAddresses(ArbiAddresses.GMX_EXCHANGE_ROUTER, ArbiAddresses.GMX_READER);
        vm.stopBroadcast();
    }
}
