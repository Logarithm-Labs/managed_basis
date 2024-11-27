// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GmxV2PositionManager} from "src/position/gmx/GmxV2PositionManager.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {DataProvider} from "src/DataProvider.sol";
import {GmxConfig} from "src/position/gmx/GmxConfig.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract UpgradeGmxPositionManagerScript is Script {
    UpgradeableBeacon positionManagerBeacon = UpgradeableBeacon(0x91544E205446E673aeC904c53BdB7cA9b892CD5E);
    GmxV2PositionManager positionManager = GmxV2PositionManager(0x5903078b87795b85388102E0881d545C0f36E231);
    GmxConfig gmxConfig = GmxConfig(0x611169E7e9C70F23E1F9C067Ee23A3B78F3c34BF);
    BasisStrategy gmxStrategy = BasisStrategy(0x166350f9b64ED99B2Aa92413A773aDCEDa1E1438);
    DataProvider dataProvider = DataProvider(0x8B92925a63B580A9bBD9e0D8D185aDea850160A8);

    function run() public {
        vm.startBroadcast();
        gmxConfig.updateAddresses(ArbiAddresses.GMX_EXCHANGE_ROUTER, ArbiAddresses.GMX_READER);
        address positionManagerImpl = address(new GmxV2PositionManager());
        positionManagerBeacon.upgradeTo(positionManagerImpl);
        positionManager.reinitialize();
        gmxStrategy.unpause();

        DataProvider.StrategyState memory state = dataProvider.getStrategyState(address(gmxStrategy));
        assert(uint8(state.strategyStatus) == uint8(0));
        assert(state.productBalance == 0);
        assert(!gmxStrategy.paused());
    }
}
