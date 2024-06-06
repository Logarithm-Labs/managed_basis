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
            collateralDelta -= initialCollateralDelta;
            bytes32 positionKey = _getPositionKey(
                positionParams.account,
                positionParams.marketToken,
                positionParams.collateralToken,
                positionParams.isLong
            );
            MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
            (, int256 uncappedPositionPnlUsd,) = IReader(positionParams.reader).getPositionPnlUsd(
                IDataStore(positionParams.dataStore),
                pricesParams.market,
                prices,
                positionKey,
                position.numbers.sizeInUsd
            );
            if (uncappedPositionPnlUsd <= 0) {
                revert Errors.NotPositivePnl();
            }
            uint256 collateralTokenPrice =
                IOracle(pricesParams.oracle).getAssetPrice(position.addresses.collateralToken);
            uint256 uncappedPositionPnlAmountInCollateral = uncappedPositionPnlUsd.toUint256() / collateralTokenPrice;
            sizeDeltaInTokens =
                collateralDelta.mulDiv(position.numbers.sizeInTokens, uncappedPositionPnlAmountInCollateral);

            uint256 sizeDeltaUsd =
                collateralDelta.mulDiv(position.numbers.sizeInUsd, uncappedPositionPnlAmountInCollateral);
            uint256 minCollateralAmount = _getMinCollateralAmount(
                IDataStore(positionParams.dataStore),
                pricesParams.market,
                position.numbers.sizeInUsd,
                -int256(sizeDeltaUsd),
                collateralTokenPrice,
                positionParams.isLong
            );
            if (minCollateralAmount > position.numbers.collateralAmount - initialCollateralDelta) {
                initialCollateralDelta = position.numbers.collateralAmount - minCollateralAmount;
            }
        } else {
            initialCollateralDelta = collateralDelta;
        }
        return (initialCollateralDelta, sizeDeltaInTokens);
    }

    function getPositionInfo(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage
    ) public view returns (ReaderUtils.PositionInfo memory) {
        MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
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

    /// @dev in gmx v2, sizeDeltaInTokens = sizeInTokens * sizeDeltaInUsd / sizeInUsd
    /// hence sizeDeltaInUsd = ceil(sizeDeltaInTokens * sizeInUsd / sizeInTokens)
    function getSizeDeltaInUsdForDecrease(GetPosition calldata params, uint256 sizeDeltaInTokens)
        external
        view
        returns (uint256 sizeDeltaInUsd)
    {
        bytes32 positionKey = _getPositionKey(params.account, params.marketToken, params.collateralToken, params.isLong);
        Position.Props memory position = IReader(params.reader).getPosition(IDataStore(params.dataStore), positionKey);
        sizeDeltaInUsd =
            sizeDeltaInTokens.mulDiv(position.numbers.sizeInUsd, position.numbers.sizeInTokens, Math.Rounding.Ceil);
        return sizeDeltaInUsd;
    }

    /// @dev return position delta size in usd when increasing
    /// considered the price impact
    function getSizeDeltaInUsdForIncrease(
        GetPosition calldata positionParams,
        GetPrices calldata priceParams,
        uint256 sizeDeltaInTokens
    ) external view returns (uint256 sizeDeltaInUsd) {
        MarketUtils.MarketPrices memory prices = _getPrices(priceParams.oracle, priceParams.market);
        Position.Props memory position = IReader(positionParams.reader).getPosition(
            IDataStore(positionParams.dataStore),
            _getPositionKey(
                positionParams.account,
                positionParams.marketToken,
                positionParams.collateralToken,
                positionParams.isLong
            )
        );
        int256 baseSizeDeltaInUsd = sizeDeltaInTokens.toInt256() * prices.indexTokenPrice.max.toInt256();
        ReaderPricingUtils.ExecutionPriceResult memory result = IReader(positionParams.reader).getExecutionPrice(
            IDataStore(positionParams.dataStore),
            positionParams.marketToken,
            prices.indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            baseSizeDeltaInUsd,
            positionParams.isLong
        );
        // in gmx v2
        // int256 sizeDeltaInTokens;
        // if (params.position.isLong()) {
        //     sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() + priceImpactAmount;
        // } else {
        //     sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() - priceImpactAmount;
        // }
        // the resulted actual size delta will be a little bit different from this estimation
        if (positionParams.isLong) {
            sizeDeltaInUsd = (baseSizeDeltaInUsd - result.priceImpactUsd).toUint256();
        } else {
            sizeDeltaInUsd = (baseSizeDeltaInUsd + result.priceImpactUsd).toUint256();
        }
        return sizeDeltaInUsd;
    }

    /// @dev returns remainingCollateral and claimable funding amount in collateral token
    function _getRemainingCollateralAndClaimableFundingAmount(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage
    ) private view returns (uint256, uint256) {
        bytes32 positionKey = _getPositionKey(
            positionParams.account, positionParams.marketToken, positionParams.collateralToken, positionParams.isLong
        );
        MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
        ReaderUtils.PositionInfo memory positionInfo = IReader(positionParams.reader).getPositionInfo(
            IDataStore(positionParams.dataStore),
            IReferralStorage(referralStorage),
            positionKey,
            prices,
            0,
            address(0),
            true // usePositionSizeAsSizeDeltaUsd meaning when closing fully
        );
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

    function _getPosition(GetPosition calldata params) private view returns (Position.Props memory) {
        bytes32 positionKey = _getPositionKey(params.account, params.marketToken, params.collateralToken, params.isLong);
        return IReader(params.reader).getPosition(IDataStore(params.dataStore), positionKey);
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

    function _getMinCollateralAmount(
        IDataStore dataStore,
        Market.Props calldata market,
        uint256 sizeInUsd,
        int256 sizeDeltaUsd,
        uint256 collateralTokenPrice,
        bool isLong
    ) private view returns (uint256) {
        // the min collateral factor will increase as the open interest for a market increases
        // this may lead to previously created limit increase orders not being executable
        //
        // the position's pnl is not factored into the remainingCollateralUsd value, since
        // factoring in a positive pnl may allow the user to manipulate price and bypass this check
        // it may be useful to factor in a negative pnl for this check, this can be added if required
        uint256 minCollateralFactor =
            MarketUtils.getMinCollateralFactorForOpenInterest(dataStore, market, sizeDeltaUsd, isLong);

        uint256 minCollateralFactorForMarket = MarketUtils.getMinCollateralFactor(dataStore, market.marketToken);
        // use the minCollateralFactor for the market if it is larger
        if (minCollateralFactorForMarket > minCollateralFactor) {
            minCollateralFactor = minCollateralFactorForMarket;
        }

        uint256 minCollateralUsdForLeverage =
            Precision.applyFactor((sizeInUsd.toInt256() + sizeDeltaUsd).toUint256(), minCollateralFactor);

        return minCollateralUsdForLeverage / collateralTokenPrice;
    }
}
