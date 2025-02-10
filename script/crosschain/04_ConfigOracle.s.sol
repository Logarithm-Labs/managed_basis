// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // predeployed contracts
    LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
    GmxV2PositionManager gmxManager = GmxV2PositionManager(Arb.GMX_POSITION_MANAGER_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);
        assets[0] = ArbiAddresses.USDC;
        assets[1] = ArbiAddresses.WETH;
        feeds[0] = ArbiAddresses.CHL_USDC_USD_PRICE_FEED;
        feeds[1] = ArbiAddresses.CHL_ETH_USD_PRICE_FEED;
        oracle.setPriceFeeds(assets, feeds);
    }
}
