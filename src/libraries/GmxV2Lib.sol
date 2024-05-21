// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {ArbGasInfo} from "src/externals/arbitrum/ArbGasInfo.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {IReferralStorage} from "src/externals/gmx-v2/interfaces/IReferralStorage.sol";

import {Chain} from "src/externals/gmx-v2/libraries/Chain.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {MarketUtils} from "src/externals/gmx-v2/libraries/MarketUtils.sol";
import {Position} from "src/externals/gmx-v2/libraries/Position.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {Price} from "src/externals/gmx-v2/libraries/Price.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";

import {Errors} from "./Errors.sol";

library GmxV2Lib {
    struct GetPositionNetAmount {
        Market.Props market;
        address dataStore;
        address reader;
        address referralStorage;
        bytes32 positionKey;
    }
    /// @dev returns token price in (30 - decimal of token)
    /// so that the usd value of token has 30 decimals
    /// for example, if usdc has 6 decimals, then this returns its price in 30 - 6 = 24 decimals

    function getPriceFeedPrice(IDataStore dataStore, address token) internal view returns (uint256) {
        address priceFeedAddress = dataStore.getAddress(Keys.priceFeedKey(token));
        if (priceFeedAddress == address(0)) {
            revert Errors.PriceFeedNotConfigured();
        }

        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);

        (
            /* uint80 roundID */
            ,
            int256 _price,
            /* uint256 startedAt */
            ,
            uint256 timestamp,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        if (_price <= 0) {
            revert Errors.InvalidFeedPrice(token, _price);
        }

        // in case chainlink price feeds are not updated
        uint256 heartbeatDuration = dataStore.getUint(Keys.priceFeedHeartbeatDurationKey(token));
        if (Chain.currentTimestamp() > timestamp && Chain.currentTimestamp() - timestamp > heartbeatDuration) {
            revert Errors.PriceFeedNotUpdated(token, timestamp, heartbeatDuration);
        }

        uint256 price = SafeCast.toUint256(_price);

        uint256 precision = dataStore.getUint(Keys.priceFeedMultiplierKey(token));

        if (precision == 0) {
            revert Errors.EmptyPriceFeedMultiplier(token);
        }

        uint256 adjustedPrice = Precision.mulDiv(price, precision, Precision.FLOAT_PRECISION);

        return adjustedPrice;
    }

    /// @dev get all prices of maket tokens including long, short, and index tokens
    /// the return type is like the type that is required by gmx
    function getPrices(IDataStore dataStore, Market.Props memory market)
        internal
        view
        returns (MarketUtils.MarketPrices memory prices)
    {
        uint256 longTokenPrice = getPriceFeedPrice(dataStore, market.longToken);
        uint256 shortTokenPrice = getPriceFeedPrice(dataStore, market.shortToken);
        uint256 indexTokenPrice = getPriceFeedPrice(dataStore, market.indexToken);
        indexTokenPrice = indexTokenPrice == 0 ? longTokenPrice : indexTokenPrice;

        prices.indexTokenPrice = Price.Props(indexTokenPrice, indexTokenPrice);
        prices.longTokenPrice = Price.Props(longTokenPrice, longTokenPrice);
        prices.shortTokenPrice = Price.Props(shortTokenPrice, shortTokenPrice);
    }
    /// @dev calculate the total claimable amount in collateral token when closing the whole
    /// Note: collateral + pnlAfterPriceImpactUsd (pnl + price impact) -
    /// total fee costs (funding fee + borrowing fee + position fee) + claimable fundings

    function getPositionNetAmount(GetPositionNetAmount memory params) internal view returns (uint256) {
        MarketUtils.MarketPrices memory prices = getPrices(IDataStore(params.dataStore), params.market);
        ReaderUtils.PositionInfo memory positionInfo = IReader(params.reader).getPositionInfo(
            IDataStore(params.dataStore),
            IReferralStorage(params.referralStorage),
            params.positionKey,
            prices,
            0,
            address(0),
            true // usePositionSizeAsSizeDeltaUsd meaning when closing fully
        );
        uint256 collateralTokenPrice =
            getPriceFeedPrice(IDataStore(params.dataStore), positionInfo.position.addresses.collateralToken);
        uint256 claimableUsd = positionInfo.fees.funding.claimableLongTokenAmount * prices.longTokenPrice.min
            + positionInfo.fees.funding.claimableShortTokenAmount * prices.shortTokenPrice.min;
        uint256 claimableTokenAmount = claimableUsd / collateralTokenPrice;

        if (positionInfo.pnlAfterPriceImpactUsd < 0) {
            return positionInfo.position.numbers.collateralAmount - positionInfo.fees.totalCostAmount
                - SafeCast.toUint256(-positionInfo.pnlAfterPriceImpactUsd) / collateralTokenPrice + claimableTokenAmount;
        } else {
            return positionInfo.position.numbers.collateralAmount
                + SafeCast.toUint256(positionInfo.pnlAfterPriceImpactUsd) / collateralTokenPrice
                - positionInfo.fees.totalCostAmount + claimableTokenAmount;
        }
    }

    function getPositionKey(address account, address marketToken, address collateralToken, bool isLong)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(account, marketToken, collateralToken, isLong));
    }

    function getExecutionFee(IDataStore dataStore, uint256 callbackGasLimit) internal view returns (uint256, uint256) {
        uint256 estimatedGasLimitIncrease = dataStore.getUint(Keys.increaseOrderGasLimitKey());
        uint256 estimatedGasLimitDecrease = dataStore.getUint(Keys.decreaseOrderGasLimitKey());
        estimatedGasLimitIncrease += callbackGasLimit;
        estimatedGasLimitDecrease += callbackGasLimit;
        uint256 baseGasLimit = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimitIncrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitIncrease, multiplierFactor);
        uint256 gasLimitDecrease = baseGasLimit + Precision.applyFactor(estimatedGasLimitDecrease, multiplierFactor);
        uint256 gasPrice = tx.gasprice;
        if (gasPrice == 0) {
            gasPrice = ArbGasInfo(0x000000000000000000000000000000000000006C).getMinimumGasPrice();
        }
        return (gasPrice * gasLimitIncrease, gasPrice * gasLimitDecrease);
    }
}
