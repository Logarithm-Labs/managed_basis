// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {Position} from "src/externals/gmx-v2/libraries/Position.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {MarketUtils} from "src/externals/gmx-v2/libraries/MarketUtils.sol";
import {Price} from "src/externals/gmx-v2/libraries/Price.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";
import {IOracle} from "src/oracle/IOracle.sol";

contract DataProvider {
    using SafeCast for uint256;

    address constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_READER = 0x5Ca84c34a381434786738735265b9f3FD814b824;

    struct StrategyState {
        uint8 strategyStatus;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 utilizedAssets;
        uint256 idleAssets;
        uint256 assetBalance;
        uint256 productBalance;
        uint256 productValueInAsset;
        uint256 assetsToWithdraw;
        uint256 assetsToClaim;
        uint256 totalPendingWithdraw;
        uint256 pendingUtilization;
        uint256 pendingDeutilization;
        uint256 accRequestedWithdrawAssets;
        uint256 processedWithdrawAssets;
        uint256 positionNetBalance;
        uint256 positionLeverage;
        uint256 positionSizeInTokens;
        bool upkeepNeeded;
        bool rebalanceUpNeeded;
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        bool decreaseCollateral;
        bool rehedgeNeeded;
        bool hedgeManagerKeepNeeded;
        bool processingRebalanceDown;
        bool strategyPaused;
        bool vaultPaused;
    }

    struct GmxPositionInfo {
        uint256 positionSizeUsd; // 30 decimals
        uint256 indexPrice; // mark_price 30 - indexToken decimals
        int256 liquidationPrice; // 30 - indexToken decimals
        int256 unrealizedPnlUsd; // 30 decimals
        int256 accumulatedFundingFeesUsd; // 30 decimals
        uint256 accumulatedPositionFeesUsd; // 30 decimals
    }

    function getStrategyState(address _strategy) external view returns (StrategyState memory state) {
        BasisStrategy strategy = BasisStrategy(_strategy);
        IHedgeManager hedgeManager = IHedgeManager(strategy.hedgeManager());
        LogarithmVault vault = LogarithmVault(strategy.vault());
        IOracle oracle = IOracle(strategy.oracle());
        address asset = strategy.asset();
        address product = strategy.product();
        bool rebalanceDownNeeded;
        bool deleverageNeeded;
        int256 hedgeDeviationInTokens;
        bool hedgeManagerNeedKeep;
        bool decreaseCollateral;
        bool rebalanceUpNeeded;
        (bool upkeepNeeded, bytes memory performData) = strategy.checkUpkeep("");
        if (performData.length > 0) {
            (
                rebalanceDownNeeded,
                deleverageNeeded,
                hedgeDeviationInTokens,
                hedgeManagerNeedKeep,
                decreaseCollateral,
                rebalanceUpNeeded
            ) = _decodePerformData(performData);
        }

        state.strategyStatus = uint8(strategy.strategyStatus());
        state.totalSupply = vault.totalSupply();
        state.totalAssets = vault.totalAssets();
        state.utilizedAssets = strategy.utilizedAssets();
        state.idleAssets = vault.idleAssets();
        state.assetBalance = IERC20(asset).balanceOf(address(vault)) + IERC20(asset).balanceOf(address(strategy));
        state.productBalance = ISpotManager(strategy.spotManager()).exposure();
        state.productValueInAsset = oracle.convertTokenAmount(product, asset, state.productBalance);
        state.assetsToWithdraw = IERC20(asset).balanceOf(address(strategy));
        state.assetsToClaim = vault.assetsToClaim();
        state.totalPendingWithdraw = vault.totalPendingWithdraw();
        (state.pendingUtilization, state.pendingDeutilization) = strategy.pendingUtilizations();
        state.accRequestedWithdrawAssets = vault.accRequestedWithdrawAssets();
        state.processedWithdrawAssets = vault.processedWithdrawAssets();
        state.positionNetBalance = hedgeManager.positionNetBalance();
        state.positionLeverage = hedgeManager.currentLeverage();
        state.positionSizeInTokens = hedgeManager.positionSizeInTokens();
        state.upkeepNeeded = upkeepNeeded;
        state.rebalanceUpNeeded = rebalanceUpNeeded;
        state.rebalanceDownNeeded = rebalanceDownNeeded;
        state.deleverageNeeded = deleverageNeeded;
        state.decreaseCollateral = decreaseCollateral;
        state.rehedgeNeeded = hedgeDeviationInTokens == 0 ? false : true;
        state.hedgeManagerKeepNeeded = hedgeManagerNeedKeep;
        state.processingRebalanceDown = strategy.processingRebalanceDown();
        state.strategyPaused = strategy.paused();
        state.vaultPaused = vault.paused();
    }

    function getGmxPositionInfo(address hedgeManagerAddr) external view returns (GmxPositionInfo memory positionInfo) {
        GmxV2PositionManager hedgeManager = GmxV2PositionManager(hedgeManagerAddr);
        BasisStrategy strategy = BasisStrategy(hedgeManager.strategy());
        Market.Props memory market = Market.Props({
            marketToken: hedgeManager.marketToken(),
            indexToken: hedgeManager.indexToken(),
            longToken: hedgeManager.longToken(),
            shortToken: hedgeManager.shortToken()
        });
        IOracle oracle = IOracle(strategy.oracle());
        bytes32 positionKey =
            _getPositionKey(hedgeManagerAddr, market.marketToken, hedgeManager.collateralToken(), hedgeManager.isLong());
        Position.Props memory position = IReader(GMX_READER).getPosition(IDataStore(GMX_DATA_STORE), positionKey);

        // position size in usd
        positionInfo.positionSizeUsd = position.numbers.sizeInUsd;

        // index price
        positionInfo.indexPrice = oracle.getAssetPrice(market.indexToken);

        if (position.numbers.sizeInTokens > 0) {
            // unrealizedPnl
            (positionInfo.unrealizedPnlUsd,,) = IReader(GMX_READER).getPositionPnlUsd(
                IDataStore(GMX_DATA_STORE),
                market,
                _getPrices(address(oracle), market),
                positionKey,
                position.numbers.sizeInUsd
            );

            // liquidation price, assuming current position is not liquidatable
            uint256 minCollateralFactor =
                IDataStore(GMX_DATA_STORE).getUint(Keys.minCollateralFactorKey(market.marketToken));
            int256 minCollateralUsdForLeverage =
                Precision.applyFactor(position.numbers.sizeInUsd, minCollateralFactor).toInt256();

            // liquidation condition: remainingCollateralUsd < minCollateralUsdForLeverage
            // remainingCollateralUsd = collateralUsd + pnlUsd - fees
            // pnlUsd = sizeInUsd - sizeInTokens * executionPrice (short)
            // remainingCollateralUsd = collateralUsd + sizeInUsd - sizeInTokens * executionPrice - fees < minCollateralUsdForLeverage
            // executionPrice > (collateralUsd + sizeInUsd - fees - minCollateralUsdForLeverage) / sizeInTokens
            // hence, liquidationPrice = (collateralUsd + sizeInUsd - fees - minCollateralUsdForLeverage) / sizeInTokens

            // positionNetBalance * collateralPrice == remainingCollateralUsd
            uint256 positionNetBalance = hedgeManager.positionNetBalance();
            uint256 collateralTokenPrice = oracle.getAssetPrice(hedgeManager.collateralToken());
            uint256 positionNetBalanceUsd = positionNetBalance * collateralTokenPrice;
            positionInfo.liquidationPrice = (
                positionNetBalanceUsd.toInt256() - positionInfo.unrealizedPnlUsd + position.numbers.sizeInUsd.toInt256()
                    - minCollateralUsdForLeverage
            ) / position.numbers.sizeInTokens.toInt256();
        }

        // accumulated funding fee
        uint256 cumulativeClaimedFundingUsd = hedgeManager.cumulativeClaimedFundingUsd();
        (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount) =
            hedgeManager.getAccruedClaimableFundingAmounts();
        (uint256 nextClaimableLongTokenAmount, uint256 nextClaimableShortTokenAmount) =
            hedgeManager.getClaimableFundingAmounts();
        uint256 longTokenPrice = oracle.getAssetPrice(market.longToken);
        uint256 shortTokenPrice = oracle.getAssetPrice(market.shortToken);
        uint256 claimableFundingUsd = (claimableLongTokenAmount + nextClaimableLongTokenAmount) * longTokenPrice
            + (claimableShortTokenAmount + nextClaimableShortTokenAmount) * shortTokenPrice;
        (uint256 fundingFeeUsd, uint256 borrowingFeeUsd) = hedgeManager.cumulativeFundingAndBorrowingFeesUsd();
        positionInfo.accumulatedFundingFeesUsd = (cumulativeClaimedFundingUsd + claimableFundingUsd).toInt256()
            - (fundingFeeUsd + borrowingFeeUsd).toInt256();

        // accumulated position fee
        positionInfo.accumulatedPositionFeesUsd = hedgeManager.cumulativePositionFeeUsd();
    }

    function _getPositionKey(address account, address marketToken, address collateralToken, bool isLong)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(account, marketToken, collateralToken, isLong));
    }

    /// @dev get all prices of maket tokens including long, short, and index tokens
    /// the return type is like the type that is required by gmx
    function _getPrices(address oracle, Market.Props memory market)
        private
        view
        returns (MarketUtils.MarketPrices memory prices)
    {
        uint256 longTokenPrice = IOracle(oracle).getAssetPrice(market.longToken);
        uint256 shortTokenPrice = IOracle(oracle).getAssetPrice(market.shortToken);
        uint256 indexTokenPrice = IOracle(oracle).getAssetPrice(market.indexToken);
        indexTokenPrice = indexTokenPrice == 0 ? longTokenPrice : indexTokenPrice;
        prices.indexTokenPrice = Price.Props(indexTokenPrice, indexTokenPrice);
        prices.longTokenPrice = Price.Props(longTokenPrice, longTokenPrice);
        prices.shortTokenPrice = Price.Props(shortTokenPrice, shortTokenPrice);
    }

    function _decodePerformData(bytes memory performData)
        internal
        pure
        returns (
            bool rebalanceDownNeeded,
            bool deleverageNeeded,
            int256 hedgeDeviationInTokens,
            bool hedgeManagerNeedKeep,
            bool decreaseCollateral,
            bool rebalanceUpNeeded
        )
    {
        uint256 emergencyDeutilizationAmount;
        uint256 deltaCollateralToIncrease;
        bool clearProcessingRebalanceDown;
        uint256 deltaCollateralToDecrease;

        (
            emergencyDeutilizationAmount,
            deltaCollateralToIncrease,
            clearProcessingRebalanceDown,
            hedgeDeviationInTokens,
            hedgeManagerNeedKeep,
            decreaseCollateral,
            deltaCollateralToDecrease
        ) = abi.decode(performData, (uint256, uint256, bool, int256, bool, bool, uint256));

        rebalanceDownNeeded = emergencyDeutilizationAmount > 0 || deltaCollateralToIncrease > 0;
        deleverageNeeded = emergencyDeutilizationAmount > 0;
        rebalanceUpNeeded = deltaCollateralToDecrease > 0;
    }
}
