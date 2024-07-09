// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "src/interfaces/IManagedBasisStrategy.sol";
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

    struct ExecutionParams {
        uint256 executionPrice;
        uint256 executionCost;
    }

    struct UpkeepParams {
        bool statusKeep;
        bool hedgeDeviation;
        bool decreaseCollateral;
        bool activeRequests;
        bool closedRequests;
    }

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
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
    uint256 constant exitCost = 0; // 0%
    uint256 constant targetLeverage = 3 ether; // 3x

    address constant usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address constant wethWhale = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    uint256 public depositAmount = 10_000 * 1e6;

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
                    entryCost,
                    exitCost
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

        // top up user1
        vm.startPrank(usdcWhale);
        IERC20(asset).transfer(user1, 10_000_000 * 1e6);
        IERC20(asset).transfer(user2, 10_000_000 * 1e6);
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
        vm.sleep(1_000);
    }

    function _executeRequest(OffChainPositionManager.RequestInfo memory request)
        internal
        returns (OffChainPositionManager.RequestInfo memory response)
    {
        if (request.isIncrease) {
            response.isIncrease = true;
            if (request.collateralDeltaAmount > 0) {
                response.collateralDeltaAmount = _increasePositionCollateral(request.collateralDeltaAmount);
            }
            if (request.sizeDeltaInTokens > 0) {
                response.sizeDeltaInTokens = _increasePositionSize(request.sizeDeltaInTokens);
            }
        } else {
            response.isIncrease = false;
            if (request.collateralDeltaAmount > 0) {
                response.collateralDeltaAmount = _decreasePositionCollateral(request.collateralDeltaAmount);
            }
            if (request.sizeDeltaInTokens > 0) {
                response.sizeDeltaInTokens = _decreasePositionSize(request.sizeDeltaInTokens);
            }
        }
    }

    function _increasePositionSize(uint256 sizeDeltaInTokens) internal returns (uint256) {
        positionSizeInTokens += sizeDeltaInTokens;
        return sizeDeltaInTokens;
    }

    function _decreasePositionSize(uint256 sizeDeltaInTokens) internal returns (uint256) {
        positionSizeInTokens -= sizeDeltaInTokens;
        return sizeDeltaInTokens;
    }

    function _increasePositionCollateral(uint256 collateralAmount) internal returns (uint256) {
        IERC20(asset).transfer(address(this), collateralAmount);
        positionNetBalance += collateralAmount;
        return collateralAmount;
    }

    function _decreasePositionCollateral(uint256 collateralAmount) internal returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 transferAmount = collateralAmount > balance ? balance : collateralAmount;
        IERC20(asset).transferFrom(address(this), agent, transferAmount);
        positionNetBalance -= transferAmount;
        return transferAmount;
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
        if (sizeDeltaInTokens == 0) {
            return (0, 0);
        } else {
            executionPrice = _getMarkPrice();
            uint256 sizeDeltaInAsset = oracle.convertTokenAmount(product, asset, sizeDeltaInTokens);
            executionCost = sizeDeltaInAsset.mulDiv(executionFee, FLOAT_PRECISION);
        }
    }

    function _reportState(
        OffChainPositionManager.RequestInfo memory request,
        OffChainPositionManager.RequestInfo memory response
    ) internal {
        (uint256 executionPrice, uint256 executionCost) = _getExecutionParams(request.sizeDeltaInTokens);
        if (response.collateralDeltaAmount < request.collateralDeltaAmount) {
            executionCost += request.collateralDeltaAmount - response.collateralDeltaAmount;
        }
        uint256 markPrice = _getMarkPrice();
        PositionManagerCallbackParams memory params = PositionManagerCallbackParams({
            sizeDeltaInTokens: response.sizeDeltaInTokens,
            collateralDeltaAmount: response.collateralDeltaAmount,
            executionPrice: executionPrice,
            executionCost: executionCost,
            isIncrease: response.isIncrease,
            isSuccess: true
        });
        positionManager.reportStateAndExecuteRequest(positionSizeInTokens, positionNetBalance, markPrice, params);
    }

    function _logWithdrawState(bytes32 withdrawId)
        internal
        view
        returns (ManagedBasisStrategy.WithdrawState memory state)
    {
        state = strategy.withdrawRequests(withdrawId);
        console.log("WITHDRAW STATE");
        console.logBytes32(withdrawId);
        console.log("Timestamp:", state.requestTimestamp);
        console.log("Requested Amount:", state.requestedAmount);
        console.log("Executed Amount From Spot:", state.executedFromSpot);
        console.log("Executed From Idle:", state.executedFromIdle);
        console.log("Executed From Hedge:", state.executedFromHedge);
        console.log("Execution Cost:", state.executionCost);
        console.log("Receiver:", state.receiver);
        console.log("Is Executed:", state.isExecuted);
        console.log("Is Claimed:", state.isClaimed);
        console.log(
            "Ready To Execute:",
            state.requestedAmount
                == state.executedFromSpot + state.executedFromIdle + state.executedFromHedge + state.executionCost
        );
        console.log(
            "Pending Withdraw:",
            state.requestedAmount
                - (state.executedFromSpot + state.executedFromIdle + state.executedFromHedge + state.executionCost)
        );
        console.log("");
    }

    function _logRequest() internal view returns (OffChainPositionManager.RequestInfo memory request) {
        uint256 round = positionManager.currentRound();
        request = positionManager.requests(round);
        console.log("REQUEST STATE");
        console.log("Round", round);
        console.log("Size Delta In Tokens", request.sizeDeltaInTokens);
        console.log("Collateral Delta Amount", request.collateralDeltaAmount);
        console.log("Is Increase", request.isIncrease);
        console.log("");
    }

    function _logUpkeep(bool upkeepNeeded, bytes memory performData)
        internal
        view
        returns (UpkeepParams memory params)
    {
        console.log("UPKEEP STATUS");
        console.log("Upkeep Needed:", upkeepNeeded);
        (
            params.statusKeep,
            params.hedgeDeviation,
            params.decreaseCollateral,
            params.activeRequests,
            params.closedRequests
        ) = abi.decode(performData, (bool, bool, bool, bool, bool));
        console.log("Status Keep:", params.statusKeep);
        console.log("Hedge Deviation:", params.hedgeDeviation);
        console.log("Decrease Collateral:", params.decreaseCollateral);
        console.log("Active Requests:", params.activeRequests);
        console.log("Closed Requests:", params.closedRequests);
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
        console.log("Withdrawing Assets:");
        console.log("totalPendingWithdraw", strategy.totalPendingWithdraw());
        console.log("withdrawingFromHedge", strategy.withdrawingFromHedge());
        console.log("");
    }

    function _logStateTransitions(string memory stateName) internal view {
        uint256 supply = strategy.totalSupply();
        uint256 totalAssets = strategy.totalAssets();
        uint256 sharePrice = supply == 0 ? 0 : totalAssets.mulDiv(1e18, supply);
        uint256 productValueInAsset =
            oracle.convertTokenAmount(product, asset, IERC20(product).balanceOf(address(strategy)));

        console.log("=========================");
        console.log(stateName);
        console.log("");
        console.log("sharePrice", sharePrice);
        console.log("totalAssets", strategy.totalAssets());
        console.log("utilizedAssets", strategy.utilizedAssets());
        console.log("idleAssets", strategy.idleAssets());
        console.log("pendingIncreaseCollateral", strategy.pendingIncreaseCollateral());
        console.log("totalPendingWithdraw", strategy.totalPendingWithdraw());
        console.log("pendingDeutilization", strategy.pendingDeutilization());
        console.log("withdrawingFromHedge", strategy.withdrawingFromHedge());
        console.log("assetsToClaim", strategy.assetsToClaim());
        console.log("assetsToWithdraw", strategy.assetsToWithdraw());
        console.log("withdrawnFromSpot", strategy.withdrawnFromSpot());
        console.log("withdrawnFromIdle", strategy.withdrawnFromIdle());
        console.log("strategyAssetBalance", IERC20(asset).balanceOf(address(strategy)));
        console.log("productValueInAsset", productValueInAsset);
        console.log("positionManagerAssetBalance", IERC20(asset).balanceOf(address(positionManager)));
        console.log("agentBalance", IERC20(asset).balanceOf(agent));
        console.log("positionNetBalance", positionManager.positionNetBalance());
        console.log("strategyProductBalance", IERC20(product).balanceOf(address(strategy)));
        console.log("positionManagerSizeInTokens", positionManager.positionSizeInTokens());
        console.log("=========================");
        console.log("");
    }

    function _logStrategyState(string memory stateName) internal view {
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
        console.log("withdrawingFromHedge", strategy.withdrawingFromHedge());
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
        console.log("Strategy Status", uint256(strategy.strategyStatus()));
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
        _logStrategyState("BEFORE DEPOSIT");
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);
        _logStrategyState("AFTER DEPOSIT");
    }

    function test_firstFullUtilize() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);
        _logStateTransitions("AFTER DEPOSIT");

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _logStateTransitions("AFTER UTILIZE");

        vm.startPrank(agent);
        positionManager.transferToAgent();
        _logStateTransitions("AFTER TRANSFER TO AGENT");

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        // uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        // uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("AFTER EXECUTE");
    }

    function test_partialUtilize() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);
        _logStateTransitions("INITIAL STATE");
        uint256 utilizationAmount = strategy.pendingUtilization() / 2;
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _logStateTransitions("AFTER UTILIZE 1");

        vm.startPrank(agent);
        positionManager.transferToAgent();
        _logStateTransitions("AFTER TRANSFER TO AGENT 1");

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("AFTER EXECUTE 1");
        assertEq(
            uint256(strategy.strategyStatus()),
            uint256(ManagedBasisStrategy.StrategyStatus.IDLE),
            "status should be idle"
        );

        utilizationAmount = strategy.pendingUtilization();
        data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _logStateTransitions("AFTER UTILIZE 2");

        vm.startPrank(agent);
        positionManager.transferToAgent();
        _logStateTransitions("AFTER TRANSFER TO AGENT 2");

        request = _logRequest();
        response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("AFTER EXECUTE 2");
    }

    function test_simpleRedeemPartialDeutilize() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);

        positionManager.transferToAgent();
        // uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        // uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("STATE BEFORE REDEEM");

        uint256 sharesToRedeem = IERC20(address(strategy)).balanceOf(user1) / 3;
        vm.startPrank(user1);
        strategy.redeem(sharesToRedeem, user1, user1);
        _logStateTransitions("STATE AFTER REDEEM");

        bytes32 withdrawId = strategy.getWithdrawId(user1, 0);
        _logWithdrawState(withdrawId);

        // first we deutilize half of pendingDeutilization
        uint256 deutilizationAmount = strategy.pendingDeutilization() / 2;
        data = _generateInchCallData(product, asset, deutilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestDecreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.deutilize(deutilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _logStateTransitions("STATE AFTER DEUTILIZE 1");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);
        _logStateTransitions("STATE AFTER EXECUTE DECREASE SIZE 1");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT DECREASE SIZE 1");

        _logWithdrawState(withdrawId);

        // then we deutilize remaining pendingDeutilization
        deutilizationAmount = strategy.pendingDeutilization();
        data = _generateInchCallData(product, asset, deutilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestDecreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.deutilize(deutilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _logStateTransitions("STATE AFTER DEUTILIZE 2");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);
        _logStateTransitions("STATE AFTER EXECUTE DECREASE SIZE 2");

        _logWithdrawState(withdrawId);

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT DECREASE SIZE 2");

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);
        assertEq(upkeepNeeded, true, "upkeep should be needed");

        if (upkeepParams.decreaseCollateral) {
            strategy.performUpkeep("");
            request = _logRequest();

            uint256 collateralAmount = request.collateralDeltaAmount;
            assertEq(IERC20(asset).balanceOf(agent), 0);
            response = _executeRequest(request);
            assertEq(IERC20(asset).balanceOf(agent), collateralAmount);

            _logStateTransitions("STATE AFTER EXECUTE DECREASE COLLATERAL");

            _reportState(request, response);
            _logStateTransitions("STATE AFTER REPORT DECREASE COLLATERAL");

            ManagedBasisStrategy.WithdrawState memory state = _logWithdrawState(withdrawId);

            uint256 user1BalBefore = IERC20(asset).balanceOf(user1);
            vm.startPrank(user1);
            strategy.claim(withdrawId);
            uint256 user1BalAfter = IERC20(asset).balanceOf(user1);

            assertEq(user1BalAfter - user1BalBefore, state.requestedAmount - state.executionCost);

            _logStateTransitions("STATE AFTER CLAIM");
        }
    }

    function test_fullRedeem() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();
        // uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        // uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);

        _reportState(request, response);
        _logStrategyState("STATE BEFORE REDEEM");

        uint256 sharesToRedeem = IERC20(address(strategy)).balanceOf(user1);
        vm.startPrank(user1);
        strategy.redeem(sharesToRedeem, user1, user1);
        _logStrategyState("STATE AFTER REDEEM");

        // bytes32 withdrawId = strategy.getWithdrawId(user1, 0);
        // _logWithdrawState(withdrawId);

        uint256 pendingDeutilization = strategy.pendingDeutilization();
        data = _generateInchCallData(product, asset, pendingDeutilization);

        vm.startPrank(operator);
        strategy.deutilize(pendingDeutilization, ManagedBasisStrategy.SwapType.INCH_V6, data);
        _logTotalAssets();
        _logStrategyState("STATE AFTER DEUTILIZE");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);

        _logStrategyState("STATE AFTER EXECUTE DECREASE SIZE");

        _reportState(request, response);
        _logStrategyState("STATE AFTER REPORT DECREASE SIZE");

        bytes32 withdrawId = strategy.getWithdrawId(user1, 0);
        _logWithdrawState(withdrawId);

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);
        assertEq(upkeepNeeded, true, "upkeep should be needed");

        if (upkeepParams.decreaseCollateral) {
            strategy.performUpkeep("");
            request = _logRequest();
            assertEq(IERC20(asset).balanceOf(agent), 0);
            response = _executeRequest(request);
            uint256 collateralAmount = response.collateralDeltaAmount;
            assertEq(IERC20(asset).balanceOf(agent), collateralAmount);

            _logStateTransitions("STATE AFTER EXECUTE DECREASE COLLATERAL");

            _reportState(request, response);
            _logStateTransitions("STATE AFTER REPORT DECREASE COLLATERAL");

            ManagedBasisStrategy.WithdrawState memory state = _logWithdrawState(withdrawId);

            uint256 user1BalBefore = IERC20(asset).balanceOf(user1);
            vm.startPrank(user1);
            strategy.claim(withdrawId);
            uint256 user1BalAfter = IERC20(asset).balanceOf(user1);

            assertEq(user1BalAfter - user1BalBefore, state.requestedAmount - state.executionCost);

            _logStateTransitions("STATE AFTER CLAIM");
        }
    }

    function test_depositWithPendingWithdrawOvershoot() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);

        _reportState(request, response);
        uint256 sharesToRedeem = IERC20(address(strategy)).balanceOf(user1) / 2;
        vm.startPrank(user1);
        strategy.redeem(sharesToRedeem, user1, user1);

        _logStateTransitions("STATE AFTER REDEEM");

        depositAmount *= 2;
        vm.startPrank(user2);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user2);

        _logStateTransitions("STATE AFTER DEPOSIT");
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);

        assertEq(upkeepParams.activeRequests, true, "active requests should be true");

        strategy.performUpkeep("");

        _logStateTransitions("STATE AFTER UPKEEP");

        bytes32 withdrawId = strategy.getWithdrawId(user1, 0);
        ManagedBasisStrategy.WithdrawState memory withdrawState = _logWithdrawState(withdrawId);
        assertEq(withdrawState.isExecuted, true, "withdraw should be executed");

        uint256 user1BalBefore = IERC20(asset).balanceOf(user1);
        vm.startPrank(user1);
        strategy.claim(withdrawId);
        uint256 user1BalDelta = IERC20(asset).balanceOf(user1) - user1BalBefore;

        assertEq(
            user1BalDelta, withdrawState.requestedAmount - withdrawState.executionCost, "user1 should receive funds"
        );
    }

    function test_multipleWithdraws() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        vm.startPrank(user2);
        IERC20(asset).approve(address(strategy), depositAmount * 2);
        strategy.deposit(depositAmount * 2, user2);

        _logStateTransitions("STATE AFTER DEPOSITS");

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        _logStateTransitions("STATE AFTER UTILIZATION");

        vm.startPrank(agent);
        positionManager.transferToAgent();

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE INCREASE SIZE");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT INCREASE SIZE");

        vm.startPrank(user1);
        uint256 sharesToRedeem = IERC20(address(strategy)).balanceOf(user1) / 2;
        strategy.redeem(sharesToRedeem, user1, user1);

        vm.startPrank(user2);
        sharesToRedeem = IERC20(address(strategy)).balanceOf(user2) / 2;
        strategy.redeem(sharesToRedeem, user2, user2);

        _logStateTransitions("STATE AFTER REDEEMS");

        vm.startPrank(operator);
        uint256 pendingDeutilization = strategy.pendingDeutilization() / 2;

        data = _generateInchCallData(product, asset, pendingDeutilization);
        strategy.deutilize(pendingDeutilization, ManagedBasisStrategy.SwapType.INCH_V6, data);

        _logStateTransitions("STATE AFTER REPORT DEUTILIZE 1");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE DECREASE SIZE 1");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT DECREASE SIZE 1");

        bytes32 withdrawId1 = strategy.getWithdrawId(user1, 0);
        bytes32 withdrawId2 = strategy.getWithdrawId(user2, 0);

        _logWithdrawState(withdrawId1);
        _logWithdrawState(withdrawId2);

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);
        assertEq(upkeepParams.closedRequests, true, "active requests should be true");

        strategy.performUpkeep("");

        _logStateTransitions("STATE AFTER UPKEEP 1");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE DECREASE COLLATERAL 1");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT DECREASE COLLATERAL 1");

        ManagedBasisStrategy.WithdrawState memory withdrawState1 = _logWithdrawState(withdrawId1);
        _logWithdrawState(withdrawId2);

        vm.startPrank(user1);
        uint256 user1BalBefore = IERC20(asset).balanceOf(user1);
        strategy.claim(withdrawId1);
        uint256 user1BalDelta = IERC20(asset).balanceOf(user1) - user1BalBefore;

        assertEq(
            user1BalDelta, withdrawState1.requestedAmount - withdrawState1.executionCost, "user1 should receive funds"
        );

        _logStateTransitions("STATE AFTER CLAIM 1");

        vm.startPrank(operator);
        pendingDeutilization = strategy.pendingDeutilization();
        data = _generateInchCallData(product, asset, pendingDeutilization);
        strategy.deutilize(pendingDeutilization, ManagedBasisStrategy.SwapType.INCH_V6, data);

        _logStateTransitions("STATE AFTER DEUTILIZE 2");

        request = _logRequest();
        response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE DECREASE SIZE 2");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT DECREASE SIZE 2");

        _logWithdrawState(withdrawId2);

        (upkeepNeeded, performData) = strategy.checkUpkeep("");
        upkeepParams = _logUpkeep(upkeepNeeded, performData);
        assertEq(upkeepParams.closedRequests, true, "active requests should be true");

        strategy.performUpkeep("");

        _logStateTransitions("STATE AFTER UPKEEP 2");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE DECREASE COLLATERAL 2");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT DECREASE COLLATERAL 2");

        ManagedBasisStrategy.WithdrawState memory withdrawState2 = _logWithdrawState(withdrawId2);

        vm.startPrank(user2);
        uint256 user2BalBefore = IERC20(asset).balanceOf(user2);
        strategy.claim(withdrawId2);
        uint256 user2BalDelta = IERC20(asset).balanceOf(user2) - user2BalBefore;

        assertEq(
            user2BalDelta, withdrawState2.requestedAmount - withdrawState2.executionCost, "user2 should receive funds"
        );

        _logStateTransitions("STATE AFTER CLAIM 2");
    }

    function test_hedgeDeviationBelowThreshold() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        // uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        // uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("STATE BEFORE HEDGE DEVIATION");

        vm.startPrank(wethWhale);
        uint256 productTransfer = IERC20(product).balanceOf(address(strategy)) / 105;
        IERC20(product).transfer(address(strategy), productTransfer);

        _logStateTransitions("STATE AFTER HEDGE DEVIATION");

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);

        assertEq(upkeepParams.hedgeDeviation, false, "hedge deviation should be false");
    }

    function test_hedgeDeviationAboveThresholdUp() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        // uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        // uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("STATE BEFORE HEDGE DEVIATION");

        vm.startPrank(wethWhale);
        uint256 productTransfer = IERC20(product).balanceOf(address(strategy)) / 98;
        IERC20(product).transfer(address(strategy), productTransfer);

        _logStateTransitions("STATE AFTER HEDGE DEVIATION");

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);

        assertEq(upkeepParams.hedgeDeviation, true, "hedge deviation should be true");

        strategy.performUpkeep("");

        _logStateTransitions("STATE AFTER PERFORM KEEP");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE KEEP");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT KEEP");

        (upkeepNeeded, performData) = strategy.checkUpkeep("");
        _logUpkeep(upkeepNeeded, performData);
        assertEq(upkeepNeeded, false, "upkeep should not be needed");
    }

    function test_hedgeDeviationAboveThresholdDown() public {
        vm.startPrank(user1);
        IERC20(asset).approve(address(strategy), depositAmount);
        strategy.deposit(depositAmount, user1);

        uint256 utilizationAmount = strategy.pendingUtilization();
        bytes memory data = _generateInchCallData(asset, product, utilizationAmount);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionCollateral(0, 0);

        vm.expectEmit(false, false, false, false, address(positionManager));
        emit OffChainPositionManager.RequestIncreasePositionSize(0, 0);

        vm.startPrank(operator);
        strategy.utilize(utilizationAmount, ManagedBasisStrategy.SwapType.INCH_V6, data);

        vm.startPrank(agent);
        positionManager.transferToAgent();

        OffChainPositionManager.RequestInfo memory request = _logRequest();
        // uint256 sizeDeltaInTokens = IERC20(product).balanceOf(address(strategy));
        // uint256 collateralDelta = IERC20(asset).balanceOf(agent);

        OffChainPositionManager.RequestInfo memory response = _executeRequest(request);
        _reportState(request, response);

        _logStateTransitions("STATE BEFORE HEDGE DEVIATION");

        vm.startPrank(address(strategy));
        uint256 productTransfer = IERC20(product).balanceOf(address(strategy)) / 98;
        IERC20(product).transfer(address(wethWhale), productTransfer);

        _logStateTransitions("STATE AFTER HEDGE DEVIATION");

        vm.startPrank(address(operator));

        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        UpkeepParams memory upkeepParams = _logUpkeep(upkeepNeeded, performData);

        assertEq(upkeepParams.hedgeDeviation, true, "hedge deviation should be true");

        strategy.performUpkeep("");

        _logStateTransitions("STATE AFTER PERFORM KEEP");

        vm.startPrank(agent);
        request = _logRequest();
        response = _executeRequest(request);

        _logStateTransitions("STATE AFTER EXECUTE KEEP");

        _reportState(request, response);
        _logStateTransitions("STATE AFTER REPORT KEEP");

        (upkeepNeeded, performData) = strategy.checkUpkeep("");
        assertEq(upkeepNeeded, false, "upkeep should not be needed");
    }
}
