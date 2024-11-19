// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "test/base/ForkTest.sol";
import {ManagedVault} from "src/vault/ManagedVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

import {console2 as console} from "forge-std/console2.sol";

contract ManagedVaultTest is ManagedVault {
    function initialize(address owner_, address asset_, string calldata name_, string calldata symbol_)
        external
        initializer
    {
        __ManagedVault_init(owner_, asset_, name_, symbol_);
    }

    // function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
    //     _harvestPerformanceFeeShares(assets, shares, true);
    //     super._deposit(caller, receiver, assets, shares);
    // }

    // function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    //     internal
    //     override
    // {
    //     _harvestPerformanceFeeShares(assets, shares, false);
    //     super._withdraw(caller, receiver, owner, assets, shares);
    // }
}

contract ManagedVaultSpecTest is ForkTest {
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");

    uint256 constant THOUSAND_USDC = 1000 * 1e6;

    ManagedVaultSpec vault;

    function setUp() public {
        vm.startPrank(owner);
        vault = new ManagedVaultSpec();
        vault.initialize(owner, USDC, "tt", "tt");
        // management fee 5%
        // performance fee 20%
        // hurdleRate 7%
        vault.setFeeInfos(recipient, 0.05 ether, 0.2 ether, 0.07 ether);

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

    function _deposit(address _user, uint256 _assets) internal {
        vm.startPrank(_user);
        IERC20(USDC).approve(address(vault), _assets);
        vault.deposit(_assets, _user);
    }

    function _withdraw(address _user, uint256 _assets) internal {
        vm.startPrank(_user);
        vault.withdraw(_assets, _user, _user);
    }

    function _redeem(address _user, uint256 _shares) internal {
        vm.startPrank(_user);
        vault.redeem(_shares, _user, _user);
    }

    function test_mint() public {
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        vault.accrueManagementFeeShares();
        uint256 sharesBefore = vault.balanceOf(user);
        _mint(user, THOUSAND_USDC);
        assertEq(sharesBefore + THOUSAND_USDC, vault.balanceOf(user));
    }

    function test_accrueManagementFee_withNoDeposit() public {
        _moveTimestamp(36.5 days);
        uint256 shares = vault.nextManagementFeeShares();
        assertEq(shares, 0, "shares 0");
    }

    function test_accrueManagementFee_withFirstDeposit() public {
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        uint256 shares = vault.nextManagementFeeShares();
        assertEq(shares, THOUSAND_USDC / 200, "1/200 of shares");
    }

    function test_accrueManagementFee_withDeposits() public {
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        _mint(user, THOUSAND_USDC);
        assertEq(vault.balanceOf(recipient), THOUSAND_USDC / 200, "1/200 of shares");
        _moveTimestamp(36.5 days);
        uint256 shares = vault.nextManagementFeeShares();
        assertEq(shares, THOUSAND_USDC / 100, "1/100 of shares");
        vault.accrueManagementFeeShares();
        assertEq(vault.balanceOf(recipient), THOUSAND_USDC * 3 / 200, "3/200 of shares");
    }

    function test_update_feeRecipientCantTransfer() public {
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        _mint(user, THOUSAND_USDC);

        vm.expectRevert(abi.encodeWithSelector(Errors.ManagementFeeTransfer.selector, recipient));
        vm.startPrank(recipient);
        vault.transfer(user, 1000);
    }

    function test_update_redeemOfUserShare() public {
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        assertEq(vault.balanceOf(recipient), THOUSAND_USDC / 200);
        vm.startPrank(user);
        vault.redeem(THOUSAND_USDC, user, user);
        assertEq(vault.balanceOf(user), THOUSAND_USDC);
        assertEq(vault.balanceOf(recipient), THOUSAND_USDC * 3 / 200);
    }

    function test_update_redeemOfRecipientShare() public {
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        _mint(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        assertEq(vault.balanceOf(recipient), THOUSAND_USDC / 200);

        assertEq(vault.nextManagementFeeShares(), THOUSAND_USDC / 100);

        // redeem half share of recipient
        vm.startPrank(recipient);
        vault.redeem(THOUSAND_USDC / 200, recipient, recipient);
        assertEq(vault.balanceOf(recipient), THOUSAND_USDC / 100);

        assertEq(vault.nextManagementFeeShares(), 0);
    }

    function test_updateHwm_initiate() public {
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC);
    }

    function test_updateHwm_deposit() public {
        _deposit(user, THOUSAND_USDC);
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC);
    }

    function test_updateHwm_withdraw() public {
        _deposit(user, THOUSAND_USDC);
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(user);
        vault.redeem(THOUSAND_USDC, user, user);
        assertEq(vault.highWaterMark(), THOUSAND_USDC);
    }

    function test_updateHwm_deposit_afterProfitLessThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 200); // 0.5% profit
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC);
    }

    function test_updateHwm_deposit_afterProfitBiggerThanHurdleRate() public {
        assertEq(vault.hurdleRate(), 0.07 ether, "hurdle rate");
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 10); // 10% profit
        assertEq(vault.totalAssets(), THOUSAND_USDC + THOUSAND_USDC / 10, "totalAssets");
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC + THOUSAND_USDC / 10);
    }

    function test_updateHwm_deposit_afterLoss() public {
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(address(vault));
        IERC20(USDC).transfer(address(this), 100 * 1e6); // 1% loss
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC);
    }

    function test_updateHwm_withdraw_afterProfitLessThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 200); // 0.5% profit
        uint256 nextMgmtShare = vault.nextManagementFeeShares();
        uint256 nextPerfShare = vault.nextPerformanceFeeShares();
        assertEq(nextPerfShare, 0, "0 performance fee");
        _redeem(user, (vault.balanceOf(user) + nextMgmtShare) / 2);
        assertEq(vault.highWaterMark(), THOUSAND_USDC / 2);
    }

    function test_updateHwm_withdraw_afterProfitBiggerThanHurdleRate() public {
        assertEq(vault.hurdleRate(), 0.07 ether, "hurdle rate");
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 100); // 1% profit
        assertEq(vault.totalAssets(), THOUSAND_USDC + THOUSAND_USDC / 100, "totalAssets");
        _redeem(user, vault.balanceOf(user) / 2);
        assertEq(vault.highWaterMark(), vault.totalAssets(), "hwm = totalAssets");
    }

    function test_updateHwm_withdraw_afterLoss() public {
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(address(vault));
        IERC20(USDC).transfer(address(this), 100 * 1e6); // 1% loss
        _redeem(user, vault.balanceOf(user) / 2);
        assertEq(vault.highWaterMark(), THOUSAND_USDC / 2);
    }

    function test_performanceFee_withdraw_withProfitLessThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        // hurdleRateFraction = 7% / 10 = 0.7%
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 200); // 0.5% profit
        uint256 mgmtFee = vault.nextManagementFeeShares();
        uint256 perfFee = vault.nextPerformanceFeeShares();
        assertEq(perfFee, 0, "no performance fee");
        uint256 nextFeeAssets = vault.previewRedeem(mgmtFee);
        _withdraw(user, THOUSAND_USDC / 2);
        uint256 feeShares = vault.balanceOf(recipient);
        uint256 feeAssets = vault.previewRedeem(feeShares);
        assertEq(mgmtFee, feeShares);
        assertEq(nextFeeAssets, feeAssets);
    }

    function test_performanceFee_withdraw_withProfitBiggerThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        // managementFee = 5% / 10 = 0.5%
        // performanceFee = THOUSAND_USDC / 100 / 5
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 100); // 1%
        uint256 mgmtFee = vault.nextManagementFeeShares();
        uint256 perfFee = vault.nextPerformanceFeeShares();
        assertEq(mgmtFee, THOUSAND_USDC / 20 / 10);
        assertEq(vault.previewRedeem(perfFee), THOUSAND_USDC / 100 / 5, "20% of profit");
        uint256 nextFeeAssets = vault.previewRedeem(mgmtFee + perfFee);
        _withdraw(user, THOUSAND_USDC / 2);
        uint256 feeShares = vault.balanceOf(recipient);
        assertEq(mgmtFee + perfFee, feeShares);
        uint256 feeAssets = vault.previewRedeem(feeShares);
        assertEq(nextFeeAssets, feeAssets);
    }

    function test_performanceFee_deposit_withProfitLessThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(USDC_WHALE);
        _moveTimestamp(36.5 days);
        // hurdleRateFraction = 7% / 10 = 0.7%
        // managementFee = 5% / 10 = 0.5%
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 200); // 0.5% profit
        uint256 mgmtFee = vault.nextManagementFeeShares();
        uint256 perfFee = vault.nextPerformanceFeeShares();
        assertEq(perfFee, 0, "no performance fee");
        uint256 nextFeeAssets = vault.previewRedeem(mgmtFee);
        _deposit(user, THOUSAND_USDC / 2);
        uint256 feeShares = vault.balanceOf(recipient);
        uint256 feeAssets = vault.previewRedeem(feeShares);
        assertEq(mgmtFee, feeShares);
        assertEq(nextFeeAssets, feeAssets);
    }

    function test_performanceFee_deposit_withProfitBiggerThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        vm.startPrank(USDC_WHALE);
        IERC20(USDC).transfer(address(vault), THOUSAND_USDC / 100); // 1% profit
        // managementFee = 5% / 10 = 0.5%
        // performanceFee = THOUSAND_USDC / 100 / 5
        uint256 mgmtFee = vault.nextManagementFeeShares();
        uint256 perfFee = vault.nextPerformanceFeeShares();
        uint256 perfFeeAssets = vault.previewRedeem(perfFee);
        assertEq(perfFeeAssets, THOUSAND_USDC / 100 / 5, "20% of profit");
        uint256 nextFeeAssets = vault.previewRedeem(mgmtFee + perfFee);
        _deposit(user, THOUSAND_USDC / 2);
        uint256 feeShares = vault.balanceOf(recipient);
        assertEq(mgmtFee + perfFee, feeShares);
        uint256 feeAssets = vault.previewRedeem(feeShares);
        assertEq(nextFeeAssets, feeAssets);
    }

    function test_maxDeposit_limit() public {
        vm.startPrank(owner);
        vault.setDepositLimits(THOUSAND_USDC, THOUSAND_USDC);
        _deposit(user, THOUSAND_USDC / 2);
        uint256 available = vault.maxDeposit(user);
        assertEq(available, THOUSAND_USDC / 2);
    }

    function test_maxMint_limit() public {
        vm.startPrank(owner);
        vault.setDepositLimits(THOUSAND_USDC, THOUSAND_USDC);
        _mint(user, THOUSAND_USDC / 2);
        uint256 available = vault.maxMint(user);
        assertEq(available, THOUSAND_USDC / 2);
    }

    function test_maxDeposit_unlimit() public {
        _deposit(user, THOUSAND_USDC / 2);
        uint256 available = vault.maxDeposit(user);
        assertEq(available, type(uint256).max);
    }

    function test_maxMint_unlimit() public {
        _mint(user, THOUSAND_USDC / 2);
        uint256 available = vault.maxMint(user);
        assertEq(available, type(uint256).max);
    }
}
