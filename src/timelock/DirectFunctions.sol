// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

library DirectFunctionSelectors {
    bytes4 constant SET_ENTRY_COST = bytes4(keccak256(bytes("setEntryCost(uint256)")));
    bytes4 constant SET_EXIT_COST = bytes4(keccak256(bytes("setExitCost(uint256)")));
    bytes4 constant SET_PRIORITY_PROVIDER = bytes4(keccak256(bytes("setPriorityProvider(address)")));
    bytes4 constant SHUTDOWN = bytes4(keccak256(bytes("shutdown()")));
    bytes4 constant PAUSE_WITH_OPTION = bytes4(keccak256(bytes("pause(bool)")));
    bytes4 constant UNPAUSE = bytes4(keccak256(bytes("unpause()")));
    bytes4 constant SET_WHITELIST_PROVIDER = bytes4(keccak256(bytes("setWhitelistProvider(address)")));
    bytes4 constant SET_DEPOSIT_LIMITS = bytes4(keccak256(bytes("setDepositLimits(uint256,uint256)")));
    bytes4 constant PAUSE = bytes4(keccak256(bytes("pause()")));
    bytes4 constant STOP = bytes4(keccak256(bytes("stop()")));
}
