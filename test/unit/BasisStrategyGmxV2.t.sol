// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkTest} from "test/base/ForkTest.sol";
import {GmxV2Test} from "test/base/GmxV2Test.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {IPositionManager} from "src/interfaces/IPositionManager.sol";
import {GmxV2Lib} from "src/libraries/gmx/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {GmxConfig} from "src/GmxConfig.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";

import {BasisStrategyBaseTest} from "./BasisStrategyBase.t.sol";

contract BasisStrategyGmxV2Test is BasisStrategyBaseTest, GmxV2Test {
    function test_afterAdjustPosition_revert_whenUtilizing() public afterDeposited {
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();

        uint256 amount = pendingUtilization / 2;
        // bytes memory data = _generateInchCallData(asset, product, amount, address(strategy));
        vm.startPrank(operator);
        strategy.utilize(amount, BasisStrategy.SwapType.MANUAL, "");

        // position manager increase reversion
        vm.startPrank(GMX_ORDER_VAULT);
        IERC20(asset).transfer(address(_positionManager()), pendingIncreaseCollateral / 2);
        vm.startPrank(address(_positionManager()));
        strategy.afterAdjustPosition(
            IPositionManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: true})
        );

        assertEq(IERC20(asset).balanceOf(address(_positionManager())), 0);
        assertEq(IERC20(product).balanceOf(address(strategy)), 0);
        assertApproxEqRel(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC, 0.9999 ether);
    }

    function test_deutilize_lastRedeemBelowRequestedAssets() public afterFullUtilized validateFinalState {
        // make last redeem
        uint256 userShares = IERC20(address(vault)).balanceOf(address(user1));
        vm.startPrank(user1);
        vault.redeem(userShares, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(pendingDeutilization);

        // decrease margin
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 105 / 100);

        _excuteOrder();
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));

        bytes32 requestKey = vault.getWithdrawKey(user1, 0);
        assertTrue(vault.proccessedWithdrawAssets() < vault.accRequestedWithdrawAssets());
        assertTrue(vault.isClaimable(requestKey));

        uint256 requestedAssets = vault.withdrawRequests(requestKey).requestedAssets;
        uint256 balBefore = IERC20(asset).balanceOf(user1);

        assertGt(vault.accRequestedWithdrawAssets(), vault.proccessedWithdrawAssets());

        vm.startPrank(user1);
        vault.claim(requestKey);
        uint256 balDelta = IERC20(asset).balanceOf(user1) - balBefore;

        assertGt(requestedAssets, balDelta);
        assertEq(strategy.pendingDecreaseCollateral(), 0);
        assertEq(vault.accRequestedWithdrawAssets(), vault.proccessedWithdrawAssets());
    }
}
