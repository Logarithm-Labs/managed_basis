// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {SendParams} from "src/spot/crosschain/ILogarithmMessenger.sol";

contract MockMessenger {
    function quote(address sender, SendParams calldata params)
        external
        view
        returns (uint256 nativeFee, uint256 lzTokenFee)
    {
        return (0.001 ether, 0);
    }

    function sendMessage(SendParams calldata params) external payable {
        return;
    }
}
