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

import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {Config} from "src/Config.sol";
import {ConfigKeys} from "src/libraries/ConfigKeys.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Keeper} from "src/Keeper.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {BasisStrategy} from "src/BasisStrategy.sol";
import {LogarithmVault} from "src/LogarithmVault.sol";

import {console2 as console} from "forge-std/console2.sol";

contract BasisStrategyGmxV2Test is InchTest, GmxV2Test {
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
        int256 totalPendingWithdraw;
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

    LogarithmVault vault;
    BasisStrategy strategy;
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

        uint256 nextNonce = uint256(vm.getNonce(owner) + 3);
        address preComputedStrategyAddress = vm.computeCreateAddress(owner, nextNonce);

        address vaultImpl = address(new LogarithmVault());
        address vaultProxy = address(
            new ERC1967Proxy(
                vaultImpl,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector,
                    preComputedStrategyAddress,
                    asset,
                    entryCost,
                    exitCost,
                    "tt",
                    "tt"
                )
            )
        );
        vault = LogarithmVault(vaultProxy);
        vm.label(address(vault), "vault");

        // deploy strategy
        address strategyImpl = address(new BasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
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
        strategy = BasisStrategy(strategyProxy);
        vm.label(address(strategy), "strategy");

        assertEq(address(strategy), preComputedStrategyAddress, "wrong precomputed strategy address");

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

    function _getStrategyState() internal view returns (StrategyState memory state) {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        int256 hedgeDeviationInTokens;
        bool positionManagerNeedKeep;
        if (performData.length > 0) {
            (rebalanceUpNeeded, rebalanceDownNeeded, deleverageNeeded, hedgeDeviationInTokens, positionManagerNeedKeep)
            = abi.decode(performData, (bool, bool, bool, int256, bool));
        }

        state.strategyStatus = uint8(strategy.strategyStatus());
        state.totalSupply = vault.totalSupply();
        state.totalAssets = vault.totalAssets();
        state.utilizedAssets = strategy.utilizedAssets();
        state.idleAssets = vault.idleAssets();
        state.assetBalance = IERC20(asset).balanceOf(address(vault));
        state.productBalance = IERC20(product).balanceOf(address(strategy));
        state.productValueInAsset = oracle.convertTokenAmount(product, asset, state.productBalance);
        state.assetsToWithdraw = IERC20(asset).balanceOf(address(strategy));
        state.assetsToClaim = vault.assetsToClaim();
        state.totalPendingWithdraw = vault.totalPendingWithdraw();
        state.pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        state.pendingDecreaseCollateral = strategy.pendingDecreaseCollateral();
        (state.pendingUtilization, state.pendingDeutilization) = strategy.pendingUtilizations();
        state.accRequestedWithdrawAssets = vault.accRequestedWithdrawAssets();
        state.proccessedWithdrawAssets = vault.proccessedWithdrawAssets();
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
            assertApproxEqRel(state.positionLeverage, 3 ether, 0.01 ether, "current leverage");
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
        uint256 redeemShares = vault.balanceOf(user1) * 2 / 3;
        vm.startPrank(user1);
        vault.redeem(redeemShares, user1, user1);
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
        vault.redeem(redeemShares1, user1, user1);

        uint256 redeemShares2 = vault.balanceOf(user2) / 4;
        vm.startPrank(user2);
        vault.redeem(redeemShares2, user2, user2);
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
        vault.deposit(assets, from);
        StrategyState memory state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
    }

    function _mint(address from, uint256 shares) private {
        vm.startPrank(from);
        uint256 assets = vault.previewMint(shares);
        IERC20(asset).approve(address(strategy), assets);
        StrategyState memory state0 = _getStrategyState();
        vault.mint(shares, from);
        StrategyState memory state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
    }

    function _utilize(uint256 amount) private {
        vm.startPrank(operator);
        StrategyState memory state0 = _getStrategyState();
        strategy.utilize(amount, BasisStrategy.SwapType.MANUAL, "");
        StrategyState memory state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.UTILIZING));

        state0 = state1;
        _fullExcuteOrder();
        state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));
        _performKeep();
    }

    function _deutilize(uint256 amount) private {
        StrategyState memory state0 = _getStrategyState();
        vm.startPrank(operator);
        strategy.deutilize(amount, BasisStrategy.SwapType.MANUAL, "");
        StrategyState memory state1 = _getStrategyState();
        // can't guarantee 1% deviation due to price impact of uniswap
        // _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.DEUTILIZING));

        state0 = state1;
        _fullExcuteOrder();
        state1 = _getStrategyState();
        _validateStateTransition(state0, state1);
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));

        _performKeep();
    }

    function _deutilizeWithoutExecution(uint256 amount) private {
        // bytes memory data = _generateInchCallData(product, asset, amount, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(amount, BasisStrategy.SwapType.MANUAL, "");
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.DEUTILIZING));
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
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC);
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
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC * 3 / 2);
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
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC);
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
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC / 2);
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
        int256 pendingWithdrawBefore = vault.totalPendingWithdraw();
        uint256 shares = vault.previewDeposit(THOUSAND_USDC);
        _deposit(user2, THOUSAND_USDC);
        assertEq(vault.balanceOf(user2), shares);
        int256 pendingWithdrawAfter = vault.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter + int256(THOUSAND_USDC), pendingWithdrawBefore);
        assertFalse(vault.isClaimable(vault.getWithdrawKey(0)));
    }

    function test_deposit_withPendingWithdraw_biggerThanTotalPendingWithdraw()
        public
        afterWithdrawRequestCreated
        validateFinalState
    {
        int256 pendingWithdrawBefore = vault.totalPendingWithdraw();
        uint256 shares = vault.previewDeposit(TEN_THOUSANDS_USDC);
        _deposit(user2, TEN_THOUSANDS_USDC);
        assertEq(vault.balanceOf(user2), shares);
        int256 pendingWithdrawAfter = vault.totalPendingWithdraw();
        assertEq(pendingWithdrawAfter, 0);
        assertTrue(vault.isClaimable(vault.getWithdrawKey(0)));
        assertTrue(pendingWithdrawBefore > 0);
        assertEq(vault.idleAssets(), TEN_THOUSANDS_USDC - uint256(pendingWithdrawBefore));
    }

    /*//////////////////////////////////////////////////////////////
                            UTILIZE TEST
    //////////////////////////////////////////////////////////////*/

    function test_utilize_partialDepositing() public afterDeposited validateFinalState {
        (uint256 pendingUtilizationInAsset,) = strategy.pendingUtilizations();
        uint256 pendingIncreaseCollateral = strategy.pendingIncreaseCollateral();
        assertEq(pendingUtilizationInAsset, pendingIncreaseCollateral * targetLeverage / 1 ether);
        _utilize(pendingUtilizationInAsset / 2);
        uint256 totalAssets = vault.totalAssets();
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
        uint256 totalAssets = vault.totalAssets();
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
        vault.withdraw(assets, user1, user1);
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

    function test_withdraw_whenIdleNotEnough() public afterPartialUtilized validateFinalState {
        uint256 totalShares = vault.balanceOf(user1);
        uint256 redeemShares = totalShares * 2 / 3;
        uint256 assets = vault.previewRedeem(redeemShares);
        vm.expectEmit();
        emit BasisStrategy.UpdatePendingUtilization();
        vm.startPrank(user1);
        vault.redeem(redeemShares, user1, user1);
        bytes32 requestKey = vault.getWithdrawKey(0);
        LogarithmVault.WithdrawRequest memory withdrawRequest = vault.withdrawRequests(requestKey);
        assertFalse(vault.isClaimable(requestKey));
        assertEq(withdrawRequest.requestedAssets, assets);
        assertEq(withdrawRequest.receiver, user1);
        assertEq(withdrawRequest.accRequestedWithdrawAssets, assets - TEN_THOUSANDS_USDC / 2);
        assertEq(vault.idleAssets(), 0);
        assertEq(vault.assetsToClaim(), TEN_THOUSANDS_USDC / 2);
        assertEq(vault.proccessedWithdrawAssets(), 0);
        assertEq(withdrawRequest.accRequestedWithdrawAssets, vault.accRequestedWithdrawAssets());
    }

    /*//////////////////////////////////////////////////////////////
                        DEUTILIZE/UPKEEP TEST
    //////////////////////////////////////////////////////////////*/

    function test_deutilize_partial_withSingleRequest() public afterWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization / 2);
        bytes32 requestKey = vault.getWithdrawKey(0);
        assertFalse(vault.isClaimable(requestKey));
        vm.expectRevert(Errors.RequestNotExecuted.selector);
        vm.startPrank(user1);
        vault.claim(requestKey);
    }

    function test_deutilize_full_withSingleRequest() public afterWithdrawRequestCreated validateFinalState {
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilize(pendingDeutilization);
        bytes32 requestKey = vault.getWithdrawKey(0);
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

        bytes32 requestKey1 = vault.getWithdrawKey(0);
        assertTrue(vault.isClaimable(requestKey1));

        bytes32 requestKey2 = vault.getWithdrawKey(1);
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

        bytes32 requestKey1 = vault.getWithdrawKey(0);
        assertTrue(vault.isClaimable(requestKey1));

        bytes32 requestKey2 = vault.getWithdrawKey(1);
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

    function test_deutilize_lastRedeemBelowrequestedAssets() public afterFullUtilized validateFinalState {
        // make last redeem
        uint256 userShares = IERC20(address(strategy)).balanceOf(address(user1));
        vm.startPrank(user1);
        vault.redeem(userShares, user1, user1);

        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        _deutilizeWithoutExecution(pendingDeutilization);

        // decrease margin
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 105 / 100);

        _fullExcuteOrder();
        assertEq(uint256(strategy.strategyStatus()), uint256(BasisStrategy.StrategyStatus.IDLE));

        bytes32 requestKey = vault.getWithdrawKey(0);
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

    function test_performUpkeep_rebalanceUp() public afterMultipleWithdrawRequestCreated validateFinalState {
        int256 priceBefore = IPriceFeed(productPriceFeed).latestAnswer();
        _mockChainlinkPriceFeedAnswer(productPriceFeed, priceBefore * 5 / 10);
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        assertTrue(upkeepNeeded);
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool liquidatable,, bool positionManagerNeedKeep) =
            abi.decode(performData, (bool, bool, bool, int256, bool));
        assertTrue(rebalanceUpNeeded);
        assertFalse(rebalanceDownNeeded);
        assertFalse(liquidatable);
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
        assertEq(vault.idleAssets(), 0);
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
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool liquidatable,, bool positionManagerNeedKeep) =
            abi.decode(performData, (bool, bool, bool, int256, bool));
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        assertFalse(liquidatable);
        assertFalse(positionManagerNeedKeep);

        _performKeep();

        assertEq(vault.idleAssets(), 0);

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
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool liquidatable,, bool positionManagerNeedKeep) =
            abi.decode(performData, (bool, bool, bool, int256, bool));
        assertFalse(rebalanceUpNeeded, "rebalanceUpNeeded");
        assertTrue(rebalanceDownNeeded, "rebalanceDownNeeded");
        assertTrue(liquidatable, "liquidatable");
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
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool liquidatable,, bool positionManagerNeedKeep) =
            abi.decode(performData, (bool, bool, bool, int256, bool));
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        assertTrue(liquidatable);
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
        assertTrue(upkeepNeeded);
        (bool rebalanceUpNeeded, bool rebalanceDownNeeded, bool liquidatable,, bool positionManagerNeedKeep) =
            abi.decode(performData, (bool, bool, bool, int256, bool));
        assertFalse(rebalanceUpNeeded);
        assertTrue(rebalanceDownNeeded);
        assertTrue(liquidatable);
        assertFalse(positionManagerNeedKeep);
        console.log("currentLeverage", positionManager.currentLeverage());
        vm.startPrank(forwarder);
        strategy.performUpkeep(performData);
        _fullExcuteOrder();
        uint256 strategyBalanceAfter = IERC20(asset).balanceOf(address(strategy));
        assertTrue(strategyBalanceAfter < strategyBalanceBefore);
        console.log("resultedLeverage", positionManager.currentLeverage());
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
        strategy.utilize(amount, BasisStrategy.SwapType.MANUAL, "");

        // position manager increase reversion
        vm.startPrank(GMX_ORDER_VAULT);
        IERC20(asset).transfer(address(positionManager), pendingIncreaseCollateral / 2);
        vm.startPrank(address(positionManager));
        strategy.afterAdjustPosition(
            IPositionManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: true})
        );

        assertEq(IERC20(asset).balanceOf(address(positionManager)), 0);
        assertEq(IERC20(product).balanceOf(address(strategy)), 0);
        assertApproxEqRel(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC, 0.9999 ether);
    }

    function test_afterAdjustPosition_revert_whenDeutilizing() public afterWithdrawRequestCreated {
        uint256 productBefore = IERC20(product).balanceOf(address(strategy));
        uint256 assetsToWithdrawBefore = IERC20(asset).balanceOf(address(strategy));
        (, uint256 pendingDeutilization) = strategy.pendingUtilizations();
        // bytes memory data = _generateInchCallData(product, asset, pendingDeutilization, address(strategy));
        vm.startPrank(operator);
        strategy.deutilize(pendingDeutilization, BasisStrategy.SwapType.MANUAL, "");

        vm.startPrank(address(positionManager));
        strategy.afterAdjustPosition(
            IPositionManager.AdjustPositionPayload({sizeDeltaInTokens: 0, collateralDeltaAmount: 0, isIncrease: false})
        );

        bytes32 requestKey = vault.getWithdrawKey(0);
        assertFalse(vault.isClaimable(requestKey));

        uint256 productAfter = IERC20(product).balanceOf(address(strategy));
        uint256 assetsToWithdrawAfter = IERC20(asset).balanceOf(address(strategy));

        assertEq(assetsToWithdrawAfter, assetsToWithdrawBefore);
        assertApproxEqRel(productAfter, productBefore, 0.9999 ether);
    }
}
