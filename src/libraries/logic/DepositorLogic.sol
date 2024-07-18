// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "src/interfaces/IOracle.sol";
import {CompactBasisStrategy} from "src/CompactBasisStrategy.sol";

import {AccountingLogic} from "src/libraries/logic/AccountingLogic.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {DataTypes} from "src/libraries/utils/DataTypes.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

library DepositorLogic {
    using Math for uint256;

    struct DepositParams {
        address asset;
        uint256 assets;
        DataTypes.StrategyStateChache cache;
    }

    struct WithdrawParams {
        address asset;
        address receiver;
        address owner;
        uint256 requestCounter;
        uint256 assets;
        DataTypes.StrategyStateChache cache;
    }

    struct ClaimParams {
        address caller;
        DataTypes.WithdrawRequestState withdrawState;
        DataTypes.StrategyStateChache cache;
    }

    function executeDeposit(DepositParams memory params)
        external
        pure
        returns (DataTypes.StrategyStateChache memory cache)
    {
        uint256 idleAssets = AccountingLogic.getIdleAssets(params.asset, params.cache);
        (, cache) = processWithdrawRequests(idleAssets, params.cache);
    }

    function executeWithdraw(WithdrawParams memory params)
        external
        view
        returns (
            bytes32 withdrawId,
            DataTypes.StrategyStateChache memory,
            DataTypes.WithdrawRequestState memory withdrawState
        )
    {
        uint256 idleAssets = AccountingLogic.getIdleAssets(params.asset, params.cache);
        if (idleAssets >= params.assets) {
            withdrawId = bytes32(0);
        } else {
            uint256 pendingWithdraw = params.assets - idleAssets;
            params.cache.accRequestedWithdrawAssets += pendingWithdraw;
            withdrawId = getWithdrawId(params.owner, params.requestCounter);
            withdrawState = DataTypes.WithdrawRequestState({
                requestedAssets: params.assets,
                accRequestedWithdrawAssets: params.cache.accRequestedWithdrawAssets,
                requestTimestamp: block.timestamp,
                receiver: params.receiver,
                isClaimed: false
            });
        }
        return (withdrawId, params.cache, withdrawState);
    }

    /// @dev process withdraw request
    /// Note: should be called whenever assets come to this vault
    /// including user's deposit and system's deutilizing
    ///
    /// @return assets remaining which goes to idle or assetsToWithdraw

    function processWithdrawRequests(uint256 assets, DataTypes.StrategyStateChache memory cache)
        public
        returns (uint256, DataTypes.StrategyStateChache memory)
    {
        if (assets == 0) return (0, cache);

        // check if there is neccessarity to process withdraw requests
        if (cache.proccessedWithdrawAssets < cache.accRequestedWithdrawAssets) {
            uint256 remainingAssets;
            uint256 proccessedWithdrawAssetsAfter = cache.proccessedWithdrawAssets + assets;

            // if proccessedWithdrawAssets overshoots accRequestedWithdrawAssets,
            // then cap it by accRequestedWithdrawAssets
            // so that the remaining asset goes to idle
            if (proccessedWithdrawAssetsAfter > cache.accRequestedWithdrawAssets) {
                remainingAssets = proccessedWithdrawAssetsAfter - cache.accRequestedWithdrawAssets;
                proccessedWithdrawAssetsAfter = cache.accRequestedWithdrawAssets;
                assets = proccessedWithdrawAssetsAfter - cache.proccessedWithdrawAssets;
            }

            cache.assetsToClaim += assets;
            cache.proccessedWithdrawAssets = proccessedWithdrawAssetsAfter;
        }

        // @todo: should update pending deutilization

        return (assets, cache);
    }

    function getWithdrawId(address owner, uint256 counter) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), owner, counter));
    }
}
