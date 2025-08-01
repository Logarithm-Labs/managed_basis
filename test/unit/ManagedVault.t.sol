// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ManagedVault} from "src/vault/ManagedVault.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {UsdcMock} from "test/mock/UsdcMock.sol";

contract ManagedVaultSpec is ManagedVault {
    function initialize(address owner_, address asset_, string calldata name_, string calldata symbol_)
        external
        initializer
    {
        __ManagedVault_init(owner_, asset_, name_, symbol_);
    }

    function harvestPerformanceFee() external {
        _harvestPerformanceFeeShares();
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

contract ManagedVaultTest is Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");

    uint256 constant THOUSAND_USDC = 1000 * 1e6;
    UsdcMock usdc;
    ManagedVaultSpec vault;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new UsdcMock();
        vault = new ManagedVaultSpec();
        vault.initialize(owner, address(usdc), "tt", "tt");
        // management fee 5%
        // performance fee 20%
        // hurdleRate 7%
        vault.setFeeInfos(recipient, 0.05 ether, 0.2 ether, 0.07 ether);

        // top up user1
        usdc.mint(user, 10_000_000 * 1e6);
        vault.harvestPerformanceFee();
        assertEq(vault.highWaterMark(), 0);
    }

    function _moveTimestamp(uint256 deltaTime) internal {
        uint256 targetTimestamp = vm.getBlockTimestamp() + deltaTime;
        vm.warp(targetTimestamp);
    }

    function _mint(address _user, uint256 _shares) internal {
        uint256 assets = vault.previewMint(_shares);
        vm.startPrank(_user);
        usdc.approve(address(vault), assets);
        vault.mint(_shares, _user);
    }

    function _deposit(address _user, uint256 _assets) internal {
        vm.startPrank(_user);
        usdc.approve(address(vault), _assets);
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
        uint256 profit = THOUSAND_USDC / 200;
        usdc.mint(address(vault), profit); // 0.5% profit
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC);
    }

    function test_updateHwm_deposit_afterProfitBiggerThanHurdleRate() public {
        assertEq(vault.hurdleRate(), 0.07 ether, "hurdle rate");
        _deposit(user, THOUSAND_USDC);
        uint256 profit = THOUSAND_USDC / 10;
        usdc.mint(address(vault), profit); // 10% profit
        assertEq(vault.totalAssets(), THOUSAND_USDC + profit, "totalAssets");
        _moveTimestamp(36.5 days);
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC);
    }

    function test_updateHwm_deposit_afterLoss() public {
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(address(vault));
        usdc.transfer(address(this), 100 * 1e6); // 1% loss
        _deposit(user, THOUSAND_USDC);
        assertEq(vault.highWaterMark(), THOUSAND_USDC + THOUSAND_USDC);
    }

    function test_updateHwm_withdraw_afterProfitLessThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        uint256 profit = THOUSAND_USDC / 200;
        usdc.mint(address(vault), profit); // 0.5% profit
        uint256 nextMgmtShare = vault.nextManagementFeeShares();
        _redeem(user, (vault.balanceOf(user) + nextMgmtShare) / 2);
        assertEq(vault.highWaterMark(), THOUSAND_USDC / 2);
    }

    function test_updateHwm_withdraw_afterProfitBiggerThanHurdleRate() public {
        assertEq(vault.hurdleRate(), 0.07 ether, "hurdle rate");
        _deposit(user, THOUSAND_USDC);
        uint256 profit = THOUSAND_USDC / 100; // 1% profit
        _moveTimestamp(36.5 days);
        usdc.mint(address(vault), profit);
        assertEq(vault.totalAssets(), THOUSAND_USDC + profit, "totalAssets");
        uint256 shares = (vault.balanceOf(user) + vault.nextManagementFeeShares()) / 2;
        _redeem(user, shares);
        assertEq(vault.highWaterMark(), THOUSAND_USDC / 2);
    }

    function test_updateHwm_withdraw_afterLoss() public {
        _deposit(user, THOUSAND_USDC);
        vm.startPrank(address(vault));
        usdc.transfer(address(this), 100 * 1e6); // 1% loss
        _redeem(user, vault.balanceOf(user) / 2);
        assertEq(vault.totalAssets(), 450 * 1e6);
        assertEq(vault.highWaterMark(), THOUSAND_USDC / 2);
    }

    function _makeProfit(uint256 _amount) internal {
        usdc.mint(address(vault), _amount);
        vault.harvestPerformanceFee();
    }

    function test_performanceFee_profit_lessThanHurdleRate() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        // hurdleRateFraction = 7% / 10 = 0.7%
        _makeProfit(THOUSAND_USDC / 200); // 0.5% profit
        uint256 feeShares = vault.balanceOf(recipient);
        assertEq(feeShares, 0, "no PF");
    }

    function test_performanceFee_profit_biggerThanHurdleRate_notInvadeHurdle() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        uint256 profit = THOUSAND_USDC / 100; // 1%
        _makeProfit(profit);
        // hurdleRateFraction = 7% / 10 = 0.7%
        // performanceFee = 20%
        // hurdleFraction = hwm * hurdleRateFraction = hwm * 7% / 10
        // uint256 hurdleFraction = THOUSAND_USDC * vault.hurdleRate() / 1 ether / 10;
        uint256 feeShares = vault.balanceOf(recipient);
        uint256 feeAssets = vault.previewRedeem(feeShares);
        uint256 expectedPF = profit / 5;
        assertEq(feeAssets, expectedPF, "PF");
    }

    function test_performanceFee_profit_biggerThanHurdleRate_invadeHurdle() public {
        _deposit(user, THOUSAND_USDC);
        _moveTimestamp(36.5 days);
        uint256 profit = THOUSAND_USDC * 8 / 1000; // 0.8% profit
        _makeProfit(profit);
        // hurdleRateFraction = 7% / 10 = 0.7%
        // performanceFee = 20%
        // hurdleFraction = hwm * hurdleRateFraction = hwm * 7% / 10
        uint256 hurdleFraction = THOUSAND_USDC * vault.hurdleRate() / 1 ether / 10;
        uint256 expectedPF = profit - hurdleFraction;
        assertEq(vault.previewRedeem(vault.balanceOf(recipient)), expectedPF, "PF");
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
