// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {Arb} from "script/utils/ProtocolAddresses.sol";

contract DeployScript is Script {
    // access control addresses
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // gas limit
    // gas limit of swapper.lzCompose
    uint128 constant buyReqGasLimit = 2_000_000;
    // gas limit of spotManager.receiveMessage
    uint128 constant buyResGasLimit = 2_000_000;
    // gas limit of swapper.receiveMessage
    uint128 constant sellReqGasLimit = 4_000_000;
    // gas limit of spotManager.lzCompose
    uint128 constant sellResGasLimit = 2_000_000;

    // predeployed contracts
    XSpotManager xSpotManager = XSpotManager(payable(Arb.X_SPOT_MANAGER_GMX_USDC_DOGE));

    function run() public {
        vm.startBroadcast();
        xSpotManager.setBuyReqGasLimit(buyReqGasLimit);
        xSpotManager.setBuyResGasLimit(buyResGasLimit);
        xSpotManager.setSellReqGasLimit(sellReqGasLimit);
        xSpotManager.setSellResGasLimit(sellResGasLimit);

        require(xSpotManager.buyReqGasLimit() == buyReqGasLimit);
        require(xSpotManager.buyResGasLimit() == buyResGasLimit);
        require(xSpotManager.sellReqGasLimit() == sellReqGasLimit);
        require(xSpotManager.sellResGasLimit() == sellResGasLimit);
    }
}
