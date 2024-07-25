// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract RescueStrategy is UUPSUpgradeable {
    address constant KEEPER = 0x4F42fa2f07f81e6E1D348245EcB7EbFfC5267bE0;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function rescue() external {
        IERC20(USDC).transfer(KEEPER, IERC20(USDC).balanceOf(address(this)));
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override {}
}
