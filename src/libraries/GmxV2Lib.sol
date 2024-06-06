// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {ArbGasInfo} from "src/externals/arbitrum/ArbGasInfo.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {IReferralStorage} from "src/externals/gmx-v2/interfaces/IReferralStorage.sol";

import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {MarketUtils} from "src/externals/gmx-v2/libraries/MarketUtils.sol";
import {Position} from "src/externals/gmx-v2/libraries/Position.sol";
import {Price} from "src/externals/gmx-v2/libraries/Price.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {ReaderPricingUtils} from "src/externals/gmx-v2/libraries/ReaderPricingUtils.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {IOracle} from "src/interfaces/IOracle.sol";

import {Errors} from "./Errors.sol";

import {console} from "forge-std/console.sol";

library GmxV2Lib {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct GetPosition {
        address dataStore;
        address reader;
        address marketToken;
        address account;
        address collateralToken;
        bool isLong;
    }

    struct GetPrices {
        Market.Props market;
        address oracle;
    }

    struct InternalGetMinCollateralAmount {
        Market.Props market;
        address dataStore;
        uint256 sizeInUsd;
        int256 sizeDeltaUsd;
        uint256 collateralTokenPrice;
        bool isLong;
    }

    /// @dev calculate the total claimable amount in collateral token when closing the whole
    /// Note: collateral + pnlAfterPriceImpactUsd (pnl + price impact) -
    /// total fee costs (funding fee + borrowing fee + position fee) + claimable fundings
    function getPositionNetAmount(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage
    ) external view returns (uint256) {
        (uint256 remainingCollateral, uint256 claimableTokenAmount) =
            _getRemainingCollateralAndClaimableFundingAmount(positionParams, pricesParams, referralStorage);
        return remainingCollateral + claimableTokenAmount;
    }

    /// @dev check if the claimable amount is bigger than limit share based on the remaining collateral
    function isFundingClaimable(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage,
        uint256 maxClaimableFundingShare,
        uint256 precision
    ) external view returns (bool) {
        (uint256 remainingCollateral, uint256 claimableTokenAmount) =
            _getRemainingCollateralAndClaimableFundingAmount(positionParams, pricesParams, referralStorage);
        uint256 netAmount = remainingCollateral + claimableTokenAmount;

        if (netAmount > 0) {
            return claimableTokenAmount.mulDiv(precision, netAmount) > maxClaimableFundingShare;
        } else {
            return false;
        }
    }

    function getPositionSizeInTokens(GetPosition calldata params) external view returns (uint256) {
        Position.Props memory position = _getPosition(params);
        return position.numbers.sizeInTokens;
    }

    /// @dev if initial collateral * 9 / 10 is enough to cover the delta amount, only reduce the collateral
    /// otherwise decrease position size at the same time to realize pnl to cover the remain delta collateral
    function getDecreaseCollateralResult(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 collateralDelta
    ) external view returns (uint256 initialCollateralDelta, uint256 sizeDeltaInTokens) {
        Position.Props memory position = _getPosition(positionParams);
        initialCollateralDelta = position.numbers.collateralAmount * 9 / 10;
        if (collateralDelta > initialCollateralDelta) {
            // fill the reducing collateral with realized pnl
            collateralDelta -= initialCollateralDelta;
            (, int256 uncappedPositionPnlUsd,) =
                _getPositionPnl(positionParams, pricesParams, position.numbers.sizeInUsd);
            if (uncappedPositionPnlUsd <= 0) {
                revert Errors.NotPositivePnl();
            }
            uint256 collateralTokenPrice =
                IOracle(pricesParams.oracle).getAssetPrice(position.addresses.collateralToken);
            uint256 uncappedPositionPnlAmount = uncappedPositionPnlUsd.toUint256() / collateralTokenPrice;
            sizeDeltaInTokens = collateralDelta.mulDiv(position.numbers.sizeInTokens, uncappedPositionPnlAmount);
            uint256 sizeDeltaUsd = collateralDelta.mulDiv(position.numbers.sizeInUsd, uncappedPositionPnlAmount);
            uint256 minCollateralAmount = _getMinCollateralAmount(
                InternalGetMinCollateralAmount({
                    market: pricesParams.market,
                    dataStore: positionParams.dataStore,
                    sizeInUsd: position.numbers.sizeInUsd,
                    sizeDeltaUsd: -int256(sizeDeltaUsd),
                    collateralTokenPrice: collateralTokenPrice,
                    isLong: positionParams.isLong
                })
            );
            if (minCollateralAmount > position.numbers.collateralAmount - initialCollateralDelta) {
                initialCollateralDelta = position.numbers.collateralAmount - minCollateralAmount;
            }
        } else {
            initialCollateralDelta = collateralDelta;
        }
        return (initialCollateralDelta, sizeDeltaInTokens);
    }

    /// @dev position info when closing fully
    function getPositionInfo(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage
    ) external view returns (ReaderUtils.PositionInfo memory) {
        MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
        return _getPositionInfo(positionParams, prices, referralStorage);
    }

    /// @dev in gmx v2, sizeDeltaInTokens = sizeInTokens * sizeDeltaUsd / sizeInUsd
    /// hence sizeDeltaUsd = ceil(sizeDeltaInTokens * sizeInUsd / sizeInTokens)
    function getSizeDeltaUsdForDecrease(GetPosition calldata params, uint256 sizeDeltaInTokens)
        external
        view
        returns (uint256 sizeDeltaUsd)
    {
        Position.Props memory position = _getPosition(params);
        sizeDeltaUsd =
            sizeDeltaInTokens.mulDiv(position.numbers.sizeInUsd, position.numbers.sizeInTokens, Math.Rounding.Ceil);
        return sizeDeltaUsd;
    }

    /// @dev return position delta size in usd when increasing
    /// considered the price impact
    function getSizeDeltaUsdForIncrease(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 sizeDeltaInTokens
    ) external view returns (uint256 sizeDeltaUsd) {
        Price.Props memory indexTokenPrice = _getPrice(pricesParams.oracle, pricesParams.market.indexToken);
        Position.Props memory position = _getPosition(positionParams);
        int256 baseSizeDeltaUsd = sizeDeltaInTokens.toInt256() * indexTokenPrice.max.toInt256();
        int256 priceImpactUsd = _getPriceImpactUsd(position, indexTokenPrice, positionParams, baseSizeDeltaUsd);
        // in gmx v2
        // int256 sizeDeltaInTokens;
        // if (params.position.isLong()) {
        //     sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() + priceImpactAmount;
        // } else {
        //     sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() - priceImpactAmount;
        // }
        // the resulted actual size delta will be a little bit different from this estimation
        if (positionParams.isLong) {
            sizeDeltaUsd = (baseSizeDeltaUsd - priceImpactUsd).toUint256();
        } else {
            sizeDeltaUsd = (baseSizeDeltaUsd + priceImpactUsd).toUint256();
        }
        return sizeDeltaUsd;
    }

    /// @dev returns transaction fees needed for gmx keeper
    function getExecutionFee(address dataStore, uint256 callbackGasLimit) external view returns (uint256, uint256) {
        uint256 estimatedGasLimitIncrease = IDataStore(dataStore).getUint(Keys.INCREASE_ORDER_GAS_LIMIT);
        uint256 estimatedGasLimitDecrease = IDataStore(dataStore).getUint(Keys.DECREASE_ORDER_GAS_LIMIT);
        estimatedGasLimitIncrease += callbackGasLimit;
        estimatedGasLimitDecrease += callbackGasLimit;
        uint256 baseGasLimit = IDataStore(dataStore).getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = IDataStore(dataStore).getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimitIncrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitIncrease, multiplierFactor);
        uint256 gasLimitDecrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitDecrease, multiplierFactor);
        uint256 gasPrice = tx.gasprice;
        if (gasPrice == 0) {
            gasPrice = ArbGasInfo(0x000000000000000000000000000000000000006C).getMinimumGasPrice();
        }
        return (gasPrice * gasLimitIncrease, gasPrice * gasLimitDecrease);
    }

    // @dev calculate the position fee in usd when changing position size
    function getPositionFeeUsd(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 sizeDeltaUsd,
        bool isIncrease
    ) external view returns (uint256) {
        Position.Props memory position = _getPosition(positionParams);
        Price.Props memory indexTokenPrice = _getPrice(pricesParams.oracle, pricesParams.market.indexToken);
        int256 priceImpactUsd = _getPriceImpactUsd(
            position, indexTokenPrice, positionParams, isIncrease ? int256(sizeDeltaUsd) : -int256(sizeDeltaUsd)
        );
        bool forPositiveImpact = priceImpactUsd > 0;
        uint256 positionFeeFactor = IDataStore(positionParams.dataStore).getUint(
            Keys.positionFeeFactorKey(positionParams.marketToken, forPositiveImpact)
        );
        uint256 positionFeeUsd = Precision.applyFactor(sizeDeltaUsd, positionFeeFactor);
        return positionFeeUsd;
    }

    /// @dev returns remainingCollateral and claimable funding amount in collateral token
    function _getRemainingCollateralAndClaimableFundingAmount(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage
    ) private view returns (uint256, uint256) {
        MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(positionParams, prices, referralStorage);
        uint256 collateralTokenPrice =
            IOracle(pricesParams.oracle).getAssetPrice(positionInfo.position.addresses.collateralToken);
        uint256 claimableUsd = positionInfo.fees.funding.claimableLongTokenAmount * prices.longTokenPrice.min
            + positionInfo.fees.funding.claimableShortTokenAmount * prices.shortTokenPrice.min;
        uint256 claimableTokenAmount = claimableUsd / collateralTokenPrice;

        int256 remainingCollateral = positionInfo.position.numbers.collateralAmount.toInt256()
            + positionInfo.pnlAfterPriceImpactUsd / collateralTokenPrice.toInt256()
            - positionInfo.fees.totalCostAmount.toInt256();

        return (remainingCollateral > 0 ? remainingCollateral.toUint256() : 0, claimableTokenAmount);
    }

    function _getPositionKey(address account, address marketToken, address collateralToken, bool isLong)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(account, marketToken, collateralToken, isLong));
    }

    /// @dev get position properties that are invariants
    function _getPosition(GetPosition calldata params) private view returns (Position.Props memory) {
        bytes32 positionKey = _getPositionKey(params.account, params.marketToken, params.collateralToken, params.isLong);
        return IReader(params.reader).getPosition(IDataStore(params.dataStore), positionKey);
    }

    /// @dev get position info including propeties and realizing pnl and fees and price impact
    /// Note: providing info when closing the whole position
    function _getPositionInfo(
        GetPosition calldata positionParams,
        MarketUtils.MarketPrices memory prices,
        address referralStorage
    ) private view returns (ReaderUtils.PositionInfo memory) {
        bytes32 positionKey = _getPositionKey(
            positionParams.account, positionParams.marketToken, positionParams.collateralToken, positionParams.isLong
        );
        ReaderUtils.PositionInfo memory positionInfo = IReader(positionParams.reader).getPositionInfo(
            IDataStore(positionParams.dataStore),
            IReferralStorage(referralStorage),
            positionKey,
            prices,
            0,
            address(0),
            true // usePositionSizeAsSizeDeltaUsd meaning when closing fully
        );
        return positionInfo;
    }

    /// @dev returns pnls and token size
    /// Note: pnl is always is realized when decreasing
    function _getPositionPnl(GetPosition calldata positionParams, GetPrices calldata pricesParams, uint256 sizeDeltaUsd)
        private
        view
        returns (int256 positionPnlUsd, int256 uncappedPositionPnlUsd, uint256 sizeDeltaInTokens)
    {
        MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
        bytes32 positionKey = _getPositionKey(
            positionParams.account, positionParams.marketToken, positionParams.collateralToken, positionParams.isLong
        );
        (positionPnlUsd, uncappedPositionPnlUsd, sizeDeltaInTokens) = IReader(positionParams.reader).getPositionPnlUsd(
            IDataStore(positionParams.dataStore), pricesParams.market, prices, positionKey, sizeDeltaUsd
        );
        return (positionPnlUsd, uncappedPositionPnlUsd, sizeDeltaInTokens);
    }

    /// @dev get all prices of maket tokens including long, short, and index tokens
    /// the return type is like the type that is required by gmx
    function _getPrices(address oracle, Market.Props calldata market)
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

    function _getPrice(address oracle, address token) private view returns (Price.Props memory) {
        uint256 tokenPrice = IOracle(oracle).getAssetPrice(token);
        return Price.Props(tokenPrice, tokenPrice);
    }

    function _getPriceImpactUsd(
        Position.Props memory position,
        Price.Props memory indexTokenPrice,
        GetPosition calldata positionParams,
        int256 sizeDeltaUsd
    ) private view returns (int256) {
        ReaderPricingUtils.ExecutionPriceResult memory result = IReader(positionParams.reader).getExecutionPrice(
            IDataStore(positionParams.dataStore),
            positionParams.marketToken,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaUsd,
            positionParams.isLong
        );
        return result.priceImpactUsd;
    }

    function _getMinCollateralAmount(InternalGetMinCollateralAmount memory params) private view returns (uint256) {
        // the min collateral factor will increase as the open interest for a market increases
        // this may lead to previously created limit increase orders not being executable
        //
        // the position's pnl is not factored into the remainingCollateralUsd value, since
        // factoring in a positive pnl may allow the user to manipulate price and bypass this check
        // it may be useful to factor in a negative pnl for this check, this can be added if required
        uint256 minCollateralFactor = MarketUtils.getMinCollateralFactorForOpenInterest(
            IDataStore(params.dataStore), params.market, params.sizeDeltaUsd, params.isLong
        );

        uint256 minCollateralFactorForMarket =
            MarketUtils.getMinCollateralFactor(IDataStore(params.dataStore), params.market.marketToken);
        // use the minCollateralFactor for the market if it is larger
        if (minCollateralFactorForMarket > minCollateralFactor) {
            minCollateralFactor = minCollateralFactorForMarket;
        }

        uint256 minCollateralUsdForLeverage =
            Precision.applyFactor((params.sizeInUsd.toInt256() + params.sizeDeltaUsd).toUint256(), minCollateralFactor);

        return minCollateralUsdForLeverage / params.collateralTokenPrice;
    }
}
