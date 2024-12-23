// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {Bsc} from "script/utils/ProtocolAddresses.sol";

contract UpgradeSwapperScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(Bsc.BEACON_BROTHER_SWAPPER);

    function run() public {
        vm.startBroadcast();
        beacon.upgradeTo(address(new BrotherSwapper()));
    }
}
