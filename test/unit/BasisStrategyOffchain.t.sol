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
import {StrategyStatus} from "src/libraries/strategy/BasisStrategyState.sol";
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
        assertEq(strategy.pendingDecreaseCollateral(), 0);
        assertEq(vault.accRequestedWithdrawAssets(), vault.processedWithdrawAssets());
    }

    function test_deutilize_PendingDecreaseCollateral() public afterMultipleWithdrawRequestCreated validateFinalState {
        uint256 increaseCollateralMin = 5 * 1e6;
        uint256 decreaseCollateralMin = 10 * 1e6;
        uint256 limitDecreaseCollateral = 50 * 1e6;
        vm.startPrank(owner);
        address _config = address(hedgeManager.config());
        OffChainConfig(_config).setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        OffChainConfig(_config).setLimitDecreaseCollateral(limitDecreaseCollateral);
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 amount = pendingDeutilization * 9 / 10;
        _deutilize(amount);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        uint256 initialLeverage = hedgeManager.currentLeverage();
        uint256 initialPendingDecreaseCollateral = strategy.pendingDecreaseCollateral();
        assertEq(initialPendingDecreaseCollateral, 0, "0 initialPendingDecreaseCollateral");
        _deutilize(amount);
        uint256 pendingDecreaseCollateralAtFirst = strategy.pendingDecreaseCollateral();
        assertGt(pendingDecreaseCollateralAtFirst, 0, "0 pendingDecreaseCollateral");
        uint256 leverageAtFirst = hedgeManager.currentLeverage();
        assertGt(initialLeverage, leverageAtFirst, "initialLeverage > leverageAtFirst");
        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        _deutilize(amount);
        uint256 pendingDecreaseCollateralAtSecond = strategy.pendingDecreaseCollateral();
        assertGt(
            pendingDecreaseCollateralAtSecond,
            pendingDecreaseCollateralAtFirst,
            "pendingDecreaseCollateralAtSecond > pendingDecreaseCollateralAtFirst"
        );
        uint256 leverageAtSecond = hedgeManager.currentLeverage();
        assertGt(leverageAtFirst, leverageAtSecond, "leverageAtFirst > leverageAtSecond");
        (, pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        uint256 leverageAtThird = hedgeManager.currentLeverage();
        uint256 pendingDecreaseCollateralAtThird = strategy.pendingDecreaseCollateral();
        assertEq(pendingDecreaseCollateralAtThird, 0, "0 pendingDecreaseCollateral");
        assertApproxEqRel(leverageAtFirst, leverageAtThird, 0.01 ether, "leverageAtFirst == leverageAtFourth");
    }

    function test_partialDeutilize_PendingDecreaseCollateral_whenLeverageBiggerThanTargetLeverage()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        uint256 increaseCollateralMin = 5 * 1e6;
        uint256 decreaseCollateralMin = 10 * 1e6;
        uint256 limitDecreaseCollateral = 50 * 1e6;
        vm.startPrank(owner);
        address _config = address(hedgeManager.config());
        OffChainConfig(_config).setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        OffChainConfig(_config).setLimitDecreaseCollateral(limitDecreaseCollateral);
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 amount = pendingDeutilization * 9 / 10;
        _deutilize(amount);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        _deutilize(amount);

        assertGt(strategy.pendingDecreaseCollateral(), 0, "pendingDecreaseCollateral != 0");
        assertLt(hedgeManager.currentLeverage(), strategy.targetLeverage(), "currentLeverage < targetLeverage");

        // mock current leverage bigger than target leverage
        address priceFeed = oracle.getPriceFeed(address(product));
        int256 currPrice = IPriceFeed(priceFeed).latestAnswer();
        uint256 deltaPrice = Math.mulDiv(uint256(currPrice), 0.01 ether, 1 ether);
        int256 resultedPrice = currPrice + int256(deltaPrice);
        _mockChainlinkPriceFeedAnswer(priceFeed, resultedPrice);

        uint256 leverageBefore = hedgeManager.currentLeverage();
        assertGt(leverageBefore, strategy.targetLeverage(), "currentLeverage > targetLeverage");

        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        _deutilize(amount);

        uint256 leverageAfter = hedgeManager.currentLeverage();
        assertLt(leverageAfter, leverageBefore, "leverageAfter < leverageBefore");
        assertEq(strategy.pendingDecreaseCollateral(), 0, "pendingDecreaseCollateral == 0");
    }

    function test_fullDeutilize_PendingDecreaseCollateral_whenLeverageBiggerThanTargetLeverage()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        uint256 increaseCollateralMin = 5 * 1e6;
        uint256 decreaseCollateralMin = 10 * 1e6;
        uint256 limitDecreaseCollateral = 50 * 1e6;
        vm.startPrank(owner);
        address _config = address(hedgeManager.config());
        OffChainConfig(_config).setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        OffChainConfig(_config).setLimitDecreaseCollateral(limitDecreaseCollateral);
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 amount = pendingDeutilization * 9 / 10;
        _deutilize(amount);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        _deutilize(amount);

        assertGt(strategy.pendingDecreaseCollateral(), 0, "pendingDecreaseCollateral != 0");
        assertLt(hedgeManager.currentLeverage(), strategy.targetLeverage(), "currentLeverage < targetLeverage");

        // mock current leverage bigger than target leverage
        address priceFeed = oracle.getPriceFeed(address(product));
        int256 currPrice = IPriceFeed(priceFeed).latestAnswer();
        uint256 deltaPrice = Math.mulDiv(uint256(currPrice), 0.01 ether, 1 ether);
        int256 resultedPrice = currPrice + int256(deltaPrice);
        _mockChainlinkPriceFeedAnswer(priceFeed, resultedPrice);

        uint256 leverageBefore = hedgeManager.currentLeverage();
        assertGt(leverageBefore, strategy.targetLeverage(), "currentLeverage > targetLeverage");

        (, pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);

        uint256 leverageAfter = hedgeManager.currentLeverage();
        assertApproxEqRel(leverageAfter, leverageBefore, 0.001 ether, "leverageAfter == leverageBefore");
        assertEq(strategy.pendingDecreaseCollateral(), 0, "pendingDecreaseCollateral == 0");
    }

    function test_performUpkeep_processPendingDecreaseCollateral()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        uint256 increaseCollateralMin = 5 * 1e6;
        uint256 decreaseCollateralMin = 10 * 1e6;
        uint256 limitDecreaseCollateral = 50 * 1e6;
        vm.startPrank(owner);
        address _config = address(hedgeManager.config());
        OffChainConfig(_config).setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        OffChainConfig(_config).setLimitDecreaseCollateral(limitDecreaseCollateral);
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 amount = pendingDeutilization * 9 / 10;
        _deutilize(amount);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        amount = pendingDeutilization * 1 / 10;
        vm.startPrank(operator);
        strategy.deutilize(amount, ISpotManager.SwapType.MANUAL, "");
        assertGt(strategy.pendingDecreaseCollateral(), 0, "0 pendingDecreaseCollateral");
        _deposit(user1, 404_000_000);
        _executeOrder();

        assertGt(
            strategy.pendingDecreaseCollateral(),
            strategy.assetsToDeutilize(),
            "pendingDecreaseCollateral > assetsToDeutilize"
        );

        assertEq(uint256(strategy.strategyStatus()), uint256(StrategyStatus.IDLE), "StrategyStatus.IDLE");

        (, pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingDeutilization, 0, "0 pendingDeutilization");

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("decreaseCollateral");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        StrategyHelper.DecodedPerformData memory decodedPerformData = helper.decodePerformData(performData);
        assertTrue(decodedPerformData.processPendingDecreaseCollateral, "processPendingDecreaseCollateral");
        assertTrue(strategy.pendingDecreaseCollateral() > 0, "0 pendingDecreaseCollateral");
        _performKeep("processPendingDecreaseCollateral");
        assertTrue(strategy.pendingDecreaseCollateral() == 0, "not 0 pendingDecreaseCollateral");
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

    function test_harvest_performanceFee() public {
        address recipient = makeAddr("recipient");
        // performance fee 20%
        // hurdleRate 10%
        vm.startPrank(owner);
        vault.setFeeInfos(recipient, 0, 0.2 ether, 0.1 ether);
        vm.stopPrank();
        _reportState();
        _deposit(user1, TEN_THOUSANDS_USDC);

        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);

        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = assetPriceFeed;
        priceFeeds[1] = productPriceFeed;
        // hurdle rate fraction = 10% / 10 = 1%
        _moveTimestamp(36.5 days, priceFeeds);

        uint256 profit = TEN_THOUSANDS_USDC * 15 / 1000; // 1.5% profit
        _updatePositionNetBalance(positionNetBalance + profit);
        _reportState();

        uint256 feeShares = vault.balanceOf(recipient);
        uint256 feeAssets = vault.previewRedeem(feeShares);
        uint256 expectedPF = profit * 20 / 100 * (1 ether - vault.exitCost()) / 1e18;

        assertApproxEqRel(feeAssets, expectedPF, 0.0001 ether, "feeAssets");
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

    function test_deutilize_clamps_to_min_when_processingRebalanceDown() public {
        // 1. Setup: fully utilize, then trigger rebalance down
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);

        // 2. Manipulate state so that a rebalance down is needed, and the deutilization amount is less than decreaseSizeMin
        // For example, set the vault's idle assets to 0, and increase leverage by changing price
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(vault), 1); // minimal idle
        vm.stopPrank();

        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);

        // 3. Trigger keeper logic to set processingRebalanceDown
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("rebalanceDown_whenIdleNotEnough");
        assertTrue(upkeepNeeded);
        _performKeep("rebalanceDown_whenIdleNotEnough");

        // 4. Mock decreaseSizeMin
        (, uint256 pendingDeutilizationOriginal) = strategy.pendingUtilizations();
        uint256 pendingDeutilizationInAsset = oracle.convertTokenAmount(product, asset, pendingDeutilizationOriginal);
        uint256 decreaseSizeMin = pendingDeutilizationInAsset * 2;
        vm.startPrank(owner);
        OffChainConfig config =
            OffChainConfig(address(OffChainPositionManager(address(strategy.hedgeManager())).config()));
        config.setSizeMin(config.increaseSizeMin(), decreaseSizeMin);
        vm.stopPrank();

        // 5. Now, pendingUtilizations should return deutilization == decreaseSizeMin
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 pendingDeutilizationInAssetExpected = oracle.convertTokenAmount(asset, product, decreaseSizeMin);
        assertEq(pendingDeutilization, pendingDeutilizationInAssetExpected, "Should clamp to decreaseSizeMin");

        uint256 exposureBefore = ISpotManager(strategy.spotManager()).exposure();
        uint256 positionSizeBefore = IHedgeManager(strategy.hedgeManager()).positionSizeInTokens();

        // 6. Optionally, call deutilize and check the event or state
        vm.startPrank(operator);
        strategy.deutilize(pendingDeutilization, ISpotManager.SwapType.MANUAL, "");
        vm.stopPrank();
        _executeOrder();

        uint256 exposureAfter = ISpotManager(strategy.spotManager()).exposure();
        uint256 positionSizeAfter = IHedgeManager(strategy.hedgeManager()).positionSizeInTokens();
        assertEq(exposureAfter + pendingDeutilizationInAssetExpected, exposureBefore, "Exposure should increase");
        assertEq(
            positionSizeAfter + pendingDeutilizationInAssetExpected, positionSizeBefore, "Position size should decrease"
        );
    }
}
