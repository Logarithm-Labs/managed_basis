// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

struct SendParams {
    uint32 dstEid;
    uint128 value;
    bytes32 receiver;
    bytes payload;
    bytes lzReceiveOption;
}

interface ILogarithmMessenger {
    function quote(address sender, SendParams calldata params)
        external
        view
        returns (uint256 nativeFee, uint256 lzTokenFee);
    function sendMessage(SendParams calldata params) external payable;
}
