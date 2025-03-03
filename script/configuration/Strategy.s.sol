// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";

contract UpgradeStrategyScript is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        UpgradeableBeacon beacon = UpgradeableBeacon(Arb.BEACON_STRATEGY);
        beacon.upgradeTo(address(new BasisStrategy()));
        vm.stopBroadcast();
    }
}

contract SetMaxUtilizePct is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        BasisStrategy wethStrategy = BasisStrategy(Arb.STRATEGY_HL_USDC_WETH);
        BasisStrategy wbtcStrategy = BasisStrategy(Arb.STRATEGY_HL_USDC_WBTC);
        BasisStrategy dogeStrategy = BasisStrategy(Arb.STRATEGY_HL_USDC_DOGE);
        BasisStrategy virtualStrategy = BasisStrategy(Arb.STRATEGY_HL_USDC_VIRTUAL);
        wethStrategy.setMaxUtilizePct(1 ether);
        wbtcStrategy.setMaxUtilizePct(1 ether);
        dogeStrategy.setMaxUtilizePct(1 ether);
        virtualStrategy.setMaxUtilizePct(1 ether);
        vm.stopBroadcast();
    }
}
