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
import {Errors} from "src/libraries/Errors.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";

import {console} from "forge-std/console.sol";

contract AccumulatedBasisStrategyTest is InchTest, GmxV2Test {
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address operator = makeAddr("operator");

    uint256 constant USD_PRECISION = 1e30;

    uint256 public TEN_THOUSANDS_USDC = 10_000 * 1e6;

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
    Keeper keeper;
    uint256 increaseFee;
    uint256 decreaseFee;

    function setUp() public {
        _forkArbitrum();
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

    function _deposit(address from, uint256 assets) private {
        vm.startPrank(from);
        IERC20(asset).approve(address(strategy), assets);
        strategy.deposit(assets, from);
    }

    function _mint(address from, uint256 shares) private {
        uint256 assets = strategy.previewMint(shares);
        IERC20(asset).approve(address(strategy), assets);
        strategy.mint(shares, from);
    }

    function _utilize(uint256 amount) private {
        bytes memory data = _generateInchCallData(asset, product, amount, address(strategy));
        vm.startPrank(operator);
        strategy.utilize(amount, AccumulatedBasisStrategy.SwapType.INCH_V6, data);
        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.DEPOSITING));
        _executeOrder(positionManager.pendingIncreaseOrderKey());
        assertEq(uint256(strategy.strategyStatus()), uint256(AccumulatedBasisStrategy.StrategyStatus.IDLE));
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/MINT TEST
    //////////////////////////////////////////////////////////////*/

    function test_previewDepositMint_first() public {
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

    function test_mint_whenPartialUtilized() public afterPartialUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(strategy.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC * 3 / 2);
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

    function test_mint_whenFullUtilized() public afterFullUtilized {
        uint256 shares = strategy.previewDeposit(TEN_THOUSANDS_USDC / 2);
        _mint(user2, shares);
        assertEq(strategy.balanceOf(user2), shares);
        assertEq(IERC20(asset).balanceOf(address(strategy)), TEN_THOUSANDS_USDC * 3 / 2);
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
}
