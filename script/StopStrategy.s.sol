// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {Arbitrum} from "script/utils/ProtocolAddresses.sol";

contract StopStrategyScript is Script {
    BasisStrategy gmxStrategy = BasisStrategy(Arbitrum.STRATEGY_GMX_USDC_DOGE);
    BasisStrategy hlStrategy = BasisStrategy(Arbitrum.STRATEGY_HL_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        hlStrategy.unpause();
    }
}
