// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BasisStrategyState} from "./BasisStrategyState.sol";
import {IHedgeManager} from "../../hedge/IHedgeManager.sol";

library Position {
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @dev Validate the position adjustment parameters before requesting.
    function adjustPosition(uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease, bool emitRequest)
        external
        returns (uint256)
    {
        IHedgeManager _hedgeManager = BasisStrategyState.getHedgeManager();

        if (isIncrease && collateralDeltaAmount > 0) {
            BasisStrategyState.getAsset().safeTransferFrom(
                address(BasisStrategyState.getVault()), address(_hedgeManager), collateralDeltaAmount
            );
        }

        IHedgeManager.AdjustPositionPayload memory requestParams = IHedgeManager.AdjustPositionPayload({
            sizeDeltaInTokens: sizeDeltaInTokens,
            collateralDeltaAmount: collateralDeltaAmount,
            isIncrease: isIncrease
        });
        BasisStrategyState.setRequestParams(requestParams);
        return _hedgeManager.adjustPosition(requestParams, emitRequest);
    }
}
