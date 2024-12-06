// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

struct SendParams {
    uint256 dstChainId;
    bytes32 receiver;
    address token;
    uint128 gasLimit;
    uint256 amount;
    bytes data;
}

interface ILogarithmMessenger {
    function authorize(address account) external;
    function unauthorize(address account) external;
    function updateGasStation(address newGasStation) external;
    function registerDstMessenger(uint256 chainId, uint32 lzEid, bytes32 dstMessenger) external;
    function registerStargate(address token, address stargate) external;
    function send(SendParams calldata params) external payable;
}
