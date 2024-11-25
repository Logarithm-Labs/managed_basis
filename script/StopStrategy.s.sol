// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";

contract StopStrategyScript is Script {
    BasisStrategy gmxStrategy = BasisStrategy(0x166350f9b64ED99B2Aa92413A773aDCEDa1E1438);
    BasisStrategy hlStrategy = BasisStrategy(0x6f4C89Ab99Cf5f8EA938D8899a8B1bC99a8656e4);

    function run() public {
        vm.startBroadcast();
        hlStrategy.stop();
    }
}
