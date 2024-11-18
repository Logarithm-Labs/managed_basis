// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "./ForkTest.sol";

import {IHedgeManager} from "src/hedge/IHedgeManager.sol";

abstract contract PositionMngerForkTest is ForkTest {
    function _initPositionManager(address owner, address strategy) internal virtual returns (address);
    function _executeOrder() internal virtual;
    function _hedgeManager() internal view virtual returns (IHedgeManager);
}
