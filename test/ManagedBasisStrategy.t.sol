// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ArbGasInfoMock} from "./mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "./mock/ArbSysMock.sol";
import {ManagedBasisStrategy} from "src/ManagedBasisStrategy.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";

contract ManagedBasisStrategyTest is Test {
    using Math for uint256;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address operator = makeAddr("operator");
    address agent = makeAddr("agent");

    ManagedBasisStrategy strategy;
    LogarithmOracle oracle;
    OffChainPositionManager positionManager;

    uint256 constant FLOAT_PRECISION = 1e18;
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
    uint256 constant executionFee = 0.001 ether;

    function setUp() public {
        IERC20(asset).approve(agent, type(uint256).max);
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
                    targetLeverage,
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
        IERC20(asset).transfer(address(this), collateralAmount);
        positionNetBalance += collateralAmount;
    }

    function _decreasePositionCollateral(uint256 collateralAmount) internal {
        IERC20(asset).transferFrom(address(this), agent, collateralAmount);
        positionNetBalance -= collateralAmount;
    }

    function _getMarkPrice() internal view returns (uint256) {
        uint256 oraclePrice = oracle.getAssetPrice(product);
        uint256 precision =
            10 ** (60 - uint256(IERC20Metadata(product).decimals()) - uint256(IERC20Metadata(asset).decimals()));
        return oraclePrice.mulDiv(1e30, precision);
    }

    function _getExecutionParams(uint256 sizeDeltaInTokens)
        internal
        view
        returns (uint256 executionPrice, uint256 executionCost)
    {
        executionPrice = _getMarkPrice();
        uint256 sizeDeltaInAsset = oracle.convertTokenAmount(product, asset, sizeDeltaInTokens);
        executionCost = sizeDeltaInAsset.mulDiv(executionFee, FLOAT_PRECISION);
    }

    function _reportState(bytes32 requestId, uint256 sizeDeltaInTokens) internal {
        (uint256 executionPrice, uint256 executionCost) = _getExecutionParams(sizeDeltaInTokens);
        positionManager.reportStateAndExecuteRequest(
            positionSizeInTokens, positionNetBalance, _getMarkPrice(), requestId, executionPrice, executionCost, true
        );
    }

    function _logWithdrawState(bytes32 withdrawId) internal view {
        ManagedBasisStrategy.WithdrawState memory state = strategy.withdrawRequests(withdrawId);
        console.log("WITHDRAW STATE");
        console.logBytes32(withdrawId);
        console.log("Timestamp", state.requestTimestamp);
        console.log("Requested Amount", state.requestedAmount);
        console.log("Executed Amount From Spot", state.executedFromSpot);
        console.log("Executed From Idle", state.executedFromIdle);
        console.log("Executed From Hedge", state.executedFromHedge);
        console.log("Execution Cost", state.executionCost);
        console.log("Receiver", state.receiver);
        console.log("Is Executed", state.isExecuted);
        console.log("Is Claimed", state.isClaimed);
        console.log("");
    }

    function _logRequest(bytes32 requestId)
        internal
        view
        returns (OffChainPositionManager.RequestInfo memory request)
    {
        request = positionManager.requests(requestId);
        console.log("REQUEST STATE");
        console.logBytes32(requestId);
        console.log("Size Delta In Tokens", request.sizeDeltaInTokens);
        console.log("Spot Execution Price", request.spotExecutionPrice);
        console.log("Collateral Delta Amount", request.collateralDeltaAmount);
        console.log("Is Increase", request.isIncrease);
        console.log("");
    }

    function _logTotalAssets() internal view {
        console.log("LOG TOTAL ASSETS");

        console.log("Utilized Assets:");
        console.log("productBalance", IERC20(product).balanceOf(address(strategy)));
        console.log(
            "productValueInAsset",
            oracle.convertTokenAmount(product, asset, IERC20(product).balanceOf(address(strategy)))
        );
        console.log("positionNetBalance", positionManager.positionNetBalance());
        console.log("utilizedAssets", strategy.utilizedAssets());
        console.log("");
        console.log("Idle Assets:");
        console.log("assetBalance", IERC20(asset).balanceOf(address(strategy)));
        console.log("assetsToClaim", strategy.assetsToClaim());
        console.log("assetsToWithdraw", strategy.assetsToWithdraw());
        console.log("idleAssets", strategy.idleAssets());
        console.log("");
        console.log("totalPendingWithdraw", strategy.totalPendingWithdraw());
    }

    function _getStrategyState(string memory stateName) internal view {
        uint256 supply = strategy.totalSupply();
        uint256 totalAssets = strategy.totalAssets();
        uint256 sharePrice = supply == 0 ? 0 : totalAssets.mulDiv(1e18, supply);
        uint256 productValueInAsset =
            oracle.convertTokenAmount(product, asset, IERC20(product).balanceOf(address(strategy)));
        OffChainPositionManager.PositionState memory state = positionManager.currentPositionState();

        console.log("=========================");
        console.log(stateName);
        console.log("");
        console.log("====STATE_TRANSITIONS====");
        console.log("sharePrice", sharePrice);
        console.log("totalAssets", strategy.totalAssets());
        console.log("utilizedAssets", strategy.utilizedAssets());
        console.log("idleAssets", strategy.idleAssets());
        console.log("totalPendingWithdraw", strategy.totalPendingWithdraw());
        console.log("assetsToClaim", strategy.assetsToClaim());
        console.log("assetsToWithdraw", strategy.assetsToWithdraw());
        console.log("strategyAssetBalance", IERC20(asset).balanceOf(address(strategy)));
        console.log("productValueInAsset", productValueInAsset);
        console.log("positionManagerAssetBalance", IERC20(asset).balanceOf(address(positionManager)));
        console.log("positionNetBalance", positionManager.positionNetBalance());
        console.log("======GENERAL_STATE======");
        console.log("Pending Utilization", strategy.pendingUtilization());
        console.log("Pending Deutilization", strategy.pendingDeutilization());
        console.log("Pending Increase Collateral", strategy.pendingIncreaseCollateral());
        console.log("Pending Decrease Collateral", strategy.pendingDecreaseCollateral());
        console.log("Withdrawn From Spot", strategy.withdrawnFromSpot());
        console.log("Withdrawn From Idle", strategy.withdrawnFromIdle());
        console.log("Idle Imbalance", strategy.idleImbalance());
        console.log("Strategy Status", uint256(strategy.strategyStatus()));
        console.log("Active Request ID", vm.toString(strategy.activeRequestId()));
        console.log("PositionManager Active Request ID", vm.toString(positionManager.activeRequestId()));
        console.log("PositionManager Current Round", positionManager.currentRound());
        console.log("PositionManager Pending Collateral Increase", positionManager.pendingCollateralIncrease());
        console.log("=========GETTERS=========");
        console.log("strategyProductBalance", IERC20(product).balanceOf(address(strategy)));
        console.log("agentAssetBalance", IERC20(asset).balanceOf(agent));
        console.log("platformAssetBalance", IERC20(asset).balanceOf(address(this)));
        console.log("positionStateSizeInTokens", state.sizeInTokens);
        console.log("positionStateNetBalance", state.netBalance);
        console.log("positionStateMarkPrice", state.markPrice);
        console.log("=========================");
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

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, bytes32(0));

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, bytes32(0));

        vm.startPrank(operator);
        bytes32 requestId = strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _getStrategyState("AFTER UTILIZE");

        vm.startPrank(agent);
        positionManager.transferToAgent();
        uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        uint256 collateralDelta = IERC20(asset).balanceOf(agent);
        _getStrategyState("AFTER TRANSFER TO AGENT");

        _increasePositionSize(sizeDeltaInTokens);
        _increasePositionCollateral(collateralDelta);

        _reportState(requestId, sizeDeltaInTokens);

        _getStrategyState("AFTER EXECUTE");
    }

    function test_partialUtilize() public {
        vm.startPrank(user);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user);
        _getStrategyState("INITIAL STATE");
        uint256 utilizationAmount = strategy.pendingUtilization() / 2;
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, bytes32(0));

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, bytes32(0));

        vm.startPrank(operator);
        bytes32 requestId = strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _getStrategyState("AFTER UTILIZE");

        vm.startPrank(agent);
        positionManager.transferToAgent();
        uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        uint256 collateralDelta = IERC20(asset).balanceOf(agent);
        _getStrategyState("AFTER TRANSFER TO AGENT");

        _increasePositionSize(sizeDeltaInTokens);
        _increasePositionCollateral(collateralDelta);

        _reportState(requestId, sizeDeltaInTokens);

        _getStrategyState("AFTER EXECUTE");
    }

    function test_simpleRedeemFullDeutilize() public {
        vm.startPrank(user);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, bytes32(0));

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, bytes32(0));

        vm.startPrank(operator);
        bytes32 requestId = strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();
        uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        _increasePositionSize(sizeDeltaInTokens);
        _increasePositionCollateral(collateralDelta);

        _reportState(requestId, sizeDeltaInTokens);
        _getStrategyState("STATE BEFORE REDEEM");

        uint256 sharesToRedeem = IERC20(address(strategy)).balanceOf(user) / 3;
        vm.startPrank(user);
        strategy.redeem(sharesToRedeem, user, user);
        _getStrategyState("STATE AFTER REDEEM");

        bytes32 withdrawId = strategy.getWithdrawId(user, 0);
        _logWithdrawState(withdrawId);

        uint256 pendingDeutilization = strategy.pendingDeutilization();
        data = _generateInchCallData(product, asset, pendingDeutilization);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestDecreasePositionSize(0, bytes32(0));

        vm.startPrank(operator);
        requestId = strategy.deutilize(pendingDeutilization, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _getStrategyState("STATE AFTER DEUTILIZE");

        OffChainPositionManager.RequestInfo memory request = _logRequest(requestId);
        sizeDeltaInTokens = request.sizeDeltaInTokens;

        vm.startPrank(agent);
        _decreasePositionSize(sizeDeltaInTokens);
        _reportState(requestId, sizeDeltaInTokens);
        _logTotalAssets();
        _getStrategyState("STATE AFTER EXECUTE");
        _logWithdrawState(withdrawId);
    }

    function test_fullRedeem() public {
        vm.startPrank(user);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, bytes32(0));

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, bytes32(0));

        vm.startPrank(operator);
        bytes32 requestId = strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();
        uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        _increasePositionSize(sizeDeltaInTokens);
        _increasePositionCollateral(collateralDelta);

        _reportState(requestId, sizeDeltaInTokens);
        _getStrategyState("STATE BEFORE REDEEM");

        uint256 sharesToRedeem = IERC20(address(strategy)).balanceOf(user);
        vm.startPrank(user);
        strategy.redeem(sharesToRedeem, user, user);
        _getStrategyState("STATE AFTER REDEEM");

        bytes32 withdrawId = strategy.getWithdrawId(user, 0);
        _logWithdrawState(withdrawId);

        uint256 pendingDeutilization = strategy.pendingDeutilization();
        data = _generateInchCallData(product, asset, pendingDeutilization);

        vm.startPrank(operator);
        requestId = strategy.deutilize(pendingDeutilization, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _getStrategyState("STATE AFTER DEUTILIZE");
    }
}
