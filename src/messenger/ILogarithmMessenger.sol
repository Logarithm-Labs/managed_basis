// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

interface ILogarithmMessenger {
    struct QuoteParam {
        address sender;
        uint32 dstEid;
        bytes32 receiver;
        bytes payload;
        bytes lzReceiveOption;
    }

    struct SendParam {
        uint32 dstEid;
        bytes32 receiver;
        bytes payload;
        bytes lzReceiveOption;
    }

    function quote(QuoteParam calldata param) external view returns (uint256 nativeFee, uint256 lzTokenFee);
    function sendMessage(SendParam calldata param) external payable;
}
