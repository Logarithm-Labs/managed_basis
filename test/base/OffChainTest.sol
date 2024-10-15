// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {IPositionManager} from "src/position/IPositionManager.sol";
import {PositionMngerForkTest} from "./PositionMngerForkTest.sol";
import {OffChainPositionManager} from "src/position/offchain/OffChainPositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OffChainConfig} from "src/position/offchain/OffChainConfig.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";
import {console2 as console} from "forge-std/console2.sol";

contract OffChainTest is PositionMngerForkTest {
    using Math for uint256;

    // off chain exchange state variables
    uint256 public positionNetBalance;
    uint256 public positionSizeInTokens;
    uint256 public positionMarkPrice;

    uint256 constant executionFee = 0.001 ether;
    uint256 constant FLOAT_PRECISION = 1e18;

    address public immutable agent = makeAddr("agent");
    OffChainPositionManager public positionManager;
    IOracle public oracle_;
    address public asset_;
    address public product_;

    uint256 constant increaseSizeMin = 15 * 1e6;
    uint256 constant increaseSizeMax = type(uint256).max;
    uint256 constant decreaseSizeMin = 15 * 1e6;
    uint256 constant decreaseSizeMax = type(uint256).max;

    uint256 constant increaseCollateralMin = 5 * 1e6;
    uint256 constant increaseCollateralMax = type(uint256).max;
    uint256 constant decreaseCollateralMin = 10 * 1e6;
    uint256 constant decreaseCollateralMax = type(uint256).max;
    uint256 constant limitDecreaseCollateral = 50 * 1e6;

    function _initPositionManager(address owner, address strategy) internal override returns (address) {
        vm.startPrank(owner);
        // deploy config
        OffChainConfig config = DeployHelper.deployOffChainConfig(owner);
        config.setSizeMinMax(increaseSizeMin, increaseSizeMax, decreaseSizeMin, decreaseSizeMax);
        config.setCollateralMinMax(
            increaseCollateralMin, increaseCollateralMax, decreaseCollateralMin, decreaseCollateralMax
        );
        config.setLimitDecreaseCollateral(limitDecreaseCollateral);
        vm.label(address(config), "config");

        address oracle = IBasisStrategy(strategy).oracle();
        address product = IBasisStrategy(strategy).product();
        address asset = IBasisStrategy(strategy).asset();

        // deploy positionManager beacon
        address positionManagerBeacon = DeployHelper.deployBeacon(address(new OffChainPositionManager()), owner);
        // deploy positionMnager beacon proxy
        positionManager = DeployHelper.deployOffChainPositionManager(
            DeployHelper.OffChainPositionManagerDeployParams(
                owner, address(config), positionManagerBeacon, strategy, agent, oracle, product, asset, false
            )
        );
        vm.label(address(positionManager), "positionManager");

        asset_ = asset;
        product_ = product;
        oracle_ = IOracle(oracle);

        vm.startPrank(address(this));
        IERC20(asset).approve(agent, type(uint256).max);
        vm.startPrank(agent);
        IERC20(asset).approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        return address(positionManager);
    }

    function _initOffChainTest(address _asset, address _product, address _oracle) internal {}

    function _positionManager() internal view override returns (IPositionManager) {
        return IPositionManager(positionManager);
    }

    function _executeOrder() internal override {
        OffChainPositionManager.RequestInfo memory requestInfo = positionManager.getLastRequest();
        if (!requestInfo.isReported) {
            vm.startPrank(agent);
            IPositionManager.AdjustPositionPayload memory request = requestInfo.request;
            IPositionManager.AdjustPositionPayload memory response = _executeRequest(request);
            _reportStateAndExecuteRequest(response);
            vm.stopPrank();
        }
    }

    function _executeRequest(IPositionManager.AdjustPositionPayload memory request)
        internal
        returns (IPositionManager.AdjustPositionPayload memory response)
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
            if (request.sizeDeltaInTokens > 0) {
                response.sizeDeltaInTokens = _decreasePositionSize(request.sizeDeltaInTokens);
            }
            if (request.collateralDeltaAmount > 0) {
                response.collateralDeltaAmount = _decreasePositionCollateral(request.collateralDeltaAmount);
            }
        }
    }

    function _reportState() internal {
        uint256 markPrice = _getMarkPrice();
        positionManager.reportState(positionSizeInTokens, positionNetBalance, markPrice);
    }

    function _updatePositionNetBalance(uint256 netBalance) internal {
        IERC20(asset_).transfer(USDC_WHALE, IERC20(asset_).balanceOf(address(this)));
        positionNetBalance = netBalance;
        vm.startPrank(USDC_WHALE);
        IERC20(asset_).transfer(address(this), netBalance);
    }

    function _reportStateAndExecuteRequest(IPositionManager.AdjustPositionPayload memory response) internal {
        uint256 markPrice = _getMarkPrice();
        IPositionManager.AdjustPositionPayload memory params = IPositionManager.AdjustPositionPayload({
            sizeDeltaInTokens: response.sizeDeltaInTokens,
            collateralDeltaAmount: response.collateralDeltaAmount,
            isIncrease: response.isIncrease
        });
        positionManager.reportStateAndExecuteRequest(positionSizeInTokens, positionNetBalance, markPrice, params);
    }

    function _increasePositionSize(uint256 sizeDeltaInTokens) internal returns (uint256) {
        positionSizeInTokens += sizeDeltaInTokens;
        return sizeDeltaInTokens;
    }

    function _decreasePositionSize(uint256 sizeDeltaInTokens) internal returns (uint256) {
        if (sizeDeltaInTokens > positionSizeInTokens) {
            positionSizeInTokens = 0;
            return positionSizeInTokens;
        } else {
            positionSizeInTokens -= sizeDeltaInTokens;
            return sizeDeltaInTokens;
        }
    }

    function _increasePositionCollateral(uint256 collateralAmount) internal returns (uint256) {
        IERC20(asset_).transfer(address(this), collateralAmount);
        positionNetBalance += collateralAmount;
        return collateralAmount;
    }

    function _decreasePositionCollateral(uint256 collateralAmount) internal returns (uint256) {
        uint256 balance = IERC20(asset_).balanceOf(address(this));
        uint256 transferAmount = collateralAmount > balance ? balance : collateralAmount;
        IERC20(asset_).transferFrom(address(this), agent, transferAmount);
        positionNetBalance -= transferAmount;
        return transferAmount;
    }

    function _getMarkPrice() internal view returns (uint256) {
        uint256 oraclePrice = oracle_.getAssetPrice(product_);
        uint256 precision =
            10 ** (60 - uint256(IERC20Metadata(product_).decimals()) - uint256(IERC20Metadata(asset_).decimals()));
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
            uint256 sizeDeltaInAsset = oracle_.convertTokenAmount(product_, asset_, sizeDeltaInTokens);
            executionCost = sizeDeltaInAsset.mulDiv(executionFee, FLOAT_PRECISION);
        }
    }
}
