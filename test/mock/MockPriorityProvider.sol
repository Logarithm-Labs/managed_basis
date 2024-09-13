// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPriorityProvider} from "src/interfaces/IPriorityProvider.sol";

contract MockPriorityProvider is IPriorityProvider {
    mapping(address => bool) _isPrioritized;

    function prioritize(address account) external {
        _isPrioritized[account] = true;
    }

    function isPrioritized(address account) external view returns (bool) {
        return _isPrioritized[account];
    }
}
