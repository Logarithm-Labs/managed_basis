// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";

contract UpgradePositionManagerScript is Script {
    OffChainPositionManager public positionManger = OffChainPositionManager(0x554F54caEA7c2EDA630F9d71fa03d58F9B30D1e0);

    function run() public {
        vm.startBroadcast();
        address positionManagerImpl = address(new OffChainPositionManager());
        positionManger.upgradeToAndCall(positionManagerImpl, "");
    }
}
