// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {Script} from "forge-std/Script.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";

contract UpgradeOffChainPositionManager is Script {
    function run() public {
        vm.startBroadcast();
        address hedgeManagerImpl = address(new OffChainPositionManager());
        UpgradeableBeacon offChainPositionManagerBeacon = UpgradeableBeacon(Arb.BEACON_OFF_CHAIN_POSITION_MANAGER);
        offChainPositionManagerBeacon.upgradeTo(hedgeManagerImpl);

        address committer = 0xB065eeEd0f9403AdacC7706726d98471995ACE76;
        OffChainPositionManager(Arb.OFF_CHAIN_POSITION_MANAGER_HL_USDC_LINK).setCommitter(committer);
        vm.stopBroadcast();
    }
}

contract SetOffChainConfig is Script {
    function run() public {
        address config = address(OffChainPositionManager(Arb.HEDGE_MANAGER_HL_USDC_WBTC).config());
        vm.startBroadcast();
        OffChainConfig(config).setSizeMin(1000000000, 1000000000);
        vm.stopBroadcast();
    }
}
