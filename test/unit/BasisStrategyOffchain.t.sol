// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {InchTest} from "test/base/InchTest.sol";
import {GmxV2Test} from "test/base/GmxV2Test.sol";
import {OffChainTest} from "test/base/OffChainTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";

import {OffChainPositionManager} from "src/position/offchain/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {BasisStrategyBaseTest} from "./BasisStrategyBase.t.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {OffChainConfig} from "src/position/offchain/OffChainConfig.sol";

import {console} from "forge-std/console.sol";

contract BasisStrategyOffChainTest is BasisStrategyBaseTest, OffChainTest {
    function _mockChainlinkPriceFeedAnswer(address priceFeed, int256 answer) internal override {
        super._mockChainlinkPriceFeedAnswer(priceFeed, answer);
        _updatePositionNetBalance(positionManager.positionNetBalance());
    }

    function test_deutilize_lastRedeemBelowRequestedAssets() public afterFullUtilized validateFinalState {
        // make last redeem
        uint256 userShares = IERC20(address(vault)).balanceOf(address(user1));
        vm.startPrank(user1);
        vault.redeem(userShares, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(pendingDeutilization);

        // manually decrease margin
        uint256 netBalance = positionManager.positionNetBalance();
        uint256 marginDecrease = netBalance / 10;
        vm.startPrank(address(this));
        IERC20(asset).transfer(USDC_WHALE, marginDecrease);
        positionNetBalance -= marginDecrease;
        vm.startPrank(agent);
        _reportState();

        _excuteOrder();

        bytes32 requestKey = vault.getWithdrawKey(user1, 0);
        assertTrue(vault.processedWithdrawAssets() < vault.accRequestedWithdrawAssets());
        assertTrue(vault.isClaimable(requestKey));

        uint256 requestedAssets = vault.withdrawRequests(requestKey).requestedAssets;
        uint256 balBefore = IERC20(asset).balanceOf(user1);

        assertGt(vault.accRequestedWithdrawAssets(), vault.processedWithdrawAssets());

        vm.startPrank(user1);
        vault.claim(requestKey);
        uint256 balDelta = IERC20(asset).balanceOf(user1) - balBefore;

        assertGt(requestedAssets, balDelta);
        assertEq(strategy.pendingDecreaseCollateral(), 0);
        assertEq(vault.accRequestedWithdrawAssets(), vault.processedWithdrawAssets());
    }

    function test_performUpkeep_decreaseCollateral() public afterMultipleWithdrawRequestCreated validateFinalState {
        uint256 increaseCollateralMin = 5 * 1e6;
        uint256 increaseCollateralMax = type(uint256).max;
        uint256 decreaseCollateralMin = 10 * 1e6;
        uint256 decreaseCollateralMax = type(uint256).max;
        uint256 limitDecreaseCollateral = 50 * 1e6;
        vm.startPrank(owner);
        address _config = address(positionManager.config());
        OffChainConfig(_config).setCollateralMinMax(
            increaseCollateralMin, increaseCollateralMax, decreaseCollateralMin, decreaseCollateralMax
        );
        OffChainConfig(_config).setLimitDecreaseCollateral(limitDecreaseCollateral);
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 amount = pendingDeutilization * 9 / 10;
        _deutilize(amount);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        vm.startPrank(operator);
        strategy.deutilize(amount, BasisStrategy.SwapType.MANUAL, "");
        _deposit(user1, 400_000_000);
        _excuteOrder();

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("decreaseCollateral");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (,,,, bool decreaseCollateral,) = helper.decodePerformData(performData);
        assertTrue(decreaseCollateral, "decreaseCollateral");
        assertTrue(strategy.pendingDecreaseCollateral() > 0, "0 pendingDecreaseCollateral");
        _performKeep("decreaseCollateral");
        assertTrue(strategy.pendingDecreaseCollateral() == 0, "not 0 pendingDecreaseCollateral");
    }
}
