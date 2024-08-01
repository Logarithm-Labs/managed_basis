// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import "src/interfaces/IManagedBasisStrategy.sol";

import {ForkTest} from "./ForkTest.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OffChainTest is ForkTest {
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

    function _initOffChainTest(address _asset, address _product, address _oracle) internal {
        asset_ = _asset;
        product_ = _product;
        oracle_ = IOracle(_oracle);
        vm.startPrank(address(this));
        IERC20(_asset).approve(agent, type(uint256).max);
        vm.startPrank(agent);
        IERC20(_asset).approve(address(positionManager), type(uint256).max);
    }

    function _fullOffChainExecute() internal {
        vm.startPrank(agent);
        DataTypes.PositionManagerPayload memory request = _getRequest();
        DataTypes.PositionManagerPayload memory response = _executeRequest(request);
        _reportStateAndExecuteRequest(response);
        vm.stopPrank();
    }

    function _getRequest() internal view returns (DataTypes.PositionManagerPayload memory request) {
        OffChainPositionManager.RequestInfo memory requestInfo = positionManager.getLastRequest();
        request = requestInfo.request;
    }

    function _executeRequest(DataTypes.PositionManagerPayload memory request)
        internal
        returns (DataTypes.PositionManagerPayload memory response)
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

    function _reportState() internal {
        uint256 markPrice = _getMarkPrice();
        positionManager.reportState(positionSizeInTokens, positionNetBalance, markPrice);
    }

    function _reportStateAndExecuteRequest(DataTypes.PositionManagerPayload memory response) internal {
        uint256 markPrice = _getMarkPrice();
        DataTypes.PositionManagerPayload memory params = DataTypes.PositionManagerPayload({
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
