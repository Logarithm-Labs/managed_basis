// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {InchTest} from "./base/InchTest.sol";
import {GmxV2Test} from "./base/GmxV2Test.sol";
import {OffChainTest} from "test/base/OffChainTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";

import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Errors} from "src/libraries/Errors.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";

import {console} from "forge-std/console.sol";

contract AccumulatedBasisStrategyTest is InchTest, OffChainTest {
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address operator = makeAddr("operator");

    uint256 constant USD_PRECISION = 1e30;

    uint256 public TEN_THOUSANDS_USDC = 10_000 * 1e6;
    uint256 public THOUSAND_USDC = 1_000 * 1e6;

    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0.01 ether;
    uint256 constant exitCost = 0.02 ether;
    bool constant isLong = false;

    uint256 constant targetLeverage = 3 ether;

    AccumulatedBasisStrategy strategy;
    LogarithmOracle oracle;
    uint256 increaseFee;
    uint256 decreaseFee;

    function setUp() public {
        _forkArbitrum(0);
        vm.startPrank(owner);
        // deploy oracle
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        oracle = LogarithmOracle(oracleProxy);
        vm.label(address(oracle), "oracle");

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

        // deploy strategy
        address strategyImpl = address(new AccumulatedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    AccumulatedBasisStrategy.initialize.selector,
                    asset,
                    product,
                    oracle,
                    operator,
                    targetLeverage,
                    entryCost,
                    exitCost
                )
            )
        );
        strategy = AccumulatedBasisStrategy(strategyProxy);
        vm.label(address(strategy), "strategy");

        // deploy position manager
        address positionManagerImpl = address(new OffChainPositionManager());
        address positionManagerProxy = address(
            new ERC1967Proxy(
                positionManagerImpl,
                abi.encodeWithSelector(
                    OffChainPositionManager.initialize.selector,
                    address(strategy),
                    agent,
                    address(oracle),
                    product,
                    asset,
                    false
                )
            )
        );
        positionManager = OffChainPositionManager(positionManagerProxy);
        vm.label(address(positionManager), "positionManager");

        strategy.setPositionManager(positionManagerProxy);

        _initOffChainTest(asset, product, address(oracle));

        // top up user1
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(user1, 10_000_000 * 1e6);
        IERC20(asset).transfer(user2, 10_000_000 * 1e6);
    }

    modifier afterDeposited() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _;
    }

    modifier afterPartialUtilized() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _utilize(strategy.pendingUtilization() / 2);
        _;
    }

    modifier afterFullUtilized() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _utilize(strategy.pendingUtilization());
        _;
    }

    modifier afterWithdrawRequestCreated() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _utilize(strategy.pendingUtilization() / 2);
        uint256 redeemShares = strategy.balanceOf(user1) * 2 / 3;
        vm.startPrank(user1);
        strategy.redeem(redeemShares, user1, user1);
        _;
    }

    modifier afterMultipleWithdrawRequestCreated() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        _utilize(strategy.pendingUtilization());
        _deposit(user2, TEN_THOUSANDS_USDC);
        _utilize(strategy.pendingUtilization());

        uint256 redeemShares1 = strategy.balanceOf(user1) / 5;
        vm.startPrank(user1);
        strategy.redeem(redeemShares1, user1, user1);

        uint256 redeemShares2 = strategy.balanceOf(user2) / 4;
        vm.startPrank(user2);
        strategy.redeem(redeemShares2, user2, user2);
        _;
    }

    function _deposit(address from, uint256 assets) private {
        vm.startPrank(from);
        IERC20(asset).approve(address(strategy), assets);
        strategy.deposit(assets, from);
    }

    function _mint(address from, uint256 shares) private {
        vm.startPrank(from);
        uint256 assets = strategy.previewMint(shares);
        IERC20(asset).approve(address(strategy), assets);
        strategy.mint(shares, from);
    }

    function _utilize(uint256 amount) private {
        bytes memory data = _generateInchCallData(asset, product, amount, address(strategy));
        vm.startPrank(operator);
        strategy.utilize(amount, AccumulatedBasisStrategy.SwapType.INCH_V6, data);
        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.DEPOSITING));
        _fullOffChainExecute();
        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.IDLE));
    }

    function _deutilize(uint256 amount) private {
        bytes memory data = _generateInchCallData(product, asset, amount, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(amount, AccumulatedBasisStrategy.SwapType.INCH_V6, data);
        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.WITHDRAWING));
        _fullOffChainExecute();
        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.IDLE));
    }

    function _performUpkeep() private {
        (, bytes memory performData) = strategy.checkUpkeep("");
        (, bool hedgeDeviation, bool decreaseCollateral) = abi.decode(performData, (bool, bool, bool));
        if (hedgeDeviation) {
            strategy.performUpkeep("");
            assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.KEEPING));
            _fullOffChainExecute();
        }

        if (decreaseCollateral) {
            strategy.performUpkeep("");
            assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.KEEPING));
            _fullOffChainExecute();
        }

        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.IDLE));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/MINT TEST
    //////////////////////////////////////////////////////////////*/

    function test_previewDepositMint_first() public view {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        assertEq(shares, TEN_THOUSANDS_USDC);
        uint256 assets = strategy.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_first() public {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user1, TEN_THOUSANDS_USDC);
        assertEq(strategy.balanceOf(user1), shares);
    }

    function test_mint_first() public {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        _mint(user1, shares);
        assertEq(strategy.balanceOf(user1), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC);
    }

    function test_previewDepositMint_whenNotUtilized() public afterDeposited {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = strategy.previewMint(shares);
        assertEq(shares, TEN_THOUSANDS_USDC * (1 ether - entryCost) / 1 ether);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenNotUtilized() public afterDeposited {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.balanceOf(user2), shares);
    }

    function test_mint_whenNotUtilized() public afterDeposited {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(strategy.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC * 3 / 2);
    }

    function test_previewDepositMint_whenPartialUtilized() public afterPartialUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = strategy.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenPartialUtilized() public afterPartialUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.balanceOf(user2), shares);
    }

    // @review srategy asset balance after full utilization should be zero
    // thus last assertion should be TEN_THOUSANDS_USDC
    function test_mint_whenPartialUtilized() public afterPartialUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(strategy.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC);
    }

    function test_previewDepositMint_whenFullUtilized() public afterFullUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = strategy.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenFullUtilized() public afterFullUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.balanceOf(user2), shares);
    }

    // @review srategy asset balance after full utilization should be zero
    // thus last assertion should be TEN_THOUSANDS_USDC / 2
    function test_mint_whenFullUtilized() public afterFullUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(strategy.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC / 2);
    }

    function test_previewDepositMint_withPendingWithdraw() public afterWithdrawRequestCreated {
        uint256 shares = strategy.previewDeposit(THOUSAND_USDC);
        uint256 assets = strategy.previewMint(shares);
        assertEq(assets, THOUSAND_USDC);
    }

    function test_deposit_withPendingWithdraw_smallerThanTotalPendingWithdraw() public afterWithdrawRequestCreated {
        uint256 pendingWithdrawBefore = strategy.totalPendingWithdraw();
        uint256 shares = strategy.previewDeposit(THOUSAND_USDC);
        _deposit(user2, THOUSAND_USDC);
        assertEq(strategy.balanceOf(user2), shares);
        uint256 pendingWithdrawAfter = strategy.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter + THOUSAND_USDC, pendingWithdrawBefore);
        assertFalse(strategy.isClaimable(strategy.getWithdrawKey(user1, 0)));
    }

    function test_deposit_withPendingWithdraw_biggerThanTotalPendingWithdraw() public afterWithdrawRequestCreated {
        uint256 pendingWithdrawBefore = strategy.totalPendingWithdraw();
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user2, TEN_THOUSANDS_USDC);
        assertEq(strategy.balanceOf(user2), shares);
        uint256 pendingWithdrawAfter = strategy.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter, 0);
        assertTrue(strategy.isClaimable(strategy.getWithdrawKey(user1, 0)));
        assertEq(strategy.idleAssets(), TEN_THOUSANDS_USDC - pendingWithdrawBefore);
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE TEST
    //////////////////////////////////////////////////////////////*/

    function test_utilize_partialDepositing() public afterDeposited {
        uint256 pendingUtilization = strategy.pendingUtilization();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilization, pendingIncreaseCollateral * targetLeverage / 1 ether);
        _utilize(pendingUtilization / 2);
        uint256 totalAssets = strategy.totalAssets();
        assertApproxEqRel(totalAssets, TEN_THOUSANDS_USDC, 0.99 ether);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC / 2);
        assertEq(IERC20(asset).balanceOf(address(positionManager)), 0);
        pendingUtilization = strategy.pendingUtilization();
        pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilization, pendingIncreaseCollateral * targetLeverage / 1 ether);
    }

    function test_utilize_fullDepositing() public afterDeposited {
        uint256 pendingUtilization = strategy.pendingUtilization();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilization, pendingIncreaseCollateral * targetLeverage / 1 ether);
        _utilize(pendingUtilization);
        uint256 totalAssets = strategy.totalAssets();
        assertApproxEqRel(totalAssets, TEN_THOUSANDS_USDC, 0.99 ether);
        assertEq(IERC20(asset).balanceOf(address(strategy)), 0);
        assertEq(IERC20(asset).balanceOf(address(positionManager)), 0);
        pendingUtilization = strategy.pendingUtilization();
        pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilization, 0);
        assertEq(pendingIncreaseCollateral, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM/WITHDRAW TEST
    //////////////////////////////////////////////////////////////*/

    function test_previewWithdrawRedeem_whenIdleEnough() public afterDeposited {
        uint256 totalShares = strategy.balanceOf(user1);
        uint256 assets = strategy.previewRedeem(totalShares / 2);
        uint256 shares = strategy.previewWithdraw(assets);
        assertEq(shares, totalShares / 2);
    }

    function test_withdraw_whenIdleEnough() public afterDeposited {
        uint256 user1BalanceBefore = IERC20(asset).balanceOf(user1);
        uint256 totalShares = strategy.balanceOf(user1);
        uint256 assets = strategy.previewRedeem(totalShares / 2);
        uint256 shares = strategy.previewWithdraw(assets);
        strategy.withdraw(assets, user1, user1);
        uint256 user1BalanceAfter = IERC20(asset).balanceOf(user1);
        uint256 sharesAfter = strategy.balanceOf(user1);
        assertEq(user1BalanceAfter, user1BalanceBefore + assets);
        assertEq(sharesAfter, totalShares - shares);
    }

    function test_previewWithdrawRedeem_whenIdleNotEnough() public afterPartialUtilized {
        uint256 totalShares = strategy.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = strategy.previewRedeem(redeemShares);
        uint256 shares = strategy.previewWithdraw(assets);
        assertEq(shares, redeemShares);
    }

    function test_withdraw_whenIdleNotEnough() public afterPartialUtilized {
        uint256 totalShares = strategy.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = strategy.previewRedeem(redeemShares);
        vm.expectEmit();
        emit AccumulatedBasisStrategy.UpdatePendingUtilization(0);
        vm.startPrank(user1);
        strategy.redeem(redeemShares, user1, user1);
        bytes32 requestKey = strategy.getWithdrawKey(user1, 0);
        AccumulatedBasisStrategy.WithdrawRequest memory withdrawRequest = strategy.withdrawRequests(requestKey);
        assertFalse(strategy.isClaimable(requestKey));
        assertEq(withdrawRequest.requestedAssets, assets);
        assertEq(withdrawRequest.receiver, user1);
        assertEq(withdrawRequest.accRequestedWithdrawAssets, assets - TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.idleAssets(), 0);
        assertEq(strategy.assetsToClaim(), TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.proccessedWithdrawAssets(), 0);
        assertEq(withdrawRequest.accRequestedWithdrawAssets, strategy.accRequestedWithdrawAssets());
    }

    /*//////////////////////////////////////////////////////////////
                        DEUTILIZE/UPKEEP TEST
    //////////////////////////////////////////////////////////////*/

    function test_deutilize_partial_withSingleRequest() public afterWithdrawRequestCreated {
        uint256 pendingDeutilization = strategy.pendingDeutilization();
        _deutilize(pendingDeutilization / 2);
        // _performUpkeep();

        bytes32 requestKey = strategy.getWithdrawKey(user1, 0);
        assertFalse(strategy.isClaimable(requestKey));
        vm.expectRevert(Errors.RequestNotExecuted.selector);
        vm.startPrank(user1);
        strategy.claim(requestKey);
    }

    function test_deutilize_full_withSingleRequest() public afterWithdrawRequestCreated {
        uint256 pendingDeutilization = strategy.pendingDeutilization();
        _deutilize(pendingDeutilization);
        _performUpkeep();

        bytes32 requestKey = strategy.getWithdrawKey(user1, 0);
        assertTrue(strategy.isClaimable(requestKey));

        AccumulatedBasisStrategy.WithdrawRequest memory withdrawRequest = strategy.withdrawRequests(requestKey);
        uint256 balanceBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(requestKey);
        uint256 balanceAfter = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore + withdrawRequest.requestedAssets, balanceAfter);
    }

    function test_deutilize_partial_withMultipleRequest() public afterMultipleWithdrawRequestCreated {
        uint256 pendingDeutilization = strategy.pendingDeutilization();
        _deutilize(pendingDeutilization / 2);
        // _performUpkeep();

        bytes32 requestKey1 = strategy.getWithdrawKey(user1, 0);
        assertFalse(strategy.isClaimable(requestKey1));

        pendingDeutilization = strategy.pendingDeutilization();
        _deutilize(pendingDeutilization);

        assertTrue(strategy.isClaimable(requestKey1));

        bytes32 requestKey2 = strategy.getWithdrawKey(user2, 0);
        assertTrue(strategy.isClaimable(requestKey2));

        AccumulatedBasisStrategy.WithdrawRequest memory withdrawRequest1 = strategy.withdrawRequests(requestKey1);
        uint256 balanceBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(requestKey1);
        uint256 balanceAfter = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore + withdrawRequest1.requestedAssets, balanceAfter);
    }

    function test_deutilize_full_withMultipleRequest() public afterMultipleWithdrawRequestCreated {
        uint256 pendingDeutilization = strategy.pendingDeutilization();
        _deutilize(pendingDeutilization);
        // _performUpkeep();

        pendingDeutilization = strategy.pendingDeutilization();
        console.log("pendingDeutilization", pendingDeutilization);

        if (pendingDeutilization > 0) {
            _deutilize(pendingDeutilization);
            // _performUpkeep();
        }

        pendingDeutilization = strategy.pendingDeutilization();
        console.log("pendingDeutilization", pendingDeutilization);

        if (pendingDeutilization > 0) {
            _deutilize(pendingDeutilization);
            // _performUpkeep();
        }

        bytes32 requestKey1 = strategy.getWithdrawKey(user1, 0);
        assertTrue(strategy.isClaimable(requestKey1));

        bytes32 requestKey2 = strategy.getWithdrawKey(user2, 0);
        assertTrue(strategy.isClaimable(requestKey2));

        AccumulatedBasisStrategy.WithdrawRequest memory withdrawRequest1 = strategy.withdrawRequests(requestKey1);
        uint256 balanceBefore1 = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(requestKey1);
        uint256 balanceAfter1 = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore1 + withdrawRequest1.requestedAssets, balanceAfter1);

        AccumulatedBasisStrategy.WithdrawRequest memory withdrawRequest2 = strategy.withdrawRequests(requestKey2);
        uint256 balanceBefore2 = IERC20(asset).balanceOf(user2);
        vm.startPrank(user2);
        strategy.claim(requestKey2);
        uint256 balanceAfter2 = IERC20(asset).balanceOf(user2);
        assertEq(balanceBefore2 + withdrawRequest2.requestedAssets, balanceAfter2);
    }
}
