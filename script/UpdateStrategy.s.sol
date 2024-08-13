// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import "forge-std/Script.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpdateStrategyScript is Script {
    ManagedBasisStrategy public strategy = ManagedBasisStrategy(0x75032ea6f276DE687a4c7cd82BE3b91E2D321ed1);

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new ManagedBasisStrategy());
        strategy.upgradeToAndCall(strategyImpl, "");
    }
}
