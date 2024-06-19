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
        /// @dev resulted size after execution
        uint256 sizeInUsd;
        /// @dev positive means increase, negative means decrease
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

    /// @dev reduce collateral and position size in tokens
    /// 1. decrease size
    /// 2. if positive pnl, check realized pnl
    /// 2.1 if realized positive pnl is bigger than the target delta collateral to decrease
    ///     increase the init collateral by the remaining delta amount
    /// 2.2 if the realized positive pnl is the same as the target
    ///     simply decrease the size
    /// 2.3 if the realized positive pnl is smaller than the target
    ///     decrease collateral substracted by the pnl
    /// 2.3.1 if the delta collateral to decrease is bigger than 9/10 of init collateral or minimum requirement
    ///       decrease the position size to fill the remainint amount with realized pnl and increase the size back
    /// 2.3.2 if the delta collateral to decrease is same or smaller
    ///       simply decrease init callateral
    /// 3. if negative pnl, check the delta collateral to decrease with the remaining collateral substracted by the realized negative pnl
    /// 3.1 if the delta collateral is equal or smaller so that the remaining is bigger than minium requirement
    ///     decrease the delta collateral
    /// 3.2 if the delta collateral is bigger
    ///     revert
    /// Note: there are 3 types of operations
    /// 1. decreasePosition (initCollateralDelta1, deltaSize1)
    /// 1. decreasePosition (initCollateralDelta1, deltaSize1) and increasePosition(0, deltaSize2)
    /// 3. decreasePosition (0, delta size) and increasePosition(initCollateralDelta, 0)
    ///
    /// @return isIncreaseCollateral is to determine whether to decrease or increase collateral
    /// @return initialCollateralDeltaAmount is amount to decrease or increase
    /// @return sizeDeltaUsdToDecrease is the delta usd size to decrease,
    ///         if it is bigger than the target, then the difference should be increased again
    /// @return sizeDeltaUsdToIncrease is the delta usd to increase
    /// @return positionFeeUsd is the position fee
    function getDecreasePositionResult(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 sizeDeltaInTokens,
        uint256 collateralDeltaAmount
    )
        external
        view
        returns (
            bool isIncreaseCollateral,
            uint256 initialCollateralDeltaAmount,
            uint256 sizeDeltaUsdToDecrease,
            uint256 sizeDeltaUsdToIncrease,
            uint256 positionFeeUsd
        )
    {
        Position.Props memory position = _getPosition(positionParams);
        uint256 collateralTokenPrice = IOracle(pricesParams.oracle).getAssetPrice(position.addresses.collateralToken);
        Price.Props memory indexTokenPrice = _getPrice(pricesParams.oracle, pricesParams.market.indexToken);
        sizeDeltaUsdToDecrease = _getSizeDeltaUsdForDecrease(position, sizeDeltaInTokens);
        positionFeeUsd = _getPositionFeeUsd(
            positionParams,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaUsdToDecrease,
            false
        );
        (int256 totalPositionPnlUsd,,) = _getPositionPnl(positionParams, pricesParams, position.numbers.sizeInUsd);
        int256 realizedPnlUsd = Precision.mulDiv(totalPositionPnlUsd, sizeDeltaInTokens, position.numbers.sizeInTokens);
        int256 realizedPnlAmount = realizedPnlUsd / collateralTokenPrice.toInt256();
        uint256 initialCollateralAmount = position.numbers.collateralAmount;

        if (realizedPnlAmount < 0) {
            initialCollateralAmount -= uint256(-realizedPnlAmount);
        } else if (uint256(realizedPnlAmount) > collateralDeltaAmount) {
            isIncreaseCollateral = true;
            initialCollateralDeltaAmount = uint256(realizedPnlAmount) - collateralDeltaAmount;
            return (
                isIncreaseCollateral,
                initialCollateralDeltaAmount,
                sizeDeltaUsdToDecrease,
                sizeDeltaUsdToIncrease,
                positionFeeUsd
            );
        } else if (uint256(realizedPnlAmount) == collateralDeltaAmount) {
            return (
                isIncreaseCollateral,
                initialCollateralDeltaAmount,
                sizeDeltaUsdToDecrease,
                sizeDeltaUsdToIncrease,
                positionFeeUsd
            );
        } else {
            collateralDeltaAmount -= uint256(realizedPnlAmount);
        }

        // get the delta amount to reduce initial collateral
        initialCollateralDeltaAmount = initialCollateralAmount * 9 / 10;
        // if 9/10 of init collateral is bigger than the target
        // then reduce as the target simply
        if (initialCollateralDeltaAmount > collateralDeltaAmount) {
            initialCollateralDeltaAmount = collateralDeltaAmount;
        }
        uint256 minCollateralAmount = _getMinCollateralAmount(
            InternalGetMinCollateralAmount({
                market: pricesParams.market,
                dataStore: positionParams.dataStore,
                sizeInUsd: position.numbers.sizeInUsd - sizeDeltaUsdToDecrease,
                sizeDeltaUsd: -sizeDeltaUsdToDecrease.toInt256(),
                collateralTokenPrice: collateralTokenPrice,
                isLong: positionParams.isLong
            })
        );
        // if the remaining collateral is smaller than the minimum requirements by gmx
        // then modify init collateral delta so that it can satisfy the requirement
        if (minCollateralAmount > initialCollateralAmount - initialCollateralDeltaAmount) {
            initialCollateralDeltaAmount = initialCollateralAmount - minCollateralAmount;
        }

        // if the target collateral delta is still bigger than the init collateral reduction
        // then reduce the size to realized positive pnl, this size will be reverted back later
        // Note: with regard to minimum collateral requirement,
        //       if the above is satisfied, then all is ok because the reverted sizeUsd will be smaller than original
        // if negative pnl, then revert
        if (collateralDeltaAmount > initialCollateralDeltaAmount) {
            // fill the reducing collateral with realized pnl
            collateralDeltaAmount -= initialCollateralDeltaAmount;
            if (totalPositionPnlUsd <= collateralDeltaAmount.toInt256()) {
                revert Errors.NotEnoughPnl();
            }
            uint256 totalPositionPnlAmount = totalPositionPnlUsd.toUint256() / collateralTokenPrice;
            uint256 sizeDeltaInTokensToBeRealized =
                collateralDeltaAmount.mulDiv(position.numbers.sizeInTokens, totalPositionPnlAmount);
            sizeDeltaUsdToDecrease += _getSizeDeltaUsdForDecrease(position, sizeDeltaInTokensToBeRealized);
            positionFeeUsd = _getPositionFeeUsd(
                positionParams,
                indexTokenPrice,
                position.numbers.sizeInUsd,
                position.numbers.sizeInTokens,
                sizeDeltaUsdToDecrease,
                false
            );
            sizeDeltaUsdToIncrease = _getSizeDeltaUsdForIncrease(
                positionParams,
                indexTokenPrice,
                position.numbers.sizeInUsd,
                position.numbers.sizeInTokens,
                sizeDeltaInTokensToBeRealized
            );
            positionFeeUsd += _getPositionFeeUsd(
                positionParams,
                indexTokenPrice,
                position.numbers.sizeInUsd,
                position.numbers.sizeInTokens,
                sizeDeltaUsdToIncrease,
                true
            );
        }
        return (
            isIncreaseCollateral,
            initialCollateralDeltaAmount,
            sizeDeltaUsdToDecrease,
            sizeDeltaUsdToIncrease,
            positionFeeUsd
        );
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

    function getSizeDeltaUsdForDecrease(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 sizeDeltaInTokens
    ) external view returns (uint256 sizeDeltaUsd, uint256 positionFeeUsd) {
        Price.Props memory indexTokenPrice = _getPrice(pricesParams.oracle, pricesParams.market.indexToken);
        Position.Props memory position = _getPosition(positionParams);
        sizeDeltaUsd = _getSizeDeltaUsdForDecrease(position, sizeDeltaInTokens);
        positionFeeUsd = _getPositionFeeUsd(
            positionParams,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaUsd,
            false
        );
        return (sizeDeltaUsd, positionFeeUsd);
    }

    function getSizeDeltaUsdForIncrease(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 sizeDeltaInTokens
    ) external view returns (uint256 sizeDeltaUsd, uint256 positionFeeUsd) {
        Price.Props memory indexTokenPrice = _getPrice(pricesParams.oracle, pricesParams.market.indexToken);
        Position.Props memory position = _getPosition(positionParams);
        sizeDeltaUsd = _getSizeDeltaUsdForIncrease(
            positionParams,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaInTokens
        );
        positionFeeUsd = _getPositionFeeUsd(
            positionParams,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaUsd,
            true
        );
        return (sizeDeltaUsd, positionFeeUsd);
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

    function getPositionFeeUsd(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 sizeDeltaUsd,
        bool isIncrease
    ) external view returns (uint256) {
        Position.Props memory position = _getPosition(positionParams);
        Price.Props memory indexTokenPrice = _getPrice(pricesParams.oracle, pricesParams.market.indexToken);
        return _getPositionFeeUsd(
            positionParams,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaUsd,
            isIncrease
        );
    }

    function getClaimableFundingAmounts(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        address referralStorage
    ) external view returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount) {
        MarketUtils.MarketPrices memory prices = _getPrices(pricesParams.oracle, pricesParams.market);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(positionParams, prices, referralStorage);
        (claimableLongTokenAmount, claimableShortTokenAmount) = _getClaimableFundingAmounts(
            positionParams,
            pricesParams,
            positionInfo.fees.funding.claimableLongTokenAmount,
            positionInfo.fees.funding.claimableShortTokenAmount
        );
        return (claimableLongTokenAmount, claimableShortTokenAmount);
    }

    /// @dev in gmx v2, sizeDeltaInTokens = sizeInTokens * sizeDeltaUsd / sizeInUsd
    /// hence sizeDeltaUsd = ceil(sizeDeltaInTokens * sizeInUsd / sizeInTokens)
    function _getSizeDeltaUsdForDecrease(Position.Props memory position, uint256 sizeDeltaInTokens)
        private
        pure
        returns (uint256)
    {
        return sizeDeltaInTokens.mulDiv(position.numbers.sizeInUsd, position.numbers.sizeInTokens, Math.Rounding.Ceil);
    }

    /// @dev return position delta size in usd when increasing
    /// considered the price impact
    function _getSizeDeltaUsdForIncrease(
        GetPosition calldata positionParams,
        Price.Props memory indexTokenPrice,
        uint256 sizeInUsd,
        uint256 sizeInTokens,
        uint256 sizeDeltaInTokens
    ) private view returns (uint256) {
        int256 baseSizeDeltaUsd = sizeDeltaInTokens.toInt256() * indexTokenPrice.max.toInt256();
        int256 priceImpactUsd =
            _getPriceImpactUsd(positionParams, indexTokenPrice, sizeInUsd, sizeInTokens, baseSizeDeltaUsd);
        uint256 sizeDeltaUsd;
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

    // @dev calculate the position fee in usd when changing position size
    function _getPositionFeeUsd(
        GetPosition calldata positionParams,
        Price.Props memory indexTokenPrice,
        uint256 sizeInUsd,
        uint256 sizeInTokens,
        uint256 sizeDeltaUsd,
        bool isIncrease
    ) private view returns (uint256) {
        int256 priceImpactUsd = _getPriceImpactUsd(
            positionParams,
            indexTokenPrice,
            sizeInUsd,
            sizeInTokens,
            isIncrease ? int256(sizeDeltaUsd) : -int256(sizeDeltaUsd)
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
        (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount) = _getClaimableFundingAmounts(
            positionParams,
            pricesParams,
            positionInfo.fees.funding.claimableLongTokenAmount,
            positionInfo.fees.funding.claimableShortTokenAmount
        );
        uint256 claimableUsd = claimableLongTokenAmount * prices.longTokenPrice.min
            + claimableShortTokenAmount * prices.shortTokenPrice.min;
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

    /// @dev return claimable token amount + next claimable token amount
    function _getClaimableFundingAmounts(
        GetPosition calldata positionParams,
        GetPrices calldata pricesParams,
        uint256 nextClaimableLongTokenAmount,
        uint256 nextClaimableShortTokenAmount
    ) private view returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount) {
        claimableLongTokenAmount = _getStoredClaimableFundingAmount(
            positionParams.dataStore, positionParams.marketToken, pricesParams.market.longToken, positionParams.account
        );
        claimableShortTokenAmount = _getStoredClaimableFundingAmount(
            positionParams.dataStore, positionParams.marketToken, pricesParams.market.shortToken, positionParams.account
        );

        claimableLongTokenAmount += nextClaimableLongTokenAmount;
        claimableShortTokenAmount += nextClaimableShortTokenAmount;

        return (claimableLongTokenAmount, claimableShortTokenAmount);
    }

    /// @dev return claimable token amount that is actually claimable
    function _getStoredClaimableFundingAmount(address dataStore, address market, address token, address account)
        private
        view
        returns (uint256)
    {
        bytes32 key = Keys.claimableFundingAmountKey(market, token, account);
        uint256 claimableAmount = IDataStore(dataStore).getUint(key);
        return claimableAmount;
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
        GetPosition calldata positionParams,
        Price.Props memory indexTokenPrice,
        uint256 sizeInUsd,
        uint256 sizeInTokens,
        int256 sizeDeltaUsd
    ) private view returns (int256) {
        ReaderPricingUtils.ExecutionPriceResult memory result = IReader(positionParams.reader).getExecutionPrice(
            IDataStore(positionParams.dataStore),
            positionParams.marketToken,
            indexTokenPrice,
            sizeInUsd,
            sizeInTokens,
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
        // params.sizeInUsd should be resulted size
        uint256 minCollateralUsdForLeverage = Precision.applyFactor(params.sizeInUsd, minCollateralFactor);
        // the oracle price that gmx uses is a real time, which has a little deviation with the onchain oracle
        // so make the minimum one bigger by 5%
        return (minCollateralUsdForLeverage / params.collateralTokenPrice) * 21 / 20;
    }
}
