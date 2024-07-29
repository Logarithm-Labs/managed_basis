// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import "forge-std/Script.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract UpdateStrategyScript is Script {
    AccumulatedBasisStrategy public strategy = AccumulatedBasisStrategy(0xC69c6A3228BB8EE5Bdd0C656eEA43Bf8713B0740);

    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new AccumulatedBasisStrategy());
        strategy.upgradeToAndCall(strategyImpl, "");
    }
}
