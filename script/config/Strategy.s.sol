// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {Arb} from "script/utils/ProtocolAddresses.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";

contract StrategyConfigScript is Script {
    function run() public {
        vm.startBroadcast();
        StrategyConfig config = StrategyConfig(Arb.CONFIG_STRATEGY);
        require(config.responseDeviationThreshold() == 0.01 ether);
        config.setResponseDeviationThreshold(0.035 ether);
        require(config.responseDeviationThreshold() == 0.035 ether);
        vm.stopBroadcast();
    }
}
