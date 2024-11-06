// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {GmxConfig} from "src/position/gmx/GmxConfig.sol";
import {GmxGasStation} from "src/position/gmx/GmxGasStation.sol";
import {GmxV2PositionManager} from "src/position/gmx/GmxV2PositionManager.sol";

import {GmxV2Test} from "test/base/GmxV2Test.sol";
import {ForkTest} from "test/base/ForkTest.sol";
import {StrategyHelper, StrategyState} from "test/helper/StrategyHelper.sol";

contract GmxHandler is GmxV2Test {
    BasisStrategy strategy;
    LogarithmVault vault;
    LogarithmOracle oracle;

    StrategyHelper helper;

    address owner;
    address operator;
    address forwarder;

    IERC20 asset;
    IERC20 product;

    address[] public actors;

    address internal currentActor;

    modifier useActor(uint256 actorIndexSeed) {
        uint256 len = actors.length;
        if (len == 0) currentActor = msg.sender;
        else currentActor = actors[bound(actorIndexSeed, 0, len - 1)];

        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(BasisStrategy _strategy, address _owner, address _operator, address _forwarder) {
        owner = _owner;
        operator = _operator;
        forwarder = _forwarder;
        strategy = _strategy;
        asset = IERC20(_strategy.asset());
        product = IERC20(_strategy.product());
        vault = LogarithmVault(_strategy.vault());
        oracle = LogarithmOracle(_strategy.oracle());
        address positionManagerAddr = _initPositionManager(owner, address(_strategy));
        vm.startPrank(owner);
        strategy.setPositionManager(positionManagerAddr);
        vm.stopPrank();

        helper = new StrategyHelper(address(strategy));
    }

    /*//////////////////////////////////////////////////////////////
                               USER LOGIC
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets) public {
        address user = msg.sender;
        assets = bound(assets, 0, vault.maxDeposit(user));
        assets = bound(assets, 0, asset.balanceOf(USDC_WHALE));

        actors.push(user);

        vm.startPrank(USDC_WHALE);
        asset.transfer(user, assets);

        vm.startPrank(user);
        asset.approve(address(vault), assets);
        vault.deposit(assets, user);
        vm.stopPrank();
    }

    function redeem(uint256 shares, uint256 actorIndexSeed) public useActor(actorIndexSeed) {
        shares = bound(shares, 0, vault.balanceOf(currentActor));
        vault.requestRedeem(shares, currentActor, currentActor);
    }

    function claim(uint256 actorIndexSeed) public useActor(actorIndexSeed) {
        uint256 nonce = vault.nonces(currentActor);
        for (uint256 i; i < nonce; i++) {
            bytes32 key = vault.getWithdrawKey(currentActor, nonce);
            if (vault.isClaimable(key)) {
                vault.claim(key);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OPERATOR LOGIC
    //////////////////////////////////////////////////////////////*/

    function utilize(uint256 amount) public {
        (uint256 utilization,) = strategy.pendingUtilizations();
        if (utilization == 0) return;
        amount = bound(amount, 1, utilization);
        vm.startPrank(operator);
        strategy.utilize(amount, BasisStrategy.SwapType.MANUAL, "");
    }

    function deutilize(uint256 amount) public {
        (, uint256 deutilization) = strategy.pendingUtilizations();
        if (deutilization == 0) return;
        amount = bound(amount, 1, deutilization);
        vm.startPrank(operator);
        strategy.deutilize(amount, BasisStrategy.SwapType.MANUAL, "");
    }

    function performUpkeep() public {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        if (upkeepNeeded) {
            strategy.performUpkeep(performData);
        }
    }

    function executeOrder() public {
        _executeOrder();
    }

    function fullExecution() public {
        performUpkeep();
        (uint256 utilization, uint256 deutilization) = strategy.pendingUtilizations();
        if (utilization > 0) {
            utilize(utilization);
            executeOrder();
        }
        if (deutilization > 0) {
            deutilize(deutilization);
            executeOrder();
        }
        performUpkeep();
    }

    /*//////////////////////////////////////////////////////////////
                                  MOCK
    //////////////////////////////////////////////////////////////*/

    function updateProductPrice(bool isRise, bool isProduct, uint256 fluctuation) public {
        fluctuation = bound(fluctuation, 0, 0.5 ether);
        if (fluctuation == 0) return;

        address priceFeed = isProduct ? oracle.getPriceFeed(address(product)) : oracle.getPriceFeed(address(asset));
        int256 currPrice = IPriceFeed(priceFeed).latestAnswer();
        uint256 deltaPrice = Math.mulDiv(uint256(currPrice), fluctuation, 1 ether);

        int256 resultedPrice = isRise ? currPrice + int256(deltaPrice) : currPrice - int256(deltaPrice);
        _mockChainlinkPriceFeedAnswer(priceFeed, resultedPrice);
    }

    function callSummary() public view {
        StrategyState memory state = helper.getStrategyState();
        helper.logStrategyState("SUMMARY", state);
    }
}
