// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManagerOld} from "src/hedge/gmx/GmxV2PositionManagerOld.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Arbitrum} from "script/utils/ProtocolAddresses.sol";

contract UpgradeGmxPositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0x91544E205446E673aeC904c53BdB7cA9b892CD5E);
    GmxV2PositionManagerOld positionManager = GmxV2PositionManagerOld(0x5903078b87795b85388102E0881d545C0f36E231);

    function run() public {
        vm.startBroadcast();
        address positionManagerImpl = address(new GmxV2PositionManagerOld());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
        positionManager.reinitialize(Arbitrum.GAS_STATION);
        GasStation(payable(Arbitrum.GAS_STATION)).registerManager(address(positionManager), true);

        assert(positionManager.gasStation() == Arbitrum.GAS_STATION);
        assert(GasStation(payable(Arbitrum.GAS_STATION)).isRegistered(address(positionManager)));
    }
}
