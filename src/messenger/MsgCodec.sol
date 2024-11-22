// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {AddressCast} from "src/libraries/utils/AddressCast.sol";

library MsgCodec {
    uint8 internal constant SENDER_OFFSET = 0;
    uint8 internal constant RECEIVER_OFFSET = 32;
    uint8 internal constant VALUE_OFFSET = 64;
    uint8 internal constant PAYLOAD_OFFSET = 80;

    function encode(address _sender, bytes32 _receiver, uint128 _value, bytes calldata _payload)
        internal
        pure
        returns (bytes memory _message)
    {
        _message = abi.encodePacked(AddressCast.addressToBytes32(_sender), _receiver, _value, _payload);
    }

    function sender(bytes calldata _message) internal pure returns (bytes32) {
        return bytes32(_message[SENDER_OFFSET:RECEIVER_OFFSET]);
    }

    function receiver(bytes calldata _message) internal pure returns (bytes32) {
        return bytes32(_message[RECEIVER_OFFSET:VALUE_OFFSET]);
    }

    function value(bytes calldata _message) internal pure returns (uint128) {
        return uint128(bytes16(_message[VALUE_OFFSET:PAYLOAD_OFFSET]));
    }

    function payload(bytes calldata _message) internal pure returns (bytes memory) {
        return bytes(_message[PAYLOAD_OFFSET:]);
    }
}
