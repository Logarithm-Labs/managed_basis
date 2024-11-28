// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {Arbitrum, Bsc} from "script/utils/ProtocolAddresses.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // predeployed contracts
    LogarithmOracle oracle = LogarithmOracle(Arbitrum.ORACLE);
    GmxV2PositionManager gmxManager = GmxV2PositionManager(Arbitrum.GMX_POSITION_MANAGER_USDC_DOGE);

    function run() public {
        vm.startBroadcast();
        oracle.upgradeToAndCall(address(new LogarithmOracle()), "");
        // configure oracle for GMX index token
        address gmxIndexToken = gmxManager.indexToken();
        require(gmxIndexToken != address(0));
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        uint8[] memory decimals = new uint8[](1);
        assets[0] = gmxIndexToken;
        feeds[0] = ArbiAddresses.CHL_DOGE_USD_PRICE_FEED;
        decimals[0] = uint8(8);
        oracle.setPriceFeeds(assets, feeds);
        oracle.setAssetDecimals(assets, decimals);
    }
}
