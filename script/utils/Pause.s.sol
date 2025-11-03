// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {Script} from "forge-std/Script.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";

contract PauseScript is Script {
    address public owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

    function run() public {
        vm.startBroadcast();
        address vault = Arb.VAULT_HL_USDC_VIRTUAL;
        LogarithmVault(vault).unpause();
        LogarithmVault(vault).shutdown();
        vm.stopBroadcast();
    }
}
