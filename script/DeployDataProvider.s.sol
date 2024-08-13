// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import {DataProvider} from "src/DataProvider.sol";

contract DeployDataProviderScript is Script {
    function run() public {
        vm.startBroadcast();
        address dataProvider = address(new DataProvider());
        console.log("Data Provider deployed at: ", dataProvider);
    }
}
