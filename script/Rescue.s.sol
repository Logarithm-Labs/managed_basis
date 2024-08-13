// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";
import {RescueStrategy} from "src/RescueStrategy.sol";

contract RescueScript is Script {
    AccumulatedBasisStrategy public strategy = AccumulatedBasisStrategy(0x541A3908f6914A5574A42Ad37e136EEdFDD4Fc89);
    address public keeper = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address public usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function run() public {
        vm.startBroadcast();
        address impl = address(new RescueStrategy());
        uint256 balStrategy = IERC20(usdc).balanceOf(address(strategy));
        uint256 balBefore = IERC20(usdc).balanceOf(address(keeper));
        strategy.upgradeToAndCall(impl, abi.encodeWithSelector(RescueStrategy.rescue.selector, ""));
        uint256 balAfter = IERC20(usdc).balanceOf(address(keeper));
        require(balAfter - balBefore == balStrategy, "RescueScript: rescue failed");
    }
}
