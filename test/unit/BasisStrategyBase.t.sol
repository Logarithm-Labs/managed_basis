// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {PositionMngerForkTest} from "test/base/PositionMngerForkTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";

import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";

import {StrategyHelper, StrategyState} from "test/helper/StrategyHelper.sol";
import {MockPriorityProvider} from "test/mock/MockPriorityProvider.sol";
import {console2 as console} from "forge-std/console2.sol";

import {DeployHelper} from "script/utils/DeployHelper.sol";

abstract contract BasisStrategyBaseTest is PositionMngerForkTest {
    using Math for uint256;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address metaVault = makeAddr("metaVault");
    address operator = makeAddr("operator");
    address forwarder = makeAddr("forwarder");

    uint256 constant USD_PRECISION = 1e30;

    uint256 public TEN_THOUSANDS_USDC = 10_000 * 1e6;
    uint256 public THOUSAND_USDC = 1_000 * 1e6;

    address constant asset = USDC; // USDC
    address constant product = WETH; // WETH
    address constant assetPriceFeed = CHL_USDC_USD_PRICE_FEED; // Chainlink USDC-USD price feed
    address constant productPriceFeed = CHL_ETH_USD_PRICE_FEED; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0.01 ether;
    uint256 constant exitCost = 0.02 ether;
    bool constant isLong = false;

    uint256 constant targetLeverage = 3 ether;
    uint256 constant minLeverage = 2 ether;
    uint256 constant maxLeverage = 5 ether;
    uint256 constant safeMarginLeverage = 20 ether;

    LogarithmVault vault;
    BasisStrategy strategy;
    SpotManager spotManager;
    LogarithmOracle oracle;
    StrategyHelper helper;
    MockPriorityProvider priorityProvider;

    function setUp() public {
        _forkArbitrum(237215502);
        vm.startPrank(owner);
        // deploy oracle
        oracle = DeployHelper.deployLogarithmOracle(owner);
        vm.label(address(oracle), "oracle");

        // mock uniswap
        _mockUniswapPool(UNISWAPV3_WETH_USDC, address(oracle));

        // set oracle price feed
        address[] memory assets = new address[](2);
        address[] memory feeds = new address[](2);
        uint256[] memory heartbeats = new uint256[](2);
        assets[0] = asset;
        assets[1] = product;
        feeds[0] = assetPriceFeed;
        feeds[1] = productPriceFeed;
        heartbeats[0] = 24 * 3600;
        heartbeats[1] = 24 * 3600;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        _mockChainlinkPriceFeed(assetPriceFeed);
        _mockChainlinkPriceFeed(productPriceFeed);

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        priorityProvider = new MockPriorityProvider();
        address vaultBeacon = DeployHelper.deployBeacon(address(new LogarithmVault()), owner);
        vault = DeployHelper.deployLogarithmVault(
            DeployHelper.LogarithmVaultDeployParams(
                vaultBeacon,
                owner,
                asset,
                address(priorityProvider),
                entryCost,
                exitCost,
                "Logarithm Basis USDC-WETH GMX (Alpha)",
                "log-b-usdc-weth-gmx-a"
            )
        );
        vm.label(address(vault), "vault");

        StrategyConfig config = DeployHelper.deployStrategyConfig(owner);

        // deploy strategy
        address strategyImpl = address(new BasisStrategy());
        // deploy strategy beacon
        address strategyBeacon = DeployHelper.deployBeacon(strategyImpl, owner);
        // deploy strategy beacon proxy

        address strategyProxy = address(
            new BeaconProxy(
                strategyBeacon,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    address(config),
                    product,
                    address(vault),
                    oracle,
                    operator,
                    targetLeverage,
                    minLeverage,
                    maxLeverage,
                    safeMarginLeverage,
                    pathWeth
                )
            )
        );
        strategy = DeployHelper.deployBasisStrategy(
            DeployHelper.BasisStrategyDeployParams(
                owner,
                strategyBeacon,
                address(config),
                product,
                address(vault),
                address(oracle),
                operator,
                targetLeverage,
                minLeverage,
                maxLeverage,
                safeMarginLeverage
            )
        );
        // strategy.setForwarder(forwarder);
        vm.label(address(strategy), "strategy");

        // deploy spot manager
        address spotManagerBeacon = DeployHelper.deployBeacon(address(new SpotManager()), owner);
        spotManager = DeployHelper.deploySpotManager(spotManagerBeacon, owner, address(strategy), pathWeth);
        vm.label(address(spotManager), "spotManager");

        _initPositionManager(owner, address(strategy));

        // top up user1
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(user1, 10_000_000 * 1e6);
        IERC20(asset).transfer(user2, 10_000_000 * 1e6);
        IERC20(asset).transfer(metaVault, 10_000_000 * 1e6);
        vm.stopPrank();

        helper = new StrategyHelper(address(strategy));
    }

    function _validateFinalState(StrategyState memory state) internal pure {
        assertEq(state.strategyStatus, uint8(0), "strategy status");
        if (state.positionSizeInTokens > 0) {
            assertTrue(state.positionLeverage >= minLeverage, "minLeverage");
            assertTrue(state.positionLeverage <= maxLeverage, "maxLeverage");
            // assertApproxEqRel(state.positionLeverage, 3 ether, 0.01 ether, "current leverage");
            assertApproxEqRel(state.productBalance, state.positionSizeInTokens, 0.001 ether, "product exposure");
        } else {
            assertEq(state.productBalance, state.positionSizeInTokens, "not 0 product exposure");
        }
        assertFalse(state.processingRebalance, "processingRebalance");
        assertFalse(state.upkeepNeeded, "upkeep");
    }

    function _validateStateTransition(StrategyState memory state0, StrategyState memory state1) internal pure {
        if (state0.totalSupply != 0 && state1.totalSupply != 0) {
            uint256 sharePrice0 = state0.totalAssets.mulDiv(1 ether, state0.totalSupply);
            uint256 sharePrice1 = state1.totalAssets.mulDiv(1 ether, state1.totalSupply);
            assertApproxEqRel(sharePrice0, sharePrice1, 0.01 ether, "share price");
        }

        assertTrue(state0.pendingUtilization == 0 || state0.pendingDeutilization == 0, "utilizations");
        assertTrue(state1.pendingUtilization == 0 || state1.pendingDeutilization == 0, "utilizations");

        // if (state0.positionLeverage != 0 && state1.positionLeverage != 0) {
        //     assertApproxEqRel(state0.positionLeverage, state1.positionLeverage, 0.01 ether, "position leverage");
        // }
    }

    modifier afterDeposited() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _;
    }

    modifier afterPartialUtilized() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset / 2);
        _;
    }

    modifier afterFullUtilized() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        _;
    }

    modifier afterWithdrawRequestCreated() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset / 2);
        uint256 redeemShares = vault.balanceOf(user1) * 2 / 3;
        vm.startPrank(user1);
        vault.requestRedeem(redeemShares, user1, user1);
        _;
    }

    modifier afterMultipleWithdrawRequestCreated() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        _deposit(user2, TEN_THOUSANDS_USDC);
        (pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);

        uint256 redeemShares1 = vault.balanceOf(user1) / 5;
        vm.startPrank(user1);
        vault.requestRedeem(redeemShares1, user1, user1);

        uint256 redeemShares2 = vault.balanceOf(user2) / 4;
        vm.startPrank(user2);
        vault.requestRedeem(redeemShares2, user2, user2);
        _;
    }

    modifier prioritize(address account) {
        priorityProvider.prioritize(account);
        _;
    }

    modifier validateFinalState() {
        _;
        _validateFinalState(helper.getStrategyState());
    }

    function _deposit(address from, uint256 assets) internal {
        vm.startPrank(from);
        IERC20(asset).approve(address(vault), assets);
        StrategyState memory state0 = helper.getStrategyState();
        vault.deposit(assets, from);
        StrategyState memory state1 = helper.getStrategyState();
        _validateStateTransition(state0, state1);
    }

    function _mint(address from, uint256 shares) internal {
        vm.startPrank(from);
        uint256 assets = vault.previewMint(shares);
        IERC20(asset).approve(address(vault), assets);
        StrategyState memory state0 = helper.getStrategyState();
        vault.mint(shares, from);
        StrategyState memory state1 = helper.getStrategyState();
        _validateStateTransition(state0, state1);
    }

    function _utilize(uint256 amount) internal {
        if (amount == 0) return;
        vm.startPrank(operator);
        StrategyState memory state0 = helper.getStrategyState();
        strategy.utilize(amount, ISpotManager.SwapType.MANUAL, "");
        StrategyState memory state1 = helper.getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.UTILIZING));
        (uint256 pendingUtilization, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
        assertEq(pendingDeutilization, 0);
        state0 = state1;
        _executeOrder();
        state1 = helper.getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));
    }

    function _deutilize(uint256 amount) internal {
        if (amount == 0) return;
        StrategyState memory state0 = helper.getStrategyState();
        vm.startPrank(operator);
        strategy.deutilize(amount, ISpotManager.SwapType.MANUAL, "");
        StrategyState memory state1 = helper.getStrategyState();
        _validateStateTransition(state0, state1);
        // assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.DEUTILIZING));
        (uint256 pendingUtilization, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
        assertEq(pendingDeutilization, 0);
        state0 = state1;
        _executeOrder();
        state1 = helper.getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));
    }

    function _deutilizeWithoutExecution(uint256 amount) internal {
        if (amount == 0) return;
        // bytes memory data = _generateInchCallData(product, asset, amount, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(amount, ISpotManager.SwapType.MANUAL, "");
    }

    function _checkUpkeep(string memory operation)
        internal
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 beginGas = gasleft();
        (upkeepNeeded, performData) = strategy.checkUpkeep("");
        uint256 gasWasted = beginGas - gasleft();
        console.log(string(abi.encodePacked(operation, ":checkUpkeep: ")), gasWasted);
    }

    function _performKeep(string memory operation) internal {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        uint256 step;
        while (upkeepNeeded) {
            vm.startPrank(forwarder);
            StrategyState memory state0 = helper.getStrategyState();
            uint256 startGas = gasleft();
            strategy.performUpkeep(performData);
            uint256 gasWasted = startGas - gasleft();
            step++;
            console.log(string(abi.encodePacked(operation, ":performUpkeep - ", step, ": ")), gasWasted);
            StrategyState memory state1 = helper.getStrategyState();
            _validateStateTransition(state0, state1);
            helper.logStrategyState("perform", state1);
            state0 = state1;
            _executeOrder();
            state1 = helper.getStrategyState();
            helper.logStrategyState("execute", state1);
            _validateStateTransition(state0, state1);
            (upkeepNeeded, performData) = strategy.checkUpkeep("");
        }
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/MINT TEST
    //////////////////////////////////////////////////////////////*/

    function test_previewDepositMint_first() public view {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        assertEq(shares, TEN_THOUSANDS_USDC);
        uint256 assets = vault.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_first() public validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user1, TEN_THOUSANDS_USDC);
        assertEq(vault.balanceOf(user1), shares);
    }

    function test_mint_first() public validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        _mint(user1, shares);
        assertEq(vault.balanceOf(user1), shares);
        assertEq(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC);
    }

    function test_managementFee() public validateFinalState {
        address recipient = makeAddr("recipient");
        vm.startPrank(owner);
        vault.setFeeInfos(recipient, 0.05 ether, 0, 0);

        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        _mint(user1, shares);
        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = assetPriceFeed;
        priceFeeds[1] = productPriceFeed;
        _moveTimestamp(36.5 days, priceFeeds);
        vm.startPrank(user1);
        vault.requestRedeem(shares / 2, user1, user1);
        assertEq(vault.balanceOf(recipient), shares / 200);
    }

    function test_previewDepositMint_whenNotUtilized() public afterDeposited {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = vault.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenNotUtilized() public afterDeposited validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(vault.balanceOf(user2), shares);
    }

    function test_mint_whenNotUtilized() public afterDeposited validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(vault.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC * 3 / 2);
    }

    function test_previewDepositMint_whenPartialUtilized() public afterPartialUtilized {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = vault.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenPartialUtilized() public afterPartialUtilized validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(vault.balanceOf(user2), shares);
    }

    function test_mint_whenPartialUtilized() public afterPartialUtilized validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(vault.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC);
    }

    function test_previewDepositMint_whenFullUtilized() public afterFullUtilized {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = vault.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenFullUtilized() public afterFullUtilized validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(vault.balanceOf(user2), shares);
    }

    function test_mint_whenFullUtilized() public afterFullUtilized validateFinalState {
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(vault.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC / 2);
    }

    function test_previewDepositMint_withPendingWithdraw() public afterWithdrawRequestCreated {
        uint256 shares = vault.previewDeposit(THOUSAND_USDC);
        uint256 assets = vault.previewMint(shares);
        assertEq(assets, THOUSAND_USDC);
    }

    function test_deposit_withPendingWithdraw_smallerThanTotalPendingWithdraw()
        public
        afterWithdrawRequestCreated
        validateFinalState
    {
        uint256 pendingWithdrawBefore = vault.totalPendingWithdraw();
        uint256 shares = vault.previewDeposit(THOUSAND_USDC);
        _deposit(user2, THOUSAND_USDC);
        assertEq(vault.balanceOf(user2), shares);
        uint256 pendingWithdrawAfter = vault.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter + THOUSAND_USDC, pendingWithdrawBefore);
        assertFalse(vault.isClaimable(vault.getWithdrawKey(user1, 0)));
    }

    function test_deposit_withPendingWithdraw_biggerThanTotalPendingWithdraw()
        public
        afterWithdrawRequestCreated
        validateFinalState
    {
        uint256 pendingWithdrawBefore = vault.totalPendingWithdraw();
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user2, TEN_THOUSANDS_USDC);
        assertEq(vault.balanceOf(user2), shares);
        uint256 pendingWithdrawAfter = vault.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter, 0);
        assertTrue(vault.isClaimable(vault.getWithdrawKey(user1, 0)));
        assertTrue(pendingWithdrawBefore > 0);
        assertEq(vault.idleAssets(), TEN_THOUSANDS_USDC - uint256(pendingWithdrawBefore));
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE TEST
    //////////////////////////////////////////////////////////////*/

    function test_utilize_partialDepositing() public afterDeposited validateFinalState {
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset / 2);
        uint256 totalAssets = vault.totalAssets();
        assertApproxEqRel(totalAssets, TEN_THOUSANDS_USDC, 0.99 ether);
        assertEq(IERC20(asset).balanceOf(address(vault)), TEN_THOUSANDS_USDC / 2);
        assertEq(IERC20(asset).balanceOf(address(_hedgeManager())), 0);
    }

    function test_utilize_fullDepositing() public afterDeposited validateFinalState {
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();
        _utilize(pendingUtilization);
        uint256 totalAssets = vault.totalAssets();
        assertApproxEqRel(totalAssets, TEN_THOUSANDS_USDC, 0.99 ether);
        assertEq(IERC20(asset).balanceOf(address(vault)), 0);
        assertEq(IERC20(asset).balanceOf(address(_hedgeManager())), 0);
        (pendingUtilization,) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM/WITHDRAW TEST
    //////////////////////////////////////////////////////////////*/

    function test_previewWithdrawRedeem_whenIdleEnough() public afterDeposited {
        uint256 totalShares = vault.balanceOf(user1);
        uint256 assets = vault.previewRedeem(totalShares / 2);
        uint256 shares = vault.previewWithdraw(assets);
        assertEq(shares, totalShares / 2);
    }

    function test_withdraw_whenIdleEnough() public afterDeposited validateFinalState {
        uint256 user1BalanceBefore = IERC20(asset).balanceOf(user1);
        uint256 totalShares = vault.balanceOf(user1);
        uint256 assets = vault.previewRedeem(totalShares / 2);
        uint256 shares = vault.previewWithdraw(assets);
        vault.requestWithdraw(assets, user1, user1);
        uint256 user1BalanceAfter = IERC20(asset).balanceOf(user1);
        uint256 sharesAfter = vault.balanceOf(user1);
        assertEq(user1BalanceAfter, user1BalanceBefore + assets);
        assertEq(sharesAfter, totalShares - shares);
    }

    function test_previewWithdrawRedeem_whenIdleNotEnough() public afterPartialUtilized validateFinalState {
        uint256 totalShares = vault.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = vault.previewRedeem(redeemShares);
        uint256 shares = vault.previewWithdraw(assets);
        assertEq(shares, redeemShares);
    }

    function test_maxWithdraw() public afterPartialUtilized validateFinalState {
        uint256 maxWithdraw = vault.maxWithdraw(user1);
        uint256 idleAssets = vault.idleAssets();
        assertEq(maxWithdraw, idleAssets);
    }

    function test_maxRedeem() public afterPartialUtilized validateFinalState {
        uint256 maxRedeem = vault.maxRedeem(user1);
        uint256 maxAssets = vault.previewRedeem(maxRedeem);
        uint256 idleAssets = vault.idleAssets();
        assertEq(maxAssets, idleAssets);
    }

    function test_withdraw_whenIdleNotEnough() public afterPartialUtilized validateFinalState {
        uint256 totalShares = vault.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = vault.previewRedeem(redeemShares);
        uint256 idleAssets = vault.idleAssets();
        vm.startPrank(user1);
        bytes32 requestKey = vault.requestRedeem(redeemShares, user1, user1);
        LogarithmVault.WithdrawRequest memory withdrawRequest = vault.withdrawRequests(requestKey);
        assertFalse(vault.isClaimable(requestKey));
        assertEq(withdrawRequest.requestedAssets, assets - idleAssets);
        assertEq(withdrawRequest.receiver, user1);
        assertEq(withdrawRequest.accRequestedWithdrawAssets, assets - idleAssets);
        assertEq(vault.idleAssets(), 0);
        assertEq(vault.assetsToClaim(), 0);
        assertEq(vault.processedWithdrawAssets(), 0);
        assertEq(withdrawRequest.accRequestedWithdrawAssets, vault.accRequestedWithdrawAssets());
    }

    /*//////////////////////////////////////////////////////////////
                        DEUTILIZE/UPKEEP TEST
    //////////////////////////////////////////////////////////////*/

    function test_prioritizedWithdraw_whenNotLast() public prioritize(metaVault) validateFinalState {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _deposit(metaVault, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        assertEq(vault.idleAssets(), 0, "idle asset should be 0");

        uint256 redeemShares = vault.balanceOf(user1) / 3;
        vm.startPrank(user1);
        vault.requestRedeem(redeemShares, user1, user1);
        vm.startPrank(metaVault);
        vault.requestRedeem(vault.balanceOf(metaVault) / 3, metaVault, metaVault);
        vm.stopPrank();

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization / 2);

        bytes32 userRequestKey = vault.getWithdrawKey(user1, 0);
        bytes32 metaVaultRequestKey = vault.getWithdrawKey(metaVault, 0);

        assertFalse(vault.isClaimable(userRequestKey), "user withdraw request not processed");
        assertTrue(vault.isClaimable(metaVaultRequestKey), "meta vault request processed");

        LogarithmVault.WithdrawRequest memory req = vault.withdrawRequests(metaVaultRequestKey);
        uint256 balBefore = IERC20(asset).balanceOf(metaVault);
        vm.startPrank(metaVault);
        vault.claim(metaVaultRequestKey);
        uint256 balAfter = IERC20(asset).balanceOf(metaVault);

        assertEq(balAfter - balBefore, req.requestedAssets, "requestedAssets should be claimed");
    }

    function test_prioritizedWithdraw_lastRedeemWhenOnlyMetaVault() public prioritize(metaVault) validateFinalState {
        _deposit(metaVault, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        assertEq(vault.idleAssets(), 0, "idle asset should be 0");

        vm.startPrank(metaVault);
        vault.requestRedeem(vault.balanceOf(metaVault), metaVault, metaVault);
        vm.stopPrank();

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);

        bytes32 metaVaultRequestKey = vault.getWithdrawKey(metaVault, 0);
        LogarithmVault.WithdrawRequest memory req = vault.withdrawRequests(metaVaultRequestKey);
        uint256 balBefore = IERC20(asset).balanceOf(metaVault);
        vm.startPrank(metaVault);
        vault.claim(metaVaultRequestKey);
        uint256 balAfter = IERC20(asset).balanceOf(metaVault);
        // console.log("balBefore", balBefore);
        // console.log("balAfter", balAfter);
        // console.log("requestedAssets", req.requestedAssets);
        assertTrue(balAfter - balBefore >= req.requestedAssets, "meta vault claims all as it is last");
        assertEq(
            vault.prioritizedAccRequestedWithdrawAssets(),
            vault.prioritizedProcessedWithdrawAssets(),
            "processed assets should be full"
        );
    }

    function test_prioritizedWithdraw_lastRedeemWhenNotOnlyMetaVault()
        public
        prioritize(metaVault)
        validateFinalState
    {
        _deposit(metaVault, TEN_THOUSANDS_USDC);
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        assertEq(vault.idleAssets(), 0, "idle asset should be 0");

        // user's withdraw first
        vm.startPrank(user1);
        vault.requestRedeem(vault.balanceOf(user1), user1, user1);
        vm.stopPrank();

        // metaVault's withdraw after
        vm.startPrank(metaVault);
        vault.requestRedeem(vault.balanceOf(metaVault), metaVault, metaVault);
        vm.stopPrank();

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);

        bytes32 metaVaultRequestKey = vault.getWithdrawKey(metaVault, 0);
        bytes32 userRequestKey = vault.getWithdrawKey(user1, 0);
        LogarithmVault.WithdrawRequest memory metaReq = vault.withdrawRequests(metaVaultRequestKey);
        LogarithmVault.WithdrawRequest memory userReq = vault.withdrawRequests(userRequestKey);

        uint256 metaBalBefore = IERC20(asset).balanceOf(metaVault);
        uint256 userBalBefore = IERC20(asset).balanceOf(user1);

        vm.startPrank(user1);
        vault.claim(userRequestKey);
        vm.startPrank(metaVault);
        vault.claim(metaVaultRequestKey);
        vm.stopPrank();

        uint256 metaBalAfter = IERC20(asset).balanceOf(metaVault);
        uint256 userBalAfter = IERC20(asset).balanceOf(user1);

        assertTrue(
            metaBalAfter - metaBalBefore == metaReq.requestedAssets,
            "meta claimed assets should be ths same as requested"
        );
        assertTrue(
            userBalAfter - userBalBefore > userReq.requestedAssets, "user claims all remaining assets as it is last"
        );
        assertEq(
            vault.prioritizedAccRequestedWithdrawAssets(),
            vault.prioritizedProcessedWithdrawAssets(),
            "processed assets should be full"
        );
        assertEq(vault.accRequestedWithdrawAssets(), vault.processedWithdrawAssets(), "processed assets should be full");
    }

    function test_prioritizedWithdraw_lastRedeemAfterAllNormalClaimed()
        public
        prioritize(metaVault)
        validateFinalState
    {
        _deposit(metaVault, TEN_THOUSANDS_USDC);
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        assertEq(vault.idleAssets(), 0, "idle asset should be 0");

        // user's withdraw first
        vm.startPrank(user1);
        vault.requestRedeem(vault.balanceOf(user1), user1, user1);
        vm.stopPrank();

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingDeutilization, 0, "no deutilization");

        uint256 userBalBefore = IERC20(asset).balanceOf(user1);
        bytes32 userRequestKey = vault.getWithdrawKey(user1, 0);
        LogarithmVault.WithdrawRequest memory userReq = vault.withdrawRequests(userRequestKey);
        vm.startPrank(user1);
        vault.claim(userRequestKey);
        vm.stopPrank();
        uint256 userBalAfter = IERC20(asset).balanceOf(user1);
        assertEq(userBalAfter - userBalBefore, userReq.requestedAssets, "user's request shouldn't be last");

        // metaVault's withdraw after
        vm.startPrank(metaVault);
        vault.requestRedeem(vault.balanceOf(metaVault), metaVault, metaVault);
        vm.stopPrank();

        (, pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        (, pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingDeutilization, 0, "no deutilization");

        uint256 metaBalBefore = IERC20(asset).balanceOf(metaVault);
        bytes32 metaVaultRequestKey = vault.getWithdrawKey(metaVault, 0);
        LogarithmVault.WithdrawRequest memory metaReq = vault.withdrawRequests(metaVaultRequestKey);
        vm.startPrank(metaVault);
        vault.claim(metaVaultRequestKey);
        vm.stopPrank();
        uint256 metaBalAfter = IERC20(asset).balanceOf(metaVault);

        assertTrue(metaBalAfter - metaBalBefore > metaReq.requestedAssets, "meta's request should be last");

        assertEq(
            vault.prioritizedAccRequestedWithdrawAssets(),
            vault.prioritizedProcessedWithdrawAssets(),
            "processed assets should be full"
        );
        assertEq(vault.accRequestedWithdrawAssets(), vault.processedWithdrawAssets(), "processed assets should be full");
    }

    function test_deutilize_partial_withSingleRequest() public afterWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization / 2);
        bytes32 requestKey = vault.getWithdrawKey(user1, 0);
        assertFalse(vault.isClaimable(requestKey));
        vm.expectRevert(Errors.RequestNotExecuted.selector);
        vm.startPrank(user1);
        vault.claim(requestKey);
    }

    function test_deutilize_full_withSingleRequest() public afterWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        bytes32 requestKey = vault.getWithdrawKey(user1, 0);
        assertTrue(vault.isClaimable(requestKey));

        LogarithmVault.WithdrawRequest memory withdrawRequest = vault.withdrawRequests(requestKey);
        uint256 balanceBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        vault.claim(requestKey);
        uint256 balanceAfter = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore + withdrawRequest.requestedAssets, balanceAfter);
    }

    function test_deutilize_partial_withMultipleRequest()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization / 2);

        bytes32 requestKey1 = vault.getWithdrawKey(user1, 0);
        assertTrue(vault.isClaimable(requestKey1));

        bytes32 requestKey2 = vault.getWithdrawKey(user2, 0);
        assertFalse(vault.isClaimable(requestKey2));

        LogarithmVault.WithdrawRequest memory withdrawRequest1 = vault.withdrawRequests(requestKey1);
        uint256 balanceBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        vault.claim(requestKey1);
        uint256 balanceAfter = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore + withdrawRequest1.requestedAssets, balanceAfter);
    }

    function test_deutilize_full_withMultipleRequest() public afterMultipleWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);

        bytes32 requestKey1 = vault.getWithdrawKey(user1, 0);
        assertTrue(vault.isClaimable(requestKey1));

        bytes32 requestKey2 = vault.getWithdrawKey(user2, 0);
        assertTrue(vault.isClaimable(requestKey2));

        LogarithmVault.WithdrawRequest memory withdrawRequest1 = vault.withdrawRequests(requestKey1);
        uint256 balanceBefore1 = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        vault.claim(requestKey1);
        uint256 balanceAfter1 = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore1 + withdrawRequest1.requestedAssets, balanceAfter1);

        LogarithmVault.WithdrawRequest memory withdrawRequest2 = vault.withdrawRequests(requestKey2);
        uint256 balanceBefore2 = IERC20(asset).balanceOf(user2);
        vm.startPrank(user2);
        vault.claim(requestKey2);
        uint256 balanceAfter2 = IERC20(asset).balanceOf(user2);
        assertEq(balanceBefore2 + withdrawRequest2.requestedAssets, balanceAfter2);
    }

    function test_performUpkeep_rebalanceUp() public afterMultipleWithdrawRequestCreated {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 5 / 10);
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("rebalanceUp");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertTrue(rebalanceUpNeeded);
        assertFalse(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);

        // position.sizeInUsd is changed due to realization of positive pnl
        // so need to execute performUpKeep several times

        _performKeep("rebalanceUp");
    }

    function test_performUpkeep_rebalanceDown_whenIdleEnough() public afterFullUtilized validateFinalState {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(vault), 10000 * 1e6);
        IERC20(asset).transfer(address(strategy), 10000 * 1e6);

        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("rebalanceDown_whenIdleEnough");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);

        _performKeep("rebalanceDown_whenIdleEnough");

        assertTrue(vault.idleAssets() < 10000 * 1e6, "idleAssets");
    }

    function test_performUpkeep_rebalanceDown_whenIdleNotEnough() public afterFullUtilized validateFinalState {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(vault), 10 * 1e6);

        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("rebalanceDown_whenIdleNotEnough");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);

        _performKeep("rebalanceDown_whenIdleNotEnough");

        (, uint256 amount) = strategy.pendingUtilizations();
        _deutilize(amount);

        _performKeep("rebalanceDown_whenIdleNotEnough");

        // assertEq(vault.idleAssets(), 0, "idleAssets");
    }

    function test_performUpkeep_rebalanceDown_whenNoIdle() public afterFullUtilized validateFinalState {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("rebalanceDown_whenIdleNotEnough");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);
        uint256 leverageBefore = _hedgeManager().currentLeverage();
        _performKeep("rebalanceDown_whenIdleNotEnough");
        uint256 leverageAfter = _hedgeManager().currentLeverage();
        assertEq(leverageBefore, leverageAfter, "leverage not changed");
        assertEq(strategy.processingRebalanceDown(), true);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        _performKeep("rebalanceDown_whenIdleNotEnough");
    }

    function test_performUpkeep_rebalanceDown_deutilize_withLessPendingWithdrawals()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);

        (bool upkeepNeeded, bytes memory performData) =
            _checkUpkeep("rebalanceDown_deutilize_withLessPendingWithdrawals");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);
        uint256 leverageBefore = _hedgeManager().currentLeverage();
        _performKeep("rebalanceDown_deutilize_withLessPendingWithdrawals");
        uint256 leverageAfter = _hedgeManager().currentLeverage();
        assertEq(leverageBefore, leverageAfter, "leverage not changed");
        assertEq(strategy.processingRebalanceDown(), true);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        (upkeepNeeded, performData) = _checkUpkeep("rebalanceDown_deutilize_withLessPendingWithdrawals");
        assertTrue(upkeepNeeded, "upkeep is needed");
        if (upkeepNeeded) {
            vm.startPrank(forwarder);
            strategy.performUpkeep(performData);
            _executeOrder();
        }
    }

    function test_performUpkeep_rebalanceDown_deutilize_withGreaterPendingWithdrawals()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        uint256 redeemShares1 = vault.balanceOf(user1) / 2;
        vm.startPrank(user1);
        vault.requestRedeem(redeemShares1, user1, user1);

        uint256 redeemShares2 = vault.balanceOf(user2) / 2;
        vm.startPrank(user2);
        vault.requestRedeem(redeemShares2, user2, user2);

        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);

        (bool upkeepNeeded, bytes memory performData) =
            _checkUpkeep("rebalanceDown_deutilize_withGreaterPendingWithdrawal");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertFalse(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);
        uint256 leverageBefore = _hedgeManager().currentLeverage();
        _performKeep("rebalanceDown_deutilize_withGreaterPendingWithdrawal");
        uint256 leverageAfter = _hedgeManager().currentLeverage();
        assertEq(leverageBefore, leverageAfter, "leverage not changed");
        assertEq(strategy.processingRebalanceDown(), true);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        (upkeepNeeded,) = _checkUpkeep("rebalanceDown_deutilize_withGreaterPendingWithdrawal");
        assertFalse(upkeepNeeded, "upkeep is not needed");
    }

    function test_performUpkeep_emergencyRebalanceDown_whenNotIdle()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 13 / 10);
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("emergencyRebalanceDown_whenNotIdle");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertTrue(rebalanceDownNeeded, "rebalanceDownNeeded");
        // assertTrue(deleverageNeeded, "deleverageNeeded");
        assertFalse(hedgeManagerNeedKeep, "hedgeManagerNeedKeep");

        _performKeep("emergencyRebalanceDown_whenNotIdle");
    }

    function test_performUpkeep_emergencyRebalanceDown_whenIdleNotEnough() public afterMultipleWithdrawRequestCreated 
    // validateFinalState
    {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(vault), 100 * 1e6);
        assertTrue(IERC20(asset).balanceOf(address(vault)) > 0);
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 13 / 10);
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("emergencyRebalanceDown_whenIdleNotEnough");
        assertTrue(upkeepNeeded);
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        // assertTrue(deleverageNeeded);
        assertFalse(hedgeManagerNeedKeep);
        _performKeep("emergencyRebalanceDown_whenIdleNotEnough");
        assertTrue(IERC20(asset).balanceOf(address(vault)) > 0);
    }

    function test_performUpkeep_emergencyRebalanceDown_whenIdleEnough()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(vault), TEN_THOUSANDS_USDC);
        uint256 vaultBalanceBefore = IERC20(asset).balanceOf(address(vault));
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 13 / 10);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE), "not idle");
        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("emergencyRebalanceDown_whenIdleEnough");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (bool rebalanceDownNeeded, bool deleverageNeeded,, bool hedgeManagerNeedKeep,, bool rebalanceUpNeeded) =
            helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertTrue(rebalanceDownNeeded, "rebalanceDownNeeded");
        // assertTrue(deleverageNeeded, "deleverageNeeded");
        assertFalse(hedgeManagerNeedKeep, "rebalanceUpNeeded");
        vm.startPrank(forwarder);
        strategy.performUpkeep(performData);
        _executeOrder();
        uint256 vaultBalanceAfter = IERC20(asset).balanceOf(address(strategy));
        assertTrue(vaultBalanceAfter < vaultBalanceBefore);
    }

    function test_performUpkeep_hedgeDeviation_down() public afterMultipleWithdrawRequestCreated validateFinalState {
        vm.startPrank(address(spotManager));
        IERC20(product).transfer(address(this), IERC20(product).balanceOf(address(spotManager)) / 10);

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("hedgeDeviation_down");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool hedgeManagerNeedKeep,
            ,
            bool rebalanceUpNeeded
        ) = helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertFalse(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertFalse(deleverageNeeded, "deleverageNeeded");
        assertFalse(hedgeManagerNeedKeep, "hedgeManagerNeedKeep");

        assertTrue(hedgeDeviationInTokens != 0, "hedge deviation");

        _performKeep("hedgeDeviation_down");
    }

    function test_performUpkeep_hedgeDeviation_down_whenNoPosition() public afterDeposited validateFinalState {
        vm.startPrank(WETH_WHALE);
        IERC20(product).transfer(address(spotManager), 1 ether);

        assertEq(spotManager.exposure(), 1 ether, "exposure");

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("hedgeDeviation_down");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool hedgeManagerNeedKeep,
            ,
            bool rebalanceUpNeeded
        ) = helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertFalse(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertFalse(deleverageNeeded, "deleverageNeeded");
        assertFalse(hedgeManagerNeedKeep, "hedgeManagerNeedKeep");

        assertTrue(hedgeDeviationInTokens != 0, "hedge deviation");

        _performKeep("hedgeDeviation_down");
        assertEq(spotManager.exposure(), 0, "exposure");
    }

    function test_performUpkeep_hedgeDeviation_up() public afterMultipleWithdrawRequestCreated validateFinalState {
        vm.startPrank(address(WETH_WHALE));
        IERC20(product).transfer(address(spotManager), IERC20(product).balanceOf(address(spotManager)) / 10);

        (bool upkeepNeeded, bytes memory performData) = _checkUpkeep("hedgeDeviation_up");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool hedgeManagerNeedKeep,
            ,
            bool rebalanceUpNeeded
        ) = helper.decodePerformData(performData);
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertFalse(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertFalse(deleverageNeeded, "deleverageNeeded");
        assertFalse(hedgeManagerNeedKeep, "hedgeManagerNeedKeep");

        assertTrue(hedgeDeviationInTokens != 0, "hedge deviation");

        _performKeep("hedgeDeviation_up");
    }

    /*//////////////////////////////////////////////////////////////
                        REVERT TEST
    //////////////////////////////////////////////////////////////*/

    function test_afterAdjustPosition_revert_whenDeutilizing() public afterWithdrawRequestCreated {
        uint256 productBefore = IERC20(product).balanceOf(address(strategy));

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        // bytes memory data = _generateInchCallData(product, asset, pendingDeutilization, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(pendingDeutilization, ISpotManager.SwapType.MANUAL, "");

        vm.startPrank(address(_hedgeManager()));
        strategy.afterAdjustPosition(
            IHedgeManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: false})
        );

        bytes32 requestKey = vault.getWithdrawKey(user1, 0);
        assertFalse(vault.isClaimable(requestKey));

        uint256 productAfter = IERC20(product).balanceOf(address(strategy));

        assertApproxEqRel(productAfter, productBefore, 0.9999 ether);

        assertTrue(strategy.paused());
    }

    /*//////////////////////////////////////////////////////////////
                            CIRCUIT BREAKER
    //////////////////////////////////////////////////////////////*/

    function test_circuit_breaker_pauseStrategy() public afterDeposited {
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();
        assertGt(pendingUtilization, 0);
        vm.startPrank(owner);
        strategy.pause();
        (pendingUtilization,) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
    }

    function test_circuit_breaker_unpauseStrategy() public afterDeposited {
        vm.startPrank(owner);
        strategy.pause();
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
        vm.startPrank(owner);
        strategy.unpause();
        (pendingUtilization,) = strategy.pendingUtilizations();
        assertGt(pendingUtilization, 0);
    }

    function test_circuit_breaker_stopStrategy() public afterMultipleWithdrawRequestCreated {
        vm.startPrank(owner);
        strategy.stop();
        _executeOrder();
        StrategyState memory state = helper.getStrategyState();
        assertTrue(strategy.paused());
        assertEq(state.utilizedAssets, 0, "utilizedAssets");
        assertEq(state.productBalance, 0, "productBalance");
        assertEq(state.assetsToWithdraw, 0, "assetsToWithdraw");
        assertEq(state.pendingUtilization, 0, "pendingUtilization");
        assertEq(state.pendingDeutilization, 0, "pendingDeutilization");
        assertEq(state.positionNetBalance, 0, "positionNetBalance");
        assertEq(state.upkeepNeeded, false, "upkeepNeeded");
    }

    function test_circuit_breaker_revert_stopStrategy() public afterMultipleWithdrawRequestCreated {
        address anyone = makeAddr("anyone");
        vm.startPrank(anyone);
        vm.expectRevert(Errors.CallerNotOwnerOrVault.selector);
        strategy.stop();
    }

    function test_circuit_breaker_shutdown_stopStrategy() public afterMultipleWithdrawRequestCreated {
        vm.startPrank(owner);
        vault.shutdown();
        _executeOrder();
        StrategyState memory state = helper.getStrategyState();
        assertTrue(strategy.paused());
        assertEq(state.utilizedAssets, 0, "utilizedAssets");
        assertEq(state.productBalance, 0, "productBalance");
        assertEq(state.assetsToWithdraw, 0, "assetsToWithdraw");
        assertEq(state.pendingUtilization, 0, "pendingUtilization");
        assertEq(state.pendingDeutilization, 0, "pendingDeutilization");
        assertEq(state.positionNetBalance, 0, "positionNetBalance");
        assertEq(state.upkeepNeeded, false, "upkeepNeeded");
    }

    function test_circuit_breaker_revert_deposit_whenShutdown() public afterMultipleWithdrawRequestCreated {
        vm.startPrank(owner);
        vault.shutdown();
        vm.startPrank(user1);
        IERC20(asset).approve(address(vault), TEN_THOUSANDS_USDC);
        vm.expectRevert();
        vault.deposit(TEN_THOUSANDS_USDC, user1);
    }

    function test_circuit_breaker_revert_mint_whenShutdown() public afterMultipleWithdrawRequestCreated {
        vm.startPrank(owner);
        vault.shutdown();
        vm.startPrank(user1);
        uint256 shares = 10000000;
        uint256 assets = vault.previewMint(shares);
        IERC20(asset).approve(address(vault), assets);
        vm.expectRevert();
        vault.mint(shares, user1);
    }

    function test_circuit_breaker_revert_shutdown() public afterMultipleWithdrawRequestCreated {
        address anyone = makeAddr("anyone");
        vm.startPrank(anyone);
        vm.expectRevert();
        vault.shutdown();
    }

    error EnforcedPause();

    function test_circuit_breaker_pauseVaultWithStopStrategy() public afterMultipleWithdrawRequestCreated {
        address securityManager = makeAddr("security");
        vm.startPrank(owner);
        vault.setSecurityManager(securityManager);
        vm.startPrank(securityManager);
        vault.pause(true);
        _executeOrder();

        StrategyState memory state = helper.getStrategyState();
        assertTrue(strategy.paused());
        assertEq(state.utilizedAssets, 0, "utilizedAssets");
        assertEq(state.productBalance, 0, "productBalance");
        assertEq(state.assetsToWithdraw, 0, "assetsToWithdraw");
        assertEq(state.pendingUtilization, 0, "pendingUtilization");
        assertEq(state.pendingDeutilization, 0, "pendingDeutilization");
        assertEq(state.positionNetBalance, 0, "positionNetBalance");
        assertEq(state.upkeepNeeded, false, "upkeepNeeded");
    }

    function test_circuit_breaker_pauseVaultWithPauseStrategy() public afterMultipleWithdrawRequestCreated {
        address securityManager = makeAddr("security");
        vm.startPrank(owner);
        vault.setSecurityManager(securityManager);
        vm.startPrank(securityManager);
        vault.pause(false);

        StrategyState memory state = helper.getStrategyState();
        assertTrue(strategy.paused());
        assertNotEq(state.utilizedAssets, 0, "utilizedAssets");
        assertNotEq(state.productBalance, 0, "productBalance");
        assertEq(state.assetsToWithdraw, 0, "assetsToWithdraw");
        assertEq(state.pendingUtilization, 0, "pendingUtilization");
        assertEq(state.pendingDeutilization, 0, "pendingDeutilization");
        assertNotEq(state.positionNetBalance, 0, "positionNetBalance");
        assertEq(state.upkeepNeeded, false, "upkeepNeeded");
    }
}
