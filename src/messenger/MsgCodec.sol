// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

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
        _message = abi.encodePacked(addressToBytes32(_sender), _receiver, _value, _payload);
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

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The bytes32 representation of the address.
     */
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /**
     * @dev Converts bytes32 to an address.
     * @param _b The bytes32 value to convert.
     * @return The address representation of bytes32.
     */
    function bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }
}
