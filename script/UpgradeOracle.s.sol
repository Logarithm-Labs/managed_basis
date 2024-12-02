// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {Arbitrum} from "script/utils/ProtocolAddresses.sol";

contract UpgradeOracleScript is Script {
    LogarithmOracle public oracle = LogarithmOracle(Arbitrum.ORACLE);

    function run() public {
        vm.startBroadcast();
        // upgrade oracle beacon
        address oracleImpl = address(new LogarithmOracle());
        oracle.upgradeToAndCall(oracleImpl, "");
        vm.stopBroadcast();
    }
}
