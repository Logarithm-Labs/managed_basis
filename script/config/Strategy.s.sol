// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {Arb} from "script/utils/ProtocolAddresses.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

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

contract UpgradeStrategyConfig is Script {
    function run() public {
        vm.startBroadcast();
        // upgrade config
        StrategyConfig config = StrategyConfig(Arb.CONFIG_STRATEGY);
        config.upgradeToAndCall(
            address(new StrategyConfig()),
            abi.encodeWithSelector(StrategyConfig.setWithdrawBufferThreshold.selector, 0.01 ether)
        );

        vm.stopBroadcast();
    }
}

contract UpgradeStrategy is Script {
    function run() public {
        vm.startBroadcast();
        address strategyImpl = address(new BasisStrategy());
        UpgradeableBeacon strategyBeacon = UpgradeableBeacon(Arb.BEACON_STRATEGY);
        strategyBeacon.upgradeTo(strategyImpl);
        vm.stopBroadcast();
    }
}

contract SetLeverages is Script {
    address public strategy = Arb.STRATEGY_HL_USDC_LINK;
    uint256 constant targetLeverage = 4 ether;
    uint256 constant minLeverage = 1 ether;
    uint256 constant maxLeverage = 7 ether;
    uint256 constant safeMarginLeverage = 9 ether;

    function run() public {
        vm.startBroadcast();
        BasisStrategy(strategy).setLeverages(targetLeverage, minLeverage, maxLeverage, safeMarginLeverage);
        vm.stopBroadcast();

        require(BasisStrategy(strategy).targetLeverage() == targetLeverage);
        require(BasisStrategy(strategy).minLeverage() == minLeverage);
        require(BasisStrategy(strategy).maxLeverage() == maxLeverage);
        require(BasisStrategy(strategy).safeMarginLeverage() == safeMarginLeverage);
    }
}
