// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SendParams, ILogarithmMessenger} from "src/messenger/ILogarithmMessenger.sol";
import {IMessageRecipient} from "src/messenger/IMessageRecipient.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";

contract MockMessenger is ILogarithmMessenger {
    function send(SendParams calldata params) external payable {
        address receiver = AddressCast.bytes32ToAddress(params.receiver);
        if (params.amount > 0) {
            IERC20(params.token).transfer(receiver, params.amount);
            IMessageRecipient(receiver).receiveToken(
                AddressCast.addressToBytes32(msg.sender), params.token, params.amount, params.data
            );
        } else {
            IMessageRecipient(receiver).receiveMessage(AddressCast.addressToBytes32(msg.sender), params.data);
        }
    }
}
