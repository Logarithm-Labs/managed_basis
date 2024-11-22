// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {AddressCast} from "src/libraries/utils/AddressCast.sol";

contract MockMessageRecipient {
    address public caller;
    address public sender;
    uint64 public amount;

    function receiveMessage(bytes32 _sender, bytes calldata _payload) external payable {
        caller = msg.sender;
        sender = AddressCast.bytes32ToAddress(_sender);
        amount = abi.decode(_payload, (uint64));
    }
}
