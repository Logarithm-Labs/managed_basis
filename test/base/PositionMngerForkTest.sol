// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "./ForkTest.sol";

import {IPositionManager} from "src/interfaces/IPositionManager.sol";

abstract contract PositionMngerForkTest is ForkTest {
    function _initPositionManager(address owner, address strategy) internal virtual returns (address);
    function _excuteOrder() internal virtual;
    function _positionManager() internal view virtual returns (IPositionManager);
}
