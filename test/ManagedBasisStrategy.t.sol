// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ArbGasInfoMock} from "./mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "./mock/ArbSysMock.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";

contract ManagedBasisStrategyTest is Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address operator = makeAddr("operator");
    address agent = makeAddr("agent");

    ManagedBasisStrategy strategy;
    LogarithmOracle oracle;
    OffChainPositionManager positionManager;

    address constant asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
    address constant product = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
    address constant assetPriceFeed = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3; // Chainlink USDC-USD price feed
    address constant productPriceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Chainlink ETH-USD price feed
    uint256 constant entryCost = 0; // 0%
    uint256 constant targetLeverage = 3 ether; // 3x

    address constant usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    uint256 constant depositAmount = 10_000 * 1e6;

    // inch swap data variables
    string constant slippage = "1";
    string constant pathLocation = "router/path.json";
    string constant inchPyLocation = "router/inch.py";
    string constant inchJsonLocation = "router/inch.json";

    // off chain exchange state variables
    uint256 public positionNetBalance;
    uint256 public positionSizeInTokens;
    uint256 public positionMarkPrice;

    function setUp() public {
        vm.label(asset, "asset");
        vm.label(product, "product");
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
        address strategyImpl = address(new ManagedBasisStrategy());
        address strategyProxy = address(
            new ERC1967Proxy(
                strategyImpl,
                abi.encodeWithSelector(
                    ManagedBasisStrategy.initialize.selector,
                    asset,
                    product,
                    oracle,
                    operator,
                    targetLeverage,
                    entryCost
                )
            )
        );
        strategy = ManagedBasisStrategy(strategyProxy);
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

        // make approve by agent
        vm.startPrank(agent);
        IERC20(asset).approve(address(positionManager), type(uint256).max);

        // set position manager
        vm.startPrank(owner);
        strategy.setPositionManager(address(positionManager));

        // top up user
        vm.startPrank(usdcWhale);
        IERC20(asset).transfer(user, 10_000_000 * 1e6);
    }

    function _forkArbitrum() internal {
        uint256 arbitrumFork = vm.createFork(vm.rpcUrl("arbitrum_one"));
        vm.selectFork(arbitrumFork);
        vm.rollFork(213168025);

        // L2 contracts explicitly reference 0x64 for the ArbSys precompile
        // and 0x6C for the ArbGasInfo precompile
        // We'll replace it with the mock
        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);
    }

    function _mockChainlinkPriceFeed(address priceFeed) internal {
        (uint80 roundID, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IPriceFeed(priceFeed).latestRoundData();
        uint8 decimals = IPriceFeed(priceFeed).decimals();
        address mockPriceFeed = address(new MockPriceFeed());
        vm.etch(priceFeed, mockPriceFeed.code);
        MockPriceFeed(priceFeed).setOracleData(roundID, answer, startedAt, updatedAt, answeredInRound, decimals);
    }

    function _generateInchCallData(address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (bytes memory data)
    {
        string memory pathObj = "path_obj";
        vm.serializeAddress(pathObj, "src", tokenIn);
        vm.serializeAddress(pathObj, "dst", tokenOut);
        vm.serializeUint(pathObj, "amount", amount);
        vm.serializeAddress(pathObj, "from", address(strategy));
        string memory finalPathJson = vm.serializeString(pathObj, "slippage", slippage);
        vm.writeJson(finalPathJson, pathLocation);

        // get inch calldata
        string[] memory inputs = new string[](4);
        inputs[0] = "python3";
        inputs[1] = inchPyLocation;
        inputs[2] = "--json_data_file";
        inputs[3] = pathLocation;

        data = vm.ffi(inputs);
    }

    function _increasePositionSize(uint256 sizeDeltaInTokens) internal {
        positionSizeInTokens += sizeDeltaInTokens;
    }

    function _decreasePositionSize(uint256 sizeDeltaInTokens) internal {
        positionSizeInTokens -= sizeDeltaInTokens;
    }

    function _increasePositionCollateral(uint256 collateralAmount) internal {
        positionNetBalance += collateralAmount;
    }

    function _decreasePositionCollateral(uint256 collateralAmount) internal {
        positionNetBalance -= collateralAmount;
    }

    function _getStrategyState(string memory stateName) internal view {
        console.log("===================");
        console.log(stateName);
        console.log("=======STATE=======");
        console.log("Current Round", strategy.currentRound());
        console.log("Assets To Claim", strategy.assetsToClaim());
        console.log("Assets To Withdraw", strategy.assetsToWithdraw());
        console.log("Pending Utilization", strategy.pendingUtilization());
        console.log("Pending Deutilization", strategy.pendingDeutilization());
        console.log("Pending Increase Collateral", strategy.pendingIncreaseCollateral());
        console.log("Pending Decrease Collateral", strategy.pendingDecreaseCollateral());
        console.log("Total Pending Withdraw", strategy.totalPendingWithdraw());
        console.log("Withdrawn From Spot", strategy.withdrawnFromSpot());
        console.log("Withdrawn From Idle", strategy.withdrawnFromIdle());
        console.log("Idle Imbalance", strategy.idleImbalance());
        console.log("Strategy Status", uint256(strategy.strategyStatus()));
        console.log("Active Request ID", vm.toString(strategy.activeRequestId()));
        console.log("PositionManager Active Request ID", vm.toString(positionManager.activeRequestId()));
        console.log("PositionManager Current Round", positionManager.currentRound());
        console.log("PositionManager Pending Collateral Increase", positionManager.pendingCollateralIncrease());
        console.log("======GETTERS======");
        console.log("totalAssets", strategy.totalAssets());
        console.log("utilizedAssets", strategy.utilizedAssets());
        console.log("idleAssets", strategy.idleAssets());
        console.log("strategyAssetBalance", IERC20(asset).balanceOf(address(strategy)));
        console.log("strategyProductBalance", IERC20(product).balanceOf(address(strategy)));
        console.log("positionManagerAssetBalance", IERC20(asset).balanceOf(address(positionManager)));
        console.log("positionNetBalance", positionManager.positionNetBalance());
        OffChainPositionManager.PositionState memory state = positionManager.currentPositionState();
        console.log("positionStateSizeInTokens", state.sizeInTokens);
        console.log("positionStateNetBalance", state.netBalance);
        console.log("positionStateMarkPrice", state.markPrice);
        console.log("===================");
        console.log("");
    }

    function test_previewDeposit() public view {
        uint256 shares = strategy.previewDeposit(depositAmount);
        console.log("Shares", shares);
    }

    function test_firstDeposit() public {
        _getStrategyState("BEFORE DEPOSIT");
        vm.startPrank(user);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user);
        _getStrategyState("AFTER DEPOSIT");
    }

    function test_firstFullUtilize() public {
        vm.startPrank(user);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user);
        _getStrategyState("AFTER DEPOSIT");

        uint256 pendingUtilization = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, pendingUtilization);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, bytes32(0));

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, bytes32(0));

        vm.startPrank(operator);
        strategy.utilize(pendingUtilization, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _getStrategyState("AFTER UTILIZE");
    }
}
