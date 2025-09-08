// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {Arb, Bsc, Base, Eth} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {BaseAddresses} from "script/utils/BaseAddresses.sol";
import {EthAddresses} from "script/utils/EthAddresses.sol";

contract UpgradeXSpotManager is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        UpgradeableBeacon beacon = UpgradeableBeacon(Arb.BEACON_X_SPOT_MANAGER);
        beacon.upgradeTo(address(new XSpotManager()));
        vm.stopBroadcast();
    }
}

contract UpgradeBscBrotherSwapper is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        UpgradeableBeacon beacon = UpgradeableBeacon(Bsc.BEACON_BROTHER_SWAPPER);
        beacon.upgradeTo(address(new BrotherSwapper()));
        vm.stopBroadcast();
    }
}

contract UpgradeBaseBrotherSwapper is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        UpgradeableBeacon beacon = UpgradeableBeacon(Base.BEACON_BROTHER_SWAPPER);
        beacon.upgradeTo(address(new BrotherSwapper()));
        vm.stopBroadcast();
    }
}

contract PepeXSpotManagerSetMessenger is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("arbitrum_one");
        vm.startBroadcast(privateKey);
        XSpotManager(Arb.X_SPOT_MANAGER_HL_USDC_PEPE).setMessenger(ArbAddresses.CCTP_ADAPTER);
        vm.stopBroadcast();
    }
}

contract PepeBrotherSwapperSetMessenger is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.createSelectFork("mainnet");
        vm.startBroadcast(privateKey);
        BrotherSwapper(Eth.BROTHER_SWAPPER_HL_USDC_PEPE).setMessenger(EthAddresses.CCTP_ADAPTER);
        vm.stopBroadcast();
    }
}
