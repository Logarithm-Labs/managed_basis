// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract MockStrategy {
    uint256 public amountExecuted;
    uint256 public executionCost;
    uint256 public decreasedCollateralAmount;

    function asset() public pure returns (address) {
        return 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // usdc
    }

    function product() public pure returns (address) {
        return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    }

    function targetLeverage() public pure returns (uint256) {
        return 3 ether;
    }

    function setPositionManager(address _positionManager) public {
        IERC20(asset()).approve(_positionManager, type(uint256).max);
    }

    function afterIncreasePositionSize(uint256 _amountExecuted, uint256 _executionCost, bool) public {
        amountExecuted = _amountExecuted;
        executionCost = _executionCost;
    }

    function afterDecreasePositionSize(uint256 _amountExecuted, uint256 _executionCost, bool) public {
        amountExecuted = _amountExecuted;
        executionCost = _executionCost;
    }

    function afterIncreasePositionCollateral() public pure {}

    function afterDecreasePositionCollateral(uint256 amount, bool isSuccess) public {
        if (isSuccess) {
            IERC20(asset()).transferFrom(msg.sender, address(this), amount);
            decreasedCollateralAmount = amount;
        }
    }
}
