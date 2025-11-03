// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "forge-std/Script.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";

contract UpdatePriceFeed is Script {
    address constant product = ArbAddresses.VIRTUAL;
    address constant priceFeed = 0xFF71AcB229dEB9B29bd4993930cC13661c156e21;

    function run() public {
        LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
        vm.startBroadcast();
        address[] memory assets = new address[](1);
        assets[0] = product;
        address[] memory feeds = new address[](1);
        feeds[0] = priceFeed;
        uint256[] memory heartbeats = new uint256[](1);
        heartbeats[0] = 24 * 3600;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        vm.stopBroadcast();

        uint256 price = oracle.getAssetPrice(product);
        console.log("price", vm.toString(price));
    }
}

contract UpgradeLogarithmOracle is Script {
    function run() public {
        vm.startBroadcast();
        LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
        oracle.upgradeToAndCall(address(new LogarithmOracle()), "");
        vm.stopBroadcast();
    }
}
