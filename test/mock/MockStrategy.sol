// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PositionManagerCallbackParams} from "src/interfaces/IManagedBasisStrategy.sol";

contract MockStrategy {
    uint256 public sizeDeltaInTokens;
    uint256 public executionCost;
    uint256 public collateralDelta;

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

    function afterAdjustPosition(PositionManagerCallbackParams calldata params) external {
        if (params.isSuccess) {
            sizeDeltaInTokens = params.sizeDeltaInTokens;
            collateralDelta = params.collateralDeltaAmount;
            if (params.collateralDeltaAmount > 0 && !params.isIncrease) {
                IERC20(asset()).transferFrom(msg.sender, address(this), collateralDelta);
            }
        } else {
            sizeDeltaInTokens = 0;
            collateralDelta = 0;
        }
    }
}
