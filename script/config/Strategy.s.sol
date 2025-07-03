// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {Arb} from "script/utils/ProtocolAddresses.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradeStrategy is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        address strategyImpl = address(new BasisStrategy());
        UpgradeableBeacon strategyBeacon = UpgradeableBeacon(Arb.BEACON_STRATEGY);
        strategyBeacon.upgradeTo(strategyImpl);
        vm.stopBroadcast();
    }
}

contract StrategyConfigScript is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        StrategyConfig config = StrategyConfig(Arb.CONFIG_STRATEGY);
        require(config.responseDeviationThreshold() == 0.1 ether);
        config.setResponseDeviationThreshold(0.035 ether);
        require(config.responseDeviationThreshold() == 0.035 ether);

        require(config.rebalanceDeviationThreshold() == 0.035 ether);
        config.setRebalanceDeviationThreshold(0.1 ether);
        require(config.rebalanceDeviationThreshold() == 0.1 ether);

        require(config.withdrawBufferThreshold() == 0.01 ether);

        vm.stopBroadcast();
    }
}

contract UpgradeStrategyConfig is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        // upgrade config
        StrategyConfig config = StrategyConfig(Arb.CONFIG_STRATEGY);
        config.upgradeToAndCall(address(new StrategyConfig()), "");

        // upgrade strategy
        address strategyImpl = address(new BasisStrategy());
        UpgradeableBeacon strategyBeacon = UpgradeableBeacon(Arb.BEACON_STRATEGY);
        strategyBeacon.upgradeTo(strategyImpl);

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
