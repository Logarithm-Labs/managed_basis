// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkTest} from "test/base/ForkTest.sol";
import {GmxV2Test} from "test/base/GmxV2Test.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {GmxV2Lib} from "src/libraries/gmx/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";

import {BasisStrategyBaseTest} from "./BasisStrategyBase.t.sol";

contract BasisStrategyGmxV2Test is BasisStrategyBaseTest, GmxV2Test {
    function test_afterAdjustPosition_revert_whenUtilizing() public afterDeposited {
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();

        uint256 amount = pendingUtilization / 2;
        // bytes memory data = _generateInchCallData(asset, product, amount, address(strategy));
        vm.startPrank(operator);
        strategy.utilize(amount, ISpotManager.SwapType.MANUAL, "");

        // position manager increase reversion
        vm.startPrank(GMX_ORDER_VAULT);
        IERC20(asset).transfer(address(_hedgeManager()), pendingUtilization / 6);
        vm.startPrank(address(_hedgeManager()));
        strategy.afterAdjustPosition(
            IHedgeManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: true})
        );

        assertEq(IERC20(asset).balanceOf(address(_hedgeManager())), 0);
        assertEq(IERC20(product).balanceOf(address(strategy)), 0);
        assertApproxEqRel(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC, 0.9999 ether);
    }

    function test_deutilize_lastRedeemBelowRequestedAssets() public afterFullUtilized validateFinalState {
        // make last redeem
        uint256 userShares = IERC20(address(vault)).balanceOf(address(user1));
        vm.startPrank(user1);
        vault.requestRedeem(userShares, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(pendingDeutilization);

        // decrease margin
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 105 / 100);

        _executeOrder();
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));

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

    function test_performUpkeep_positionManagerKeep() public afterFullUtilized validateFinalState {
        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = assetPriceFeed;
        priceFeeds[1] = productPriceFeed;
        _moveTimestamp(1 days, priceFeeds);

        vm.startPrank(address(owner));
        GmxConfig(address(positionManager.config())).setMaxClaimableFundingShare(0.00001 ether);

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("positionManagerKeep");
        // assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            ,
            bool rebalanceUpNeeded
        ) = helper.decodePerformData(performData);

        assertTrue(upkeepNeeded, "upkeepNeeded");
        assertTrue(positionManagerNeedKeep, "positionManagerNeedKeep");

        _performKeep("positionManagerKeep");
    }

    function test_performUpkeep_rebalanceDown_whenNoIdle_whenOracleFluctuateBeforeExecuting()
        public
        afterFullUtilized
        validateFinalState
    {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);

        (bool upkeepNeeded, bytes memory performData) =
            _checkUpkeep("rebalanceDown_whenNoIdle_whenOracleFluctuateBeforeExecuting");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool positionManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(positionManagerNeedKeep);
        uint256 leverageBefore = _hedgeManager().currentLeverage();
        _performKeep("rebalanceDown_whenNoIdle_whenOracleFluctuateBeforeExecuting");
        uint256 leverageAfter = _hedgeManager().currentLeverage();
        assertEq(leverageBefore, leverageAfter, "leverage not changed");
        assertEq(strategy.processingRebalanceDown(), true);

        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 99 / 100);

        (uint256 pendingUtilization, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0, "pendingUtilization");
        assertEq(pendingDeutilization, 0, "pendingDeutilization");
        (upkeepNeeded, performData) = _checkUpkeep("rebalanceDown_whenNoIdle_whenOracleFluctuateBeforeExecuting");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        _performKeep("rebalanceDown_whenNoIdle_whenOracleFluctuateBeforeExecuting");
        assertEq(strategy.processingRebalanceDown(), false);
        (upkeepNeeded, performData) = _checkUpkeep("rebalanceDown_whenNoIdle_whenOracleFluctuateBeforeExecuting");
        assertFalse(upkeepNeeded, "upkeepNeeded");
        (pendingUtilization, pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0, "pendingUtilization");
        assertEq(pendingDeutilization, 0, "pendingDeutilization");
    }
}
