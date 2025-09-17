// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasisStrategyState} from "./BasisStrategyState.sol";

library AssetsState {
    using Math for uint256;

    function _utilizedAssets() internal view returns (uint256) {
        return BasisStrategyState.getSpotManager().getAssetValue()
            + BasisStrategyState.getHedgeManager().positionNetBalance() + _assetsToWithdraw();
    }

    function _assetsToWithdraw() internal view returns (uint256) {
        return BasisStrategyState.getAsset().balanceOf(address(this));
    }

    function _assetsToDeutilize() internal view returns (uint256) {
        (, uint256 assets) = BasisStrategyState.getVault().totalPendingWithdraw().trySub(_assetsToWithdraw());
        return assets;
    }
}
