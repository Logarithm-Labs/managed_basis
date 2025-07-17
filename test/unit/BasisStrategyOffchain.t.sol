// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {InchTest} from "test/base/InchTest.sol";
import {OffChainTest} from "test/base/OffChainTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {BasisStrategyBaseTest} from "./BasisStrategyBase.t.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";

import {console} from "forge-std/console.sol";
import {StrategyHelper} from "test/helper/StrategyHelper.sol";

contract BasisStrategyOffChainTest is BasisStrategyBaseTest, OffChainTest {
    function _mockChainlinkPriceFeedAnswer(address priceFeed, int256 answer) internal override {
        super._mockChainlinkPriceFeedAnswer(priceFeed, answer);
        _updatePositionNetBalance(hedgeManager.positionNetBalance());
    }

    function test_deutilize_lastRedeemBelowRequestedAssets() public afterFullUtilized validateFinalState {
        // make last redeem
        uint256 userShares = IERC20(address(vault)).balanceOf(address(user1));
        vm.startPrank(user1);
        vault.requestRedeem(userShares, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(pendingDeutilization);

        // manually decrease margin
        uint256 netBalance = hedgeManager.positionNetBalance();
        uint256 marginDecrease = netBalance / 10;
        vm.startPrank(address(this));
        IERC20(asset).transfer(USDC_WHALE, marginDecrease);
        positionNetBalance -= marginDecrease;
        // _reportState();

        _executeOrder();

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
        assertEq(vault.accRequestedWithdrawAssets(), vault.processedWithdrawAssets());
    }

    function test_idleCollateral_fullRedeem() public afterFullUtilized validateFinalState {
        // make 10 USDC idle assets for the position manager
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(hedgeManager), 10_000_000);
        vm.startPrank(user1);
        vault.requestRedeem(vault.balanceOf(user1), user1, user1);

        (, uint256 deutilization) = strategy.pendingUtilizations();
        _deutilize(deutilization);

        bool claimable = vault.isClaimable(vault.getWithdrawKey(user1, 0));
        assertTrue(claimable);
    }

    function test_idleCollateral_increaseCollateral() public {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();

        // make 10 USDC idle assets for the position manager
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(hedgeManager), 10_000_000);

        _utilize(pendingUtilizationInAsset);

        // collateral should be around 100000 / 4 + 10
        assertApproxEqRel(hedgeManager.positionNetBalance(), TEN_THOUSANDS_USDC / 4 + 10_000_000, 0.0001 ether);
        assertEq(hedgeManager.idleCollateralAmount(), 0);
    }

    function test_revertReportState() public afterFullUtilized validateFinalState {
        // make 10 USDC idle assets for the position manager
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(hedgeManager), 10_000_000);
        vm.startPrank(user1);
        vault.requestRedeem(vault.balanceOf(user1), user1, user1);

        (, uint256 deutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(deutilization);

        uint256 markPrice = _getMarkPrice();
        vm.startPrank(agent);
        vm.expectRevert(Errors.ProcessingRequest.selector);
        hedgeManager.reportState(positionSizeInTokens, positionNetBalance, markPrice);

        // finally can report after processing request
        _executeOrder();
        _reportState();
    }

    function test_revertLastExecution_withZeroResponse() public afterFullUtilized {
        vm.startPrank(user1);
        vault.requestRedeem(vault.balanceOf(user1), user1, user1);

        (, uint256 deutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(deutilization);

        OffChainPositionManager.RequestInfo memory requestInfo = hedgeManager.getLastRequest();
        IHedgeManager.AdjustPositionPayload memory request = requestInfo.request;
        IHedgeManager.AdjustPositionPayload memory response = _executeRequest(request);
        uint256 markPrice = _getMarkPrice();
        IHedgeManager.AdjustPositionPayload memory params = IHedgeManager.AdjustPositionPayload({
            sizeDeltaInTokens: response.sizeDeltaInTokens,
            collateralDeltaAmount: 0,
            isIncrease: response.isIncrease
        });
        vm.startPrank(agent);
        vm.expectRevert(Errors.HedgeWrongCloseResponse.selector);
        hedgeManager.reportStateAndExecuteRequest(positionSizeInTokens, positionNetBalance, markPrice, params);
        vm.stopPrank();
    }

    function test_evt_createRequest_utilize() public afterDeposited {
        (uint256 amount,) = strategy.pendingUtilizations();
        vm.startPrank(operator);
        vm.expectEmit(true, false, false, false);
        emit OffChainPositionManager.CreateRequest(
            1, oracle.convertTokenAmount(asset, product, amount), amount / strategy.targetLeverage(), true
        );
        strategy.utilize(amount, ISpotManager.SwapType.MANUAL, "");
        vm.stopPrank();
    }

    function test_evt_createRequest_deutilize() public afterWithdrawRequestCreated {
        (, uint256 amount) = strategy.pendingUtilizations();
        vm.startPrank(operator);
        vm.expectEmit(true, false, false, false);
        emit OffChainPositionManager.CreateRequest(3, amount, 0, true);
        strategy.deutilize(amount, ISpotManager.SwapType.MANUAL, "");
        vm.stopPrank();
    }

    function test_performUpkeep_rebalanceDown_whenIdleNotEnough_smallerThanMinCollateral()
        public
        afterFullUtilized
        validateFinalState
    {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(vault), 10 * 1e6);

        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("rebalanceDown_whenIdleNotEnough");
        assertTrue(upkeepNeeded);
        BasisStrategy.InternalCheckUpkeepResult memory result =
            abi.decode(performData, (BasisStrategy.InternalCheckUpkeepResult));

        // set min increase collateral bigger than deltaCollateralToIncrease
        vm.startPrank(owner);
        OffChainConfig config =
            OffChainConfig(address(OffChainPositionManager(address(strategy.hedgeManager())).config()));
        config.setLimitDecreaseCollateral(result.deltaCollateralToIncrease + 10);
        config.setCollateralMin(result.deltaCollateralToIncrease + 1, result.deltaCollateralToIncrease + 1);

        StrategyHelper.DecodedPerformData memory decodedPerformData = helper.decodePerformData(performData);
        assertFalse(decodedPerformData.rebalanceUpNeeded);
        assertTrue(decodedPerformData.rebalanceDownNeeded);
        assertFalse(decodedPerformData.hedgeManagerNeedKeep);

        _performKeep("rebalanceDown_whenIdleNotEnough");

        (, uint256 amount) = strategy.pendingUtilizations();
        _deutilize(amount);

        _performKeep("rebalanceDown_whenIdleNotEnough");

        (, amount) = strategy.pendingUtilizations();
        _deutilize(amount);

        _performKeep("rebalanceDown_whenIdleNotEnough");
    }
}
