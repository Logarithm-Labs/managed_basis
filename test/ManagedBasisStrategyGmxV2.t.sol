// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {InchTest} from "./base/InchTest.sol";
import {GmxV2Test} from "./base/GmxV2Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";

import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {Config} from "src/Config.sol";
import {ConfigKeys} from "src/libraries/ConfigKeys.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Keeper} from "src/Keeper.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {console} from "forge-std/console.sol";

contract ManagedBasisStrategyGmxV2Test is InchTest, GmxV2Test {
    using Math for uint256;

    struct StrategyState {
        uint8 strategyStatus;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 utilizedAssets;
        uint256 idleAssets;
        uint256 assetBalance;
        uint256 productBalance;
        uint256 productValueInAsset;
        uint256 assetsToWithdraw;
        uint256 assetsToClaim;
        uint256 totalPendingWithdraw;
        uint256 pendingIncreaseCollateral;
        uint256 pendingDecreaseCollateral;
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 accRequestedWithdrawAssets;
        uint256 proccessedWithdrawAssets;
        uint256 positionNetBalance;
        uint256 positionLeverage;
        uint256 positionSizeInTokens;
        uint256 positionSizeInAsset;
        bool processingRebalance;
        bool upkeepNeeded;
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        bool rehedgeNeeded;
        bool positionManagerKeepNeeded;
    }

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address operator = makeAddr("operator");
    address forwarder = makeAddr("forwarder");

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
    uint256 constant minLeverage = 2 ether;
    uint256 constant maxLeverage = 5 ether;
    uint256 constant safeMarginLeverage = 20 ether;

    ManagedBasisStrategy strategy;
    LogarithmOracle oracle;
    Keeper keeper;
    uint256 increaseFee;
    uint256 decreaseFee;

    function setUp() public {
        _forkArbitrum(238841172);
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

        // deploy config
        Config config = new Config();
        config.initialize(owner);

        config.setAddress(ConfigKeys.GMX_EXCHANGE_ROUTER, GMX_EXCHANGE_ROUTER);
        config.setAddress(ConfigKeys.GMX_DATA_STORE, GMX_DATA_STORE);
        config.setAddress(ConfigKeys.GMX_ORDER_HANDLER, GMX_ORDER_HANDLER);
        config.setAddress(ConfigKeys.GMX_ORDER_VAULT, GMX_ORDER_VAULT);
        config.setAddress(ConfigKeys.GMX_REFERRAL_STORAGE, IOrderHandler(GMX_ORDER_HANDLER).referralStorage());
        config.setAddress(ConfigKeys.GMX_READER, GMX_READER);
        config.setAddress(ConfigKeys.ORACLE, address(oracle));

        config.setAddress(ConfigKeys.gmxMarketKey(asset, product), GMX_ETH_USDC_MARKET);

        config.setUint(ConfigKeys.GMX_CALLBACK_GAS_LIMIT, 2_000_000);
        vm.label(address(config), "config");

        address[] memory pathWeth = new address[](3);
        pathWeth[0] = USDC;
        pathWeth[1] = UNISWAPV3_WETH_USDC;
        pathWeth[2] = WETH;

        // deploy strategy
        address strategyImpl = address(new ManagedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    ManagedBasisStrategy.initialize.selector,
                    "tt",
                    "tt",
                    asset,
                    product,
                    oracle,
                    operator,
                    targetLeverage,
                    minLeverage,
                    maxLeverage,
                    safeMarginLeverage,
                    entryCost,
                    exitCost,
                    pathWeth
                )
            )
        );
        strategy = ManagedBasisStrategy(strategyProxy);
        vm.label(address(strategy), "strategy");

        // deploy keeper
        address keeperImpl = address(new Keeper());
        address keeperProxy = address(
            new ERC1967Proxy(keeperImpl, abi.encodeWithSelector(Keeper.initialize.selector, owner, address(config)))
        );
        keeper = Keeper(payable(keeperProxy));
        vm.label(address(keeper), "keeper");

        config.setAddress(ConfigKeys.KEEPER, address(keeper));

        // deploy positionManager impl
        address positionManagerImpl = address(new GmxV2PositionManager());
        // deploy positionManager beacon
        address positionManagerBeacon = address(new UpgradeableBeacon(positionManagerImpl, owner));
        // deploy positionMnager beacon proxy
        address positionManagerProxy = address(
            new BeaconProxy(
                positionManagerBeacon,
                abi.encodeWithSelector(
                    GmxV2PositionManager.initialize.selector, owner, address(strategy), address(config)
                )
            )
        );
        positionManager = GmxV2PositionManager(payable(positionManagerProxy));
        strategy.setForwarder(forwarder);
        vm.label(address(positionManager), "positionManager");

        strategy.setPositionManager(positionManagerProxy);

        config.setBool(ConfigKeys.isPositionManagerKey(address(positionManager)), true);

        // topup keeper with some native token, in practice, its don't through keeper
        vm.deal(address(keeper), 1 ether);
        vm.stopPrank();
        (increaseFee, decreaseFee) = positionManager.getExecutionFee();
        assert(increaseFee > 0);
        assert(decreaseFee > 0);

        // top up user1
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(user1, 10_000_000 * 1e6);
        IERC20(asset).transfer(user2, 10_000_000 * 1e6);
    }

    function _moveTimestamp(uint256 deltaTime) internal {
        address[] memory priceFeeds = new address[](2);
        priceFeeds[0] = assetPriceFeed;
        priceFeeds[1] = productPriceFeed;
        _moveTimestamp(deltaTime, priceFeeds);
    }

    function _getStrategyState() internal view returns (StrategyState memory state) {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;
        if (performData.length > 0) {
            (rebalanceDownNeeded, deleverageNeeded, hedgeDeviationInTokens, positionManagerNeedKeep, rebalanceUpNeeded,)
            = abi.decode(performData, (bool, bool, int256, bool, bool, uint256));
        }

        state.strategyStatus = uint8(strategy.strategyStatus());
        state.totalSupply = strategy.totalSupply();
        state.totalAssets = strategy.totalAssets();
        state.utilizedAssets = strategy.utilizedAssets();
        state.idleAssets = strategy.idleAssets();
        state.assetBalance = IERC20(asset).balanceOf(address(strategy));
        state.productBalance = IERC20(product).balanceOf(address(strategy));
        state.productValueInAsset = oracle.convertTokenAmount(product, asset, state.productBalance);
        state.assetsToWithdraw = strategy.assetsToWithdraw();
        state.assetsToClaim = strategy.assetsToClaim();
        state.totalPendingWithdraw = strategy.totalPendingWithdraw();
        state.pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        state.pendingDecreaseCollateral = strategy.pendingDecreaseCollateral();
        (state.pendingUtilization, state.pendingDeutilization) = strategy.pendingUtilizations();
        state.accRequestedWithdrawAssets = strategy.accRequestedWithdrawAssets();
        state.proccessedWithdrawAssets = strategy.proccessedWithdrawAssets();
        state.positionNetBalance = positionManager.positionNetBalance();
        state.positionLeverage = positionManager.currentLeverage();
        state.positionSizeInTokens = positionManager.positionSizeInTokens();
        state.positionSizeInAsset = oracle.convertTokenAmount(product, asset, state.positionSizeInTokens);
        state.processingRebalance = strategy.processingRebalance();

        state.upkeepNeeded = upkeepNeeded;
        state.rebalanceUpNeeded = rebalanceUpNeeded;
        state.rebalanceDownNeeded = rebalanceDownNeeded;
        state.deleverageNeeded = deleverageNeeded;
        state.rehedgeNeeded = hedgeDeviationInTokens == 0 ? false : true;
        state.positionManagerKeepNeeded = positionManagerNeedKeep;
    }

    function _logStrategyState(string memory stateName, StrategyState memory state) internal view {
        console.log("===================");
        console.log(stateName);
        console.log("===================");
        console.log("strategyStatus", state.strategyStatus);
        console.log("totalSupply", state.totalSupply);
        console.log("totalAssets", state.totalAssets);
        console.log("utilizedAssets", state.utilizedAssets);
        console.log("idleAssets", state.idleAssets);
        console.log("assetBalance", state.assetBalance);
        console.log("productBalance", state.productBalance);
        console.log("productValueInAsset", state.productValueInAsset);
        console.log("assetsToWithdraw", state.assetsToWithdraw);
        console.log("assetsToClaim", state.assetsToClaim);
        console.log("totalPendingWithdraw", state.totalPendingWithdraw);
        console.log("pendingIncreaseCollateral", state.pendingIncreaseCollateral);
        console.log("pendingDecreaseCollateral", state.pendingDecreaseCollateral);
        console.log("pendingUtilization", state.pendingUtilization);
        console.log("pendingDeutilization", state.pendingDeutilization);
        console.log("accRequestedWithdrawAssets", state.accRequestedWithdrawAssets);
        console.log("proccessedWithdrawAssets", state.proccessedWithdrawAssets);
        console.log("positionNetBalance", state.positionNetBalance);
        console.log("positionLeverage", state.positionLeverage);
        console.log("positionSizeInTokens", state.positionSizeInTokens);
        console.log("positionSizeInAsset", state.positionSizeInAsset);
        console.log("upkeepNeeded", state.upkeepNeeded);
        console.log("rebalanceUpNeeded", state.rebalanceUpNeeded);
        console.log("rebalanceDownNeeded", state.rebalanceDownNeeded);
        console.log("deleverageNeeded", state.deleverageNeeded);
        console.log("rehedgeNeeded", state.rehedgeNeeded);
        console.log("positionManagerNeedKeep", state.positionManagerKeepNeeded);
        console.log("");
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
        assertFalse(state.processingRebalance);
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
        uint256 redeemShares = strategy.balanceOf(user1) * 2 / 3;
        vm.startPrank(user1);
        strategy.redeem(redeemShares, user1, user1);
        _;
    }

    modifier afterMultipleWithdrawRequestCreated() {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        _deposit(user2, TEN_THOUSANDS_USDC);
        (pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);

        uint256 redeemShares1 = strategy.balanceOf(user1) / 5;
        vm.startPrank(user1);
        strategy.redeem(redeemShares1, user1, user1);

        uint256 redeemShares2 = strategy.balanceOf(user2) / 4;
        vm.startPrank(user2);
        strategy.redeem(redeemShares2, user2, user2);
        _;
    }

    modifier validateFinalState() {
        _;
        _validateFinalState(_getStrategyState());
    }

    function _deposit(address from, uint256 assets) private {
        vm.startPrank(from);
        IERC20(asset).approve(address(strategy), assets);
        StrategyState memory state0 = _getStrategyState();
        strategy.deposit(assets, from);
        StrategyState memory state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
    }

    function _mint(address from, uint256 shares) private {
        vm.startPrank(from);
        uint256 assets = strategy.previewMint(shares);
        IERC20(asset).approve(address(strategy), assets);
        StrategyState memory state0 = _getStrategyState();
        strategy.mint(shares, from);
        StrategyState memory state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
    }

    function _utilize(uint256 amount) private {
        vm.startPrank(operator);
        StrategyState memory state0 = _getStrategyState();
        strategy.utilize(amount, DataTypes.SwapType.MANUAL, "");
        StrategyState memory state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(DataTypes.StrategyStatus.UTILIZING));
        (uint256 pendingUtilization, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
        assertEq(pendingDeutilization, 0);
        state0 = state1;
        _fullExcuteOrder();
        state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(DataTypes.StrategyStatus.IDLE));
        _performKeep();
    }

    function _deutilize(uint256 amount) private {
        StrategyState memory state0 = _getStrategyState();
        vm.startPrank(operator);
        strategy.deutilize(amount, DataTypes.SwapType.MANUAL, "");
        StrategyState memory state1 = _getStrategyState();
        // can't guarantee 1% deviation due to price impact of uniswap
        // _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(DataTypes.StrategyStatus.DEUTILIZING));
        (uint256 pendingUtilization, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        assertEq(pendingUtilization, 0);
        assertEq(pendingDeutilization, 0);
        state0 = state1;
        _fullExcuteOrder();
        state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(DataTypes.StrategyStatus.IDLE));

        _performKeep();
    }

    function _deutilizeWithoutExecution(uint256 amount) private {
        // bytes memory data = _generateInchCallData(product, asset, amount, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(amount, DataTypes.SwapType.MANUAL, "");
        assertEq(uint256(strategy.strategyStatus()), uint256(DataTypes.StrategyStatus.DEUTILIZING));
    }

    function _performKeep() private {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");

        while (upkeepNeeded) {
            vm.startPrank(forwarder);
            StrategyState memory state0 = _getStrategyState();
            strategy.performUpkeep(performData);
            StrategyState memory state1 = _getStrategyState();

            // in case of emergency rebalance down, can't guarantee totalAssets deviation is less than 1%
            // due to uniswap price impact
            // _validateStateTransition(state0, state1);

            state0 = state1;
            _fullExcuteOrder();
            state1 = _getStrategyState();
            _validateStateTransition(state0, state1);
            (upkeepNeeded, performData) = strategy.checkUpkeep("");
        }
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

    function test_deposit_first() public validateFinalState {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user1, TEN_THOUSANDS_USDC);
        assertEq(strategy.balanceOf(user1), shares);
    }

    function test_mint_first() public validateFinalState {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        _mint(user1, shares);
        assertEq(strategy.balanceOf(user1), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC);
    }

    function test_previewDepositMint_whenNotUtilized() public afterDeposited {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        uint256 assets = strategy.previewMint(shares);
        assertEq(assets, TEN_THOUSANDS_USDC);
    }

    function test_deposit_whenNotUtilized() public afterDeposited validateFinalState {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.balanceOf(user2), shares);
    }

    function test_mint_whenNotUtilized() public afterDeposited validateFinalState {
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

    function test_deposit_whenPartialUtilized() public afterPartialUtilized validateFinalState {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.balanceOf(user2), shares);
    }

    function test_mint_whenPartialUtilized() public afterPartialUtilized validateFinalState {
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

    function test_deposit_whenFullUtilized() public afterFullUtilized validateFinalState {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _deposit(user2, TEN_THOUSANDS_USDC / 2);
        assertEq(strategy.balanceOf(user2), shares);
    }

    function test_mint_whenFullUtilized() public afterFullUtilized validateFinalState {
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

    function test_deposit_withPendingWithdraw_smallerThanTotalPendingWithdraw()
        public
        afterWithdrawRequestCreated
        validateFinalState
    {
        uint256 pendingWithdrawBefore = strategy.totalPendingWithdraw();
        uint256 shares = strategy.previewDeposit(THOUSAND_USDC);
        _deposit(user2, THOUSAND_USDC);
        assertEq(strategy.balanceOf(user2), shares);
        uint256 pendingWithdrawAfter = strategy.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter + THOUSAND_USDC, pendingWithdrawBefore);
        assertFalse(strategy.isClaimable(strategy.getWithdrawId(user1, 0)));
    }

    function test_deposit_withPendingWithdraw_biggerThanTotalPendingWithdraw()
        public
        afterWithdrawRequestCreated
        validateFinalState
    {
        uint256 pendingWithdrawBefore = strategy.totalPendingWithdraw();
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user2, TEN_THOUSANDS_USDC);
        assertEq(strategy.balanceOf(user2), shares);
        uint256 pendingWithdrawAfter = strategy.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter, 0);
        assertTrue(strategy.isClaimable(strategy.getWithdrawId(user1, 0)));
        assertEq(strategy.idleAssets(), TEN_THOUSANDS_USDC - pendingWithdrawBefore);
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE TEST
    //////////////////////////////////////////////////////////////*/

    function test_utilize_partialDepositing() public afterDeposited validateFinalState {
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilizationInAsset, pendingIncreaseCollateral * targetLeverage / 1 ether);
        _utilize(pendingUtilizationInAsset / 2);
        uint256 totalAssets = strategy.totalAssets();
        assertApproxEqRel(totalAssets, TEN_THOUSANDS_USDC, 0.99 ether);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC / 2);
        assertEq(IERC20(asset).balanceOf(address(positionManager)), 0);
        (pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilizationInAsset, pendingIncreaseCollateral * targetLeverage / 1 ether);
    }

    function test_utilize_fullDepositing() public afterDeposited validateFinalState {
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilization, pendingIncreaseCollateral * targetLeverage / 1 ether);
        _utilize(pendingUtilization);
        uint256 totalAssets = strategy.totalAssets();
        assertApproxEqRel(totalAssets, TEN_THOUSANDS_USDC, 0.99 ether);
        assertEq(IERC20(asset).balanceOf(address(strategy)), 0);
        assertEq(IERC20(asset).balanceOf(address(positionManager)), 0);
        (pendingUtilization,) = strategy.pendingUtilizations();
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

    function test_withdraw_whenIdleEnough() public afterDeposited validateFinalState {
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

    function test_previewWithdrawRedeem_whenIdleNotEnough() public afterPartialUtilized validateFinalState {
        uint256 totalShares = strategy.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = strategy.previewRedeem(redeemShares);
        uint256 shares = strategy.previewWithdraw(assets);
        assertEq(shares, redeemShares);
    }

    function test_withdraw_whenIdleNotEnough() public afterPartialUtilized validateFinalState {
        uint256 totalShares = strategy.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = strategy.previewRedeem(redeemShares);
        vm.expectEmit();
        emit ManagedBasisStrategy.UpdatePendingUtilization();
        vm.startPrank(user1);
        strategy.redeem(redeemShares, user1, user1);
        bytes32 requestKey = strategy.getWithdrawId(user1, 0);
        DataTypes.WithdrawRequestState memory withdrawRequest = strategy.withdrawRequests(requestKey);
        assertFalse(strategy.isClaimable(requestKey));
        assertEq(withdrawRequest.requestedAmount, assets);
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

    function test_deutilize_partial_withSingleRequest() public afterWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization / 2);
        bytes32 requestKey = strategy.getWithdrawId(user1, 0);
        assertFalse(strategy.isClaimable(requestKey));
        vm.expectRevert(Errors.RequestNotExecuted.selector);
        vm.startPrank(user1);
        strategy.claim(requestKey);
    }

    function test_deutilize_full_withSingleRequest() public afterWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        bytes32 requestKey = strategy.getWithdrawId(user1, 0);
        assertTrue(strategy.isClaimable(requestKey));

        DataTypes.WithdrawRequestState memory withdrawRequest = strategy.withdrawRequests(requestKey);
        uint256 balanceBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(requestKey);
        uint256 balanceAfter = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore + withdrawRequest.requestedAmount, balanceAfter);
    }

    function test_deutilize_partial_withMultipleRequest()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization / 2);

        bytes32 requestKey1 = strategy.getWithdrawId(user1, 0);
        assertTrue(strategy.isClaimable(requestKey1));

        bytes32 requestKey2 = strategy.getWithdrawId(user2, 0);
        assertFalse(strategy.isClaimable(requestKey2));

        DataTypes.WithdrawRequestState memory withdrawRequest1 = strategy.withdrawRequests(requestKey1);
        uint256 balanceBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(requestKey1);
        uint256 balanceAfter = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore + withdrawRequest1.requestedAmount, balanceAfter);
    }

    function test_deutilize_full_withMultipleRequest() public afterMultipleWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);

        bytes32 requestKey1 = strategy.getWithdrawId(user1, 0);
        assertTrue(strategy.isClaimable(requestKey1));

        bytes32 requestKey2 = strategy.getWithdrawId(user2, 0);
        assertTrue(strategy.isClaimable(requestKey2));

        DataTypes.WithdrawRequestState memory withdrawRequest1 = strategy.withdrawRequests(requestKey1);
        uint256 balanceBefore1 = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(requestKey1);
        uint256 balanceAfter1 = IERC20(asset).balanceOf(user1);
        assertEq(balanceBefore1 + withdrawRequest1.requestedAmount, balanceAfter1);

        DataTypes.WithdrawRequestState memory withdrawRequest2 = strategy.withdrawRequests(requestKey2);
        uint256 balanceBefore2 = IERC20(asset).balanceOf(user2);
        vm.startPrank(user2);
        strategy.claim(requestKey2);
        uint256 balanceAfter2 = IERC20(asset).balanceOf(user2);
        assertEq(balanceBefore2 + withdrawRequest2.requestedAmount, balanceAfter2);
    }

    function test_deutilize_lastRedeemBelowRequestedAmount() public afterFullUtilized validateFinalState {
        // make last redeem
        uint256 userShares = IERC20(address(strategy)).balanceOf(address(user1));
        vm.startPrank(user1);
        strategy.redeem(userShares, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(pendingDeutilization);

        // decrease margin
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 105 / 100);

        _fullExcuteOrder();
        assertEq(uint256(strategy.strategyStatus()), uint256(DataTypes.StrategyStatus.IDLE));

        bytes32 requestKey = strategy.getWithdrawId(user1, 0);
        assertTrue(strategy.proccessedWithdrawAssets() < strategy.accRequestedWithdrawAssets());
        assertTrue(strategy.isClaimable(requestKey));

        uint256 requestedAmount = strategy.withdrawRequests(requestKey).requestedAmount;
        uint256 balBefore = IERC20(asset).balanceOf(user1);

        assertGt(strategy.accRequestedWithdrawAssets(), strategy.proccessedWithdrawAssets());

        vm.startPrank(user1);
        strategy.claim(requestKey);
        uint256 balDelta = IERC20(asset).balanceOf(user1) - balBefore;

        assertGt(requestedAmount, balDelta);
        assertEq(strategy.pendingDecreaseCollateral(), 0);
        assertEq(strategy.accRequestedWithdrawAssets(), strategy.proccessedWithdrawAssets());
    }

    function test_performUpkeep_rebalanceUp() public afterMultipleWithdrawRequestCreated validateFinalState {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 5 / 10);
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertTrue(rebalanceUpNeeded);
        assertFalse(rebalanceDownNeeded);
        assertFalse(deleverageNeeded);
        assertFalse(positionManagerNeedKeep);

        // position.sizeInUsd is changed due to realization of positive pnl
        // so need to execute performUpKeep several times

        _performKeep();
    }

    function test_performUpkeep_rebalanceDown_whenNoIdle()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);
        assertEq(strategy.idleAssets(), 0);
        (bool upkeepNeeded,) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        _performKeep();
        (, uint256 deutilization) = strategy.pendingUtilizations();
        _deutilize(deutilization);
    }

    function test_performUpkeep_rebalanceDown_whenIdle()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(strategy), 100 * 1e6);
        assertTrue(IERC20(asset).balanceOf(address(strategy)) > 0);

        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 12 / 10);

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        assertFalse(deleverageNeeded);
        assertFalse(positionManagerNeedKeep);

        _performKeep();

        assertEq(strategy.idleAssets(), 0);

        (upkeepNeeded,) = strategy.checkUpkeep("");
        assertFalse(upkeepNeeded);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
    }

    function test_performUpkeep_emergencyRebalanceDown_whenNotIdle()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 13 / 10);
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertTrue(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertTrue(deleverageNeeded, "deleverageNeeded");
        assertFalse(positionManagerNeedKeep, "positionManagerNeedKeep");

        _performKeep();
    }

    function test_performUpkeep_emergencyRebalanceDown_whenIdleNotEnough()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(strategy), 100 * 1e6);
        assertTrue(IERC20(asset).balanceOf(address(strategy)) > 0);
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 13 / 10);
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        assertTrue(deleverageNeeded);
        assertFalse(positionManagerNeedKeep);
        _performKeep();
        assertTrue(IERC20(asset).balanceOf(address(strategy)) > 0);
    }

    function test_performUpkeep_emergencyRebalanceDown_whenIdleEnough()
        public
        afterMultipleWithdrawRequestCreated
        validateFinalState
    {
        vm.startPrank(USDC_WHALE);
        IERC20(asset).transfer(address(strategy), TEN_THOUSANDS_USDC);
        uint256 strategyBalanceBefore = IERC20(asset).balanceOf(address(strategy));
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 13 / 10);
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertTrue(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertTrue(deleverageNeeded, "deleverageNeeded");
        assertFalse(positionManagerNeedKeep, "positionManagerNeedKeep");
        vm.startPrank(forwarder);
        strategy.performUpkeep(performData);
        _fullExcuteOrder();
        uint256 strategyBalanceAfter = IERC20(asset).balanceOf(address(strategy));
        assertTrue(strategyBalanceAfter < strategyBalanceBefore);
    }

    function test_performUpkeep_hedgeDeviation_down() public afterMultipleWithdrawRequestCreated validateFinalState {
        vm.startPrank(address(strategy));
        IERC20(product).transfer(address(this), IERC20(product).balanceOf(address(strategy)) / 10);

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded, "upkeepNeeded");
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertFalse(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertFalse(deleverageNeeded, "deleverageNeeded");
        assertFalse(positionManagerNeedKeep, "positionManagerNeedKeep");

        assertTrue(hedgeDeviationInTokens != 0, "hedge deviation");

        _performKeep();
    }

    function test_performUpkeep_hedgeDeviation_up() public afterMultipleWithdrawRequestCreated validateFinalState {
        vm.startPrank(address(WETH_WHALE));
        IERC20(product).transfer(address(strategy), IERC20(product).balanceOf(address(strategy)) / 10);

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertFalse(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertFalse(deleverageNeeded, "deleverageNeeded");
        assertFalse(positionManagerNeedKeep, "positionManagerNeedKeep");

        assertTrue(hedgeDeviationInTokens != 0, "hedge deviation");

        _performKeep();
    }

    function test_performUpkeep_decreaseCollateral_whenRebalanceUpNeeded() public validateFinalState {
        _deposit(user1, TEN_THOUSANDS_USDC);
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        _utilize(pendingUtilizationInAsset);
        uint256 redeemShares1 = strategy.balanceOf(user1);
        vm.startPrank(user1);
        strategy.redeem(redeemShares1, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        uint256 amount = pendingDeutilization * 9 / 10;
        vm.startPrank(operator);
        strategy.deutilize(amount, DataTypes.SwapType.MANUAL, "");

        _fullExcuteOrder();

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool positionManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded,
            uint256 deltaCollateralToDecrease
        ) = abi.decode(performData, (bool, bool, int256, bool, bool, bool, uint256));

        assertFalse(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertFalse(deleverageNeeded, "deleverageNeeded");
        assertFalse(positionManagerNeedKeep, "positionManagerNeedKeep");
        assertFalse(hedgeDeviationInTokens != 0, "hedge deviation");
        assertTrue(decreaseCollateral, "decreaseCollateral");
        assertTrue(rebalanceUpNeeded, "rebalanceUpNeeded");

        _performKeep();
    }

    /*//////////////////////////////////////////////////////////////
                        REVERT TEST
    //////////////////////////////////////////////////////////////*/

    function test_afterAdjustPosition_revert_whenUtilizing() public afterDeposited {
        (uint256 pendingUtilization,) = strategy.pendingUtilizations();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();

        uint256 amount = pendingUtilization / 2;
        // bytes memory data = _generateInchCallData(asset, product, amount, address(strategy));
        vm.startPrank(operator);
        strategy.utilize(amount, DataTypes.SwapType.MANUAL, "");

        // position manager increase reversion
        vm.startPrank(GMX_ORDER_VAULT);
        IERC20(asset).transfer(address(positionManager), pendingIncreaseCollateral / 2);
        vm.startPrank(address(positionManager));
        strategy.afterAdjustPosition(
            DataTypes.PositionManagerPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: true})
        );

        assertEq(IERC20(asset).balanceOf(address(positionManager)), 0);
        assertEq(IERC20(product).balanceOf(address(strategy)), 0);
        assertApproxEqRel(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC, 0.9999 ether);
    }

    function test_afterAdjustPosition_revert_whenDeutilizing() public afterWithdrawRequestCreated {
        uint256 productBefore = IERC20(product).balanceOf(address(strategy));
        uint256 assetsToWithdrawBefore = strategy.assetsToWithdraw();
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        // bytes memory data = _generateInchCallData(product, asset, pendingDeutilization, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(pendingDeutilization, DataTypes.SwapType.MANUAL, "");

        vm.startPrank(address(positionManager));
        strategy.afterAdjustPosition(
            DataTypes.PositionManagerPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: false})
        );

        bytes32 requestKey = strategy.getWithdrawId(user1, 0);
        assertFalse(strategy.isClaimable(requestKey));

        uint256 productAfter = IERC20(product).balanceOf(address(strategy));
        uint256 assetsToWithdrawAfter = strategy.assetsToWithdraw();

        assertEq(assetsToWithdrawAfter, assetsToWithdrawBefore);
        assertApproxEqRel(productAfter, productBefore, 0.9999 ether);
    }
}
