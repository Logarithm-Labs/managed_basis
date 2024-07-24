// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {AccumulatedBasisStrategy} from "src/AccumulatedBasisStrategy.sol";
import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ProdTest is Test {
    using Math for uint256;

    uint256 PRECISION = 1e18;

    AccumulatedBasisStrategy public strategy = AccumulatedBasisStrategy(0xC69c6A3228BB8EE5Bdd0C656eEA43Bf8713B0740);
    OffChainPositionManager public positionManager;
    address public asset;
    address public product;

    function setUp() public {
        asset = strategy.asset();
        product = strategy.product();
        positionManager = OffChainPositionManager(strategy.positionManager());
    }

    function test_run() public {
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        (bool statusKeep, bool hedgeDeviation, bool decreaseCollateral) = abi.decode(performData, (bool, bool, bool));
        console.log("upkeepNeeded", upkeepNeeded);
        console.log("statusKeep", statusKeep);
        console.log("hedgeDeviation", hedgeDeviation);
        console.log("decreaseCollateral", decreaseCollateral);

        _logState();
    }

    function _logState() internal view {
        uint256 productBalance = IERC20(product).balanceOf(address(strategy));
        uint256 positionSizeInTokens = positionManager.positionSizeInTokens();
        (uint256 hedgeDeviation, bool hedgeDeviationIncrease) =
            _checkHedgeDeviation(productBalance, positionSizeInTokens);
        uint256 positionNetBalance = positionManager.positionNetBalance();
        uint256 totalAssets = strategy.totalAssets();
        uint256 utilizedAssets = strategy.utilizedAssets();
        uint256 idleAssets = strategy.idleAssets();
        uint256 totalPendingWithdraw = strategy.totalPendingWithdraw();
        uint256 assetsToClaim = strategy.assetsToClaim();
        uint256 assetsToWithdraw = strategy.assetsToWithdraw();

        console.log("totalAssets", totalAssets);
        console.log("utilizedAssets", utilizedAssets);
        console.log("idleAssets", idleAssets);
        console.log("totalPendingWithdraw", totalPendingWithdraw);
        console.log("strategyAssetBalance", IERC20(asset).balanceOf(address(this)));
        console.log("assetsToClaim", assetsToClaim);
        console.log("assetsToWithdraw", assetsToWithdraw);

        console.log("positionNetBalance", positionNetBalance);
        console.log("productBalance", productBalance);
        console.log("positionSizeInTokens", positionSizeInTokens);
        console.log("hedgeDeviationIncrease", hedgeDeviationIncrease);
        console.log("hedgeDeviation", hedgeDeviation);
        console.log();
    }

    function _checkHedgeDeviation(uint256 spotExposure, uint256 hedgeExposure)
        internal
        view
        returns (uint256 hedgeDeviationInTokens, bool isIncrease)
    {
        if (spotExposure == 0) {
            if (hedgeExposure == 0) {
                return (0, false);
            } else {
                return (hedgeExposure, false);
            }
        }
        uint256 hedgeDeviationThreshold = strategy.hedgeDeviationThreshold();
        uint256 hedgeDeviation = hedgeExposure.mulDiv(PRECISION, spotExposure);
        if (hedgeDeviation > PRECISION + hedgeDeviationThreshold) {
            // strategy is overhedged, need to decrease position size
            isIncrease = false;
            hedgeDeviationInTokens = hedgeExposure - spotExposure;
        } else if (hedgeDeviation < PRECISION - hedgeDeviationThreshold) {
            // strategy is underhedged, need to increase position size
            isIncrease = true;
            hedgeDeviationInTokens = spotExposure - hedgeExposure;
        }
    }
}
