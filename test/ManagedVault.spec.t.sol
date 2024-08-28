// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "./base/ForkTest.sol";
import {ManagedVault} from "src/ManagedVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {console2 as console} from "forge-std/console2.sol";

contract ManagedVaultSpec is ManagedVault {
    function initialize(address owner_, address asset_, string calldata name_, string calldata symbol_)
        external
        initializer
    {
        __ManagedVault_init(owner_, asset_, name_, symbol_);
    }
}

contract ManagedVaultSpecTest is ForkTest {
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");

    uint256 constant TEN_THOUSAND_USDC = 1000 * 1e6;

    ManagedVaultSpec vault;

    function setUp() public {
        _forkArbitrum(238841172);
        vm.startPrank(owner);
        vault = new ManagedVaultSpec();
        vault.initialize(owner, USDC, "tt", "tt");
        vault.setFeeRecipient(recipient);
        vault.setApy(0.1 ether); // 10%

        // top up user1
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(user, 10_000_000 * 1e6);
    }

    function test_accureManagementFee_woSupply() public {
        _moveTimestamp(30 days);
        vault.accrueManagementFee();
        assertEq(vault.balanceOf(recipient), 0, "shares of recipient should be 0");
    }

    function test_accureManagementFee_withSupply() public {
        vault.accrueManagementFee();
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), TEN_THOUSAND_USDC);
        vault.deposit(TEN_THOUSAND_USDC, user);
        console.log(vault.balanceOf(user));
        _moveTimestamp(36.5 days);
        vault.accrueManagementFee();
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND_USDC / 100, "fee recipient share is 1/100 of totalSupply");
    }
}
