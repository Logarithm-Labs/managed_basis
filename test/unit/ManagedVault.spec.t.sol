// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "test/base/ForkTest.sol";
import {ManagedVault} from "src/vault/ManagedVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

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

    uint256 constant TEN_THOUSAND = 1000 * 1e6;

    ManagedVaultSpec vault;

    function setUp() public {
        _forkArbitrum(238841172);
        vm.startPrank(owner);
        vault = new ManagedVaultSpec();
        vault.initialize(owner, USDC, "tt", "tt");
        vault.setFeeInfos(recipient, 0.05 ether, 0, 0);

        // top up user1
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(user, 10_000_000 * 1e6);
    }

    function _mint(address _user, uint256 _shares) internal {
        uint256 assets = vault.previewMint(_shares);
        vm.startPrank(_user);
        IERC20(USDC).approve(address(vault), assets);
        vault.mint(_shares, _user);
    }

    function test_mint() public {
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        vault.accrueManagementFeeShares();
        uint256 sharesBefore = vault.balanceOf(user);
        _mint(user, TEN_THOUSAND);
        assertEq(sharesBefore + TEN_THOUSAND, vault.balanceOf(user));
    }

    function test_accrueManagementFee_withNoDeposit() public {
        _moveTimestamp(36.5 days);
        uint256 shares = vault.nextManagementFeeShares();
        assertEq(shares, 0, "shares 0");
    }

    function test_accrueManagementFee_withFirstDeposit() public {
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        uint256 shares = vault.nextManagementFeeShares();
        assertEq(shares, TEN_THOUSAND / 200, "1/200 of shares");
    }

    function test_accrueManagementFee_withDeposits() public {
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        _mint(user, TEN_THOUSAND);
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND / 200, "1/200 of shares");
        _moveTimestamp(36.5 days);
        uint256 shares = vault.nextManagementFeeShares();
        assertEq(shares, TEN_THOUSAND / 100, "1/100 of assets");
        vault.accrueManagementFeeShares();
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND * 3 / 200, "3/200 of shares assets");
    }

    function test_update_feeRecipientCantTransfer() public {
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        _mint(user, TEN_THOUSAND);

        vm.expectRevert(abi.encodeWithSelector(Errors.ManagementFeeTransfer.selector, recipient));
        vm.startPrank(recipient);
        vault.transfer(user, 1000);
    }

    function test_update_redeemOfUserShare() public {
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND / 200);
        vm.startPrank(user);
        vault.redeem(TEN_THOUSAND, user, user);
        assertEq(vault.balanceOf(user), TEN_THOUSAND);
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND * 3 / 200);
    }

    function test_update_redeemOfRecipientShare() public {
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        _mint(user, TEN_THOUSAND);
        _moveTimestamp(36.5 days);
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND / 200);

        assertEq(vault.nextManagementFeeShares(), TEN_THOUSAND / 100);

        // redeem half share of recipient
        vm.startPrank(recipient);
        vault.redeem(TEN_THOUSAND / 200, recipient, recipient);
        assertEq(vault.balanceOf(recipient), TEN_THOUSAND / 100);

        assertEq(vault.nextManagementFeeShares(), 0);
    }
}
