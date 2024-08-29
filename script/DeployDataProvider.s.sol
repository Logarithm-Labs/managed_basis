// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {DataProvider} from "src/DataProvider.sol";

contract DeployDataProviderScript is Script {
    address constant strategy = 0x881aDA5AC6F0337355a3ee923dF8bC33320d4dE1;

    function run() public {
        // deploy DataProvider
        vm.startBroadcast();
        DataProvider dataProvider = new DataProvider();
        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(strategy));
        console.log("DataProvider deployed at", address(dataProvider));
    }
}
