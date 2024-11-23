// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SendParams} from "src/spot/crosschain/ILogarithmMessenger.sol";

contract MockMessenger {
    function quote(address, SendParams calldata) external pure returns (uint256, uint256) {
        return (0.001 ether, 0);
    }

    function sendMessage(SendParams calldata) external payable {
        return;
    }
}
