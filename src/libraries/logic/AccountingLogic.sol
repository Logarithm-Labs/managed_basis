// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {IOffChainPositionManager} from "src/interfaces/IOffChainPositionManager.sol";

import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library AccountingLogic {
    using Math for uint256;

    function getTotalAssets(
        CompactBasisStrategy.StrategyAddresses memory addr,
        CompactBasisStrategy.StrategyStateChache memory cache
    ) external view returns (uint256) {
        uint256 utilizedAssets = getUtilizedAssets(addr, cache);
        uint256 idleAssets = getIdleAssets(addr.asset, cache);

        // In the scenario where user tries to withdraw all of the remaining assets the volatility
        // of oracle price can create a situation where pending withdraw is greater then the sum of
        // idle and utilized assets. In this case we will return 0 as total assets.
        (, uint256 totalAssets) =
            (utilizedAssets + idleAssets).trySub(cache.totalPendingWithdraw + cache.withdrawingFromHedge);
        return totalAssets;
    }

    function getUtilizedAssets(
        CompactBasisStrategy.StrategyAddresses memory addr,
        CompactBasisStrategy.StrategyStateChache memory cache
    ) public view returns (uint256) {
        uint256 productBalance = IERC20(addr.product).balanceOf(address(this));
        uint256 productValueInAsset = IOracle(addr.oracle).convertTokenAmount(addr.product, addr.asset, productBalance);
        return productValueInAsset + IOffChainPositionManager(addr.positionManager).positionNetBalance();
    }

    function getIdleAssets(address asset, CompactBasisStrategy.StrategyStateChache memory cache)
        public
        view
        returns (uint256)
    {
        return IERC20(asset).balanceOf(address(this)) - (cache.assetsToClaim + cache.assetsToWithdraw);
    }
}
