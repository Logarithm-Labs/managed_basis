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
import {Errors} from "src/libraries/utils/Errors.sol";
import {Constants} from "src/libraries/utils/Constants.sol";

library GmxV2Lib {
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct GmxParams {
        Market.Props market;
        address dataStore;
        address reader;
        address account;
        address collateralToken;
        bool isLong;
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

    struct DecreasePositionResult {
        /// @dev to determine whether to decrease or increase collateral
        bool isIncreaseCollateral;
        /// @dev amount to decrease or increase
        uint256 initialCollateralDeltaAmount;
        /// @dev the delta usd size to decrease,
        /// if it is bigger than the target, then the difference should be increased again
        uint256 sizeDeltaUsdToDecrease;
        /// @dev the delta usd to increase
        uint256 sizeDeltaUsdToIncrease;
        /// @dev the position fee
        uint256 positionFeeUsd;
        /// @dev the execution price
        uint256 executionPrice;
    }

    function getPositionSizeInTokens(GmxParams calldata params) external view returns (uint256) {
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
    /// @return result DecreasePositionResult
    function getDecreasePositionResult(
        GmxParams calldata params,
        address oracle,
        uint256 sizeDeltaInTokens,
        uint256 collateralDeltaAmount,
        uint256 realizedPnlDiffFactor
    ) external view returns (DecreasePositionResult memory result) {
        Position.Props memory position = _getPosition(params);

        if (sizeDeltaInTokens == type(uint256).max) {
            // in case when requesting full close
            result.sizeDeltaUsdToDecrease = position.numbers.sizeInUsd;
            return result;
        }

        uint256 collateralTokenPrice = IOracle(oracle).getAssetPrice(position.addresses.collateralToken);
        Price.Props memory indexTokenPrice = _getPrice(oracle, params.market.indexToken);
        (int256 totalPositionPnlUsd,,) = _getPositionPnl(params, oracle, position.numbers.sizeInUsd);
        uint256 initialCollateralAmount = position.numbers.collateralAmount;
        ReaderPricingUtils.ExecutionPriceResult memory executionPriceResultForDecrease;

        if (sizeDeltaInTokens > 0) {
            result.sizeDeltaUsdToDecrease = _getSizeDeltaUsdForDecrease(position, sizeDeltaInTokens);
            executionPriceResultForDecrease =
                _getExecutionPrice(params, position, indexTokenPrice, -int256(result.sizeDeltaUsdToDecrease));
            result.positionFeeUsd = _getPositionFeeUsd(
                params, result.sizeDeltaUsdToDecrease, executionPriceResultForDecrease.priceImpactUsd
            );
            result.executionPrice = executionPriceResultForDecrease.executionPrice;
            int256 realizedPnlUsd =
                Precision.mulDiv(totalPositionPnlUsd, sizeDeltaInTokens, position.numbers.sizeInTokens);
            int256 realizedPnlAmount = realizedPnlUsd / collateralTokenPrice.toInt256();

            if (realizedPnlAmount < 0) {
                (, initialCollateralAmount) = initialCollateralAmount.trySub(uint256(-realizedPnlAmount));
            } else {
                // realized pnl by gmx is sometimes different from the expectation due to having offchain oracle
                // and when it is positive, all fees are deducted from the realized pnl, instead of collateral
                // but we need to overshoot the target decreasing delta collateral
                // so make expectation smaller by the realizedPnlDiffFactor
                uint256 realizedPnlAmountAbs = uint256(realizedPnlAmount);
                realizedPnlAmountAbs = realizedPnlAmountAbs.mulDiv(
                    Constants.FLOAT_PRECISION - realizedPnlDiffFactor, Constants.FLOAT_PRECISION
                );

                if (realizedPnlAmountAbs > collateralDeltaAmount) {
                    result.isIncreaseCollateral = true;
                    result.initialCollateralDeltaAmount = realizedPnlAmountAbs - collateralDeltaAmount;
                    return result;
                } else if (realizedPnlAmountAbs == collateralDeltaAmount) {
                    return result;
                } else {
                    collateralDeltaAmount -= realizedPnlAmountAbs;
                }
            }
        }

        // get the delta amount to reduce initial collateral
        result.initialCollateralDeltaAmount = initialCollateralAmount * 9 / 10;
        // if 9/10 of init collateral is bigger than the target
        // then reduce as the target simply
        if (result.initialCollateralDeltaAmount > collateralDeltaAmount) {
            result.initialCollateralDeltaAmount = collateralDeltaAmount;
        }
        uint256 minCollateralAmount = _getMinCollateralAmount(
            InternalGetMinCollateralAmount({
                market: params.market,
                dataStore: params.dataStore,
                sizeInUsd: position.numbers.sizeInUsd > result.sizeDeltaUsdToDecrease
                    ? position.numbers.sizeInUsd - result.sizeDeltaUsdToDecrease
                    : 0,
                sizeDeltaUsd: -result.sizeDeltaUsdToDecrease.toInt256(),
                collateralTokenPrice: collateralTokenPrice,
                isLong: params.isLong
            })
        );
        // if the remaining collateral is smaller than the minimum requirements by gmx
        // then modify init collateral delta so that it can satisfy the requirement
        if (minCollateralAmount > initialCollateralAmount - result.initialCollateralDeltaAmount) {
            result.initialCollateralDeltaAmount = initialCollateralAmount - minCollateralAmount;
        }

        // if the target collateral delta is still bigger than the init collateral reduction
        // then reduce the size to realized positive pnl, this size will be reverted back later
        // Note: with regard to minimum collateral requirement,
        //       if the above is satisfied, then all is ok because the reverted sizeUsd will be smaller than original
        // if negative pnl, then revert
        if (collateralDeltaAmount > result.initialCollateralDeltaAmount && totalPositionPnlUsd > 0) {
            // fill the reducing collateral with realized pnl
            collateralDeltaAmount -= result.initialCollateralDeltaAmount;
            uint256 totalPositionPnlAmount = totalPositionPnlUsd.toUint256() / collateralTokenPrice;
            if (totalPositionPnlAmount <= collateralDeltaAmount) {
                revert Errors.NotEnoughPnl();
            }
            uint256 sizeDeltaInTokensToBeRealized =
                collateralDeltaAmount.mulDiv(position.numbers.sizeInTokens, totalPositionPnlAmount);
            // make sizeDeltaInTokensToBeRealized bigger by the diff factor,
            // so that we can guarrantee that the decreased collateral overshoots the request
            sizeDeltaInTokensToBeRealized = sizeDeltaInTokensToBeRealized.mulDiv(
                Constants.FLOAT_PRECISION + realizedPnlDiffFactor, Constants.FLOAT_PRECISION
            );
            result.sizeDeltaUsdToDecrease += _getSizeDeltaUsdForDecrease(position, sizeDeltaInTokensToBeRealized);
            executionPriceResultForDecrease =
                _getExecutionPrice(params, position, indexTokenPrice, -int256(result.sizeDeltaUsdToDecrease));
            result.positionFeeUsd = _getPositionFeeUsd(
                params, result.sizeDeltaUsdToDecrease, executionPriceResultForDecrease.priceImpactUsd
            );
            result.sizeDeltaUsdToIncrease = _getSizeDeltaUsdForIncrease(
                params,
                indexTokenPrice,
                position.numbers.sizeInUsd,
                position.numbers.sizeInTokens,
                sizeDeltaInTokensToBeRealized
            );
            ReaderPricingUtils.ExecutionPriceResult memory executionPriceResultForIncrease =
                _getExecutionPrice(params, position, indexTokenPrice, int256(result.sizeDeltaUsdToIncrease));
            result.positionFeeUsd += _getPositionFeeUsd(
                params, result.sizeDeltaUsdToIncrease, executionPriceResultForIncrease.priceImpactUsd
            );
            if (sizeDeltaInTokens > 0) {
                result.executionPrice = (
                    executionPriceResultForDecrease.executionPrice * (sizeDeltaInTokens + sizeDeltaInTokensToBeRealized)
                        - executionPriceResultForIncrease.executionPrice * sizeDeltaInTokensToBeRealized
                ) / sizeDeltaInTokens;
            }
        }

        if (result.sizeDeltaUsdToDecrease >= position.numbers.sizeInUsd) {
            result.sizeDeltaUsdToDecrease = position.numbers.sizeInUsd;
            result.sizeDeltaUsdToIncrease = 0;
            result.initialCollateralDeltaAmount = 0;
        }
        return result;
    }

    /// @dev position info when closing fully
    function getPositionInfo(GmxParams calldata params, address oracle, address referralStorage)
        external
        view
        returns (ReaderUtils.PositionInfo memory)
    {
        MarketUtils.MarketPrices memory prices = _getPrices(oracle, params.market);
        return _getPositionInfo(params, prices, referralStorage);
    }

    function getSizeDeltaUsdForDecrease(GmxParams calldata params, uint256 sizeDeltaInTokens)
        external
        view
        returns (uint256)
    {
        Position.Props memory position = _getPosition(params);
        uint256 sizeDeltaUsd = _getSizeDeltaUsdForDecrease(position, sizeDeltaInTokens);
        return sizeDeltaUsd;
    }

    function getSizeDeltaUsdForIncrease(GmxParams calldata params, address oracle, uint256 sizeDeltaInTokens)
        external
        view
        returns (uint256)
    {
        Price.Props memory indexTokenPrice = _getPrice(oracle, params.market.indexToken);
        Position.Props memory position = _getPosition(params);
        uint256 sizeDeltaUsd = _getSizeDeltaUsdForIncrease(
            params, indexTokenPrice, position.numbers.sizeInUsd, position.numbers.sizeInTokens, sizeDeltaInTokens
        );
        return sizeDeltaUsd;
    }

    /// @dev returns transaction fees needed for gmx keeper
    function getExecutionFee(address dataStore, uint256 callbackGasLimit) external view returns (uint256, uint256) {
        uint256 estimatedGasLimitIncrease = IDataStore(dataStore).getUint(Keys.INCREASE_ORDER_GAS_LIMIT);
        uint256 estimatedGasLimitDecrease = IDataStore(dataStore).getUint(Keys.DECREASE_ORDER_GAS_LIMIT);
        estimatedGasLimitIncrease += callbackGasLimit;
        estimatedGasLimitDecrease += callbackGasLimit;
        uint256 baseGasLimit = IDataStore(dataStore).getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1);
        baseGasLimit += IDataStore(dataStore).getUint(Keys.ESTIMATED_GAS_FEE_PER_ORACLE_PRICE) * 3;
        uint256 multiplierFactor = IDataStore(dataStore).getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimitIncrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitIncrease, multiplierFactor);
        uint256 gasLimitDecrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitDecrease, multiplierFactor);
        uint256 gasPrice = tx.gasprice;
        if (gasPrice == 0) {
            gasPrice = ArbGasInfo(0x000000000000000000000000000000000000006C).getMinimumGasPrice();
        }
        return (gasPrice * gasLimitIncrease, gasPrice * gasLimitDecrease);
    }

    /// @dev return the funding amounts received
    function getAccruedFundingAmounts(GmxParams calldata params)
        public
        view
        returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount)
    {
        claimableLongTokenAmount = _getAccruedFundingAmount(
            params.dataStore, params.market.marketToken, params.market.longToken, params.account
        );
        claimableShortTokenAmount = _getAccruedFundingAmount(
            params.dataStore, params.market.marketToken, params.market.shortToken, params.account
        );
        return (claimableLongTokenAmount, claimableShortTokenAmount);
    }

    /// @dev current leverage that is calculated by gmx
    function getCurrentLeverage(GmxParams calldata params, address oracle, address referralStorage)
        external
        view
        returns (uint256)
    {
        uint256 positionSizeInUsd = _getPosition(params).numbers.sizeInUsd;
        if (positionSizeInUsd == 0) return 0;

        (uint256 remainingCollateral,) =
            getRemainingCollateralAndClaimableFundingAmount(params, oracle, referralStorage);
        uint256 collateralTokenPrice = IOracle(oracle).getAssetPrice(params.collateralToken);
        uint256 remainingCollateralUsd = remainingCollateral * collateralTokenPrice;

        if (remainingCollateralUsd == 0) return type(uint256).max;

        return positionSizeInUsd.mulDiv(Constants.FLOAT_PRECISION, remainingCollateralUsd);
    }

    /// @dev returns remainingCollateral and claimable funding amount in collateral token
    function getRemainingCollateralAndClaimableFundingAmount(
        GmxParams calldata params,
        address oracle,
        address referralStorage
    ) public view returns (uint256, uint256) {
        MarketUtils.MarketPrices memory prices = _getPrices(oracle, params.market);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(params, prices, referralStorage);

        if (positionInfo.position.addresses.collateralToken == address(0)) {
            // no position opened
            return (0, 0);
        }

        uint256 collateralTokenPrice = IOracle(oracle).getAssetPrice(positionInfo.position.addresses.collateralToken);
        uint256 claimableUsd = positionInfo.fees.funding.claimableLongTokenAmount * prices.longTokenPrice.min
            + positionInfo.fees.funding.claimableShortTokenAmount * prices.shortTokenPrice.min;
        uint256 claimableTokenAmount = claimableUsd / collateralTokenPrice;

        int256 priceImpactUsd = positionInfo.executionPriceResult.priceImpactUsd;

        // even if there is a large positive price impact, positions that would be liquidated
        // if the positive price impact is reduced should not be allowed to be created
        // as they would be easily liquidated if the price impact changes
        // cap the priceImpactUsd to zero to prevent these positions from being created
        if (priceImpactUsd >= 0) {
            priceImpactUsd = 0;
        } else {
            uint256 maxPriceImpactFactor = MarketUtils.getMaxPositionImpactFactorForLiquidations(
                IDataStore(params.dataStore), params.market.marketToken
            );

            // if there is a large build up of open interest and a sudden large price movement
            // it may result in a large imbalance between longs and shorts
            // this could result in very large price impact temporarily
            // cap the max negative price impact to prevent cascading liquidations
            int256 maxNegativePriceImpactUsd =
                -Precision.applyFactor(positionInfo.position.numbers.sizeInUsd, maxPriceImpactFactor).toInt256();
            if (priceImpactUsd < maxNegativePriceImpactUsd) {
                priceImpactUsd = maxNegativePriceImpactUsd;
            }
        }

        int256 remainingCollateral = positionInfo.position.numbers.collateralAmount.toInt256()
            + (positionInfo.basePnlUsd + priceImpactUsd) / collateralTokenPrice.toInt256()
            - positionInfo.fees.totalCostAmount.toInt256();

        return (remainingCollateral > 0 ? remainingCollateral.toUint256() : 0, claimableTokenAmount);
    }

    function getClaimableFundingAmounts(GmxParams calldata params, address oracle, address referralStorage)
        external
        view
        returns (uint256 claimableLongTokenAmount, uint256 claimableShortTokenAmount)
    {
        MarketUtils.MarketPrices memory prices = _getPrices(oracle, params.market);
        ReaderUtils.PositionInfo memory positionInfo = _getPositionInfo(params, prices, referralStorage);
        claimableLongTokenAmount = positionInfo.fees.funding.claimableLongTokenAmount;
        claimableShortTokenAmount = positionInfo.fees.funding.claimableShortTokenAmount;
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
        GmxParams calldata params,
        Price.Props memory indexTokenPrice,
        uint256 sizeInUsd,
        uint256 sizeInTokens,
        uint256 sizeDeltaInTokens
    ) private view returns (uint256) {
        int256 baseSizeDeltaUsd = sizeDeltaInTokens.toInt256() * indexTokenPrice.max.toInt256();
        ReaderPricingUtils.ExecutionPriceResult memory result = IReader(params.reader).getExecutionPrice(
            IDataStore(params.dataStore),
            params.market.marketToken,
            indexTokenPrice,
            sizeInUsd,
            sizeInTokens,
            baseSizeDeltaUsd,
            params.isLong
        );
        uint256 sizeDeltaUsd;
        // in gmx v2
        // int256 sizeDeltaInTokens;
        // if (params.position.isLong()) {
        //     sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() + priceImpactAmount;
        // } else {
        //     sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() - priceImpactAmount;
        // }
        // the resulted actual size delta will be a little bit different from this estimation
        if (params.isLong) {
            sizeDeltaUsd = (baseSizeDeltaUsd - result.priceImpactUsd).toUint256();
        } else {
            sizeDeltaUsd = (baseSizeDeltaUsd + result.priceImpactUsd).toUint256();
        }
        return sizeDeltaUsd;
    }

    // @dev calculate the position fee in usd when changing position size
    function _getPositionFeeUsd(GmxParams calldata params, uint256 sizeDeltaUsd, int256 priceImpactUsd)
        private
        view
        returns (uint256)
    {
        bool forPositiveImpact = priceImpactUsd > 0;
        uint256 positionFeeFactor = IDataStore(params.dataStore).getUint(
            Keys.positionFeeFactorKey(params.market.marketToken, forPositiveImpact)
        );
        uint256 positionFeeUsd = Precision.applyFactor(sizeDeltaUsd, positionFeeFactor);
        return positionFeeUsd;
    }

    function _getPositionKey(address account, address marketToken, address collateralToken, bool isLong)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(account, marketToken, collateralToken, isLong));
    }

    /// @dev get position properties that are invariants
    function _getPosition(GmxParams calldata params) private view returns (Position.Props memory) {
        bytes32 positionKey =
            _getPositionKey(params.account, params.market.marketToken, params.collateralToken, params.isLong);
        return IReader(params.reader).getPosition(IDataStore(params.dataStore), positionKey);
    }

    /// @dev get position info including propeties and realizing pnl and fees and price impact
    /// Note: providing info when closing the whole position
    function _getPositionInfo(
        GmxParams calldata params,
        MarketUtils.MarketPrices memory prices,
        address referralStorage
    ) private view returns (ReaderUtils.PositionInfo memory) {
        ReaderUtils.PositionInfo memory positionInfo;

        bytes32 positionKey =
            _getPositionKey(params.account, params.market.marketToken, params.collateralToken, params.isLong);
        Position.Props memory position = IReader(params.reader).getPosition(IDataStore(params.dataStore), positionKey);
        if (position.numbers.sizeInUsd == 0) {
            return positionInfo;
        }

        positionInfo = IReader(params.reader).getPositionInfo(
            IDataStore(params.dataStore),
            IReferralStorage(referralStorage),
            positionKey,
            prices,
            0,
            address(0),
            true // usePositionSizeAsSizeDeltaUsd meaning when closing fully
        );
        return positionInfo;
    }

    /// @dev return received founding amount given a token
    function _getAccruedFundingAmount(address dataStore, address market, address token, address account)
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
    function _getPositionPnl(GmxParams calldata params, address oracle, uint256 sizeDeltaUsd)
        private
        view
        returns (int256 positionPnlUsd, int256 uncappedPositionPnlUsd, uint256 sizeDeltaInTokens)
    {
        MarketUtils.MarketPrices memory prices = _getPrices(oracle, params.market);
        bytes32 positionKey =
            _getPositionKey(params.account, params.market.marketToken, params.collateralToken, params.isLong);
        (positionPnlUsd, uncappedPositionPnlUsd, sizeDeltaInTokens) = IReader(params.reader).getPositionPnlUsd(
            IDataStore(params.dataStore), params.market, prices, positionKey, sizeDeltaUsd
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
        GmxParams calldata params,
        Price.Props memory indexTokenPrice,
        uint256 sizeInUsd,
        uint256 sizeInTokens,
        int256 sizeDeltaUsd
    ) private view returns (int256) {
        ReaderPricingUtils.ExecutionPriceResult memory result = IReader(params.reader).getExecutionPrice(
            IDataStore(params.dataStore),
            params.market.marketToken,
            indexTokenPrice,
            sizeInUsd,
            sizeInTokens,
            sizeDeltaUsd,
            params.isLong
        );
        return result.priceImpactUsd;
    }

    function _getExecutionPrice(
        GmxParams calldata params,
        Position.Props memory position,
        Price.Props memory indexTokenPrice,
        int256 sizeDeltaUsd
    ) private view returns (ReaderPricingUtils.ExecutionPriceResult memory) {
        return IReader(params.reader).getExecutionPrice(
            IDataStore(params.dataStore),
            params.market.marketToken,
            indexTokenPrice,
            position.numbers.sizeInUsd,
            position.numbers.sizeInTokens,
            sizeDeltaUsd,
            params.isLong
        );
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
