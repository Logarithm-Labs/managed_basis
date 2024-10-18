// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {OffChainPositionManager} from "src/position/offchain/OffChainPositionManager.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DataProvider} from "src/DataProvider.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";

contract UpgradeOffChainPositionManagerScript is Script {
    UpgradeableBeacon constant beacon = UpgradeableBeacon(0x9a6bd24FC6a958d916596FF24093B0270F993b40);
    OffChainPositionManager positionManager = OffChainPositionManager(0x9901A001995230C20ba227bD006CFE9D4B3bee34);

    function run() public {
        vm.startBroadcast();
        address impl = address(new OffChainPositionManager());
        beacon.upgradeTo(impl);
        positionManager.clearIdleCollateral();
    }
}
