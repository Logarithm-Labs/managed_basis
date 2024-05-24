// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {ArbGasInfo} from "src/externals/arbitrum/ArbGasInfo.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IReader} from "src/externals/gmx-v2/interfaces/IReader.sol";
import {IReferralStorage} from "src/externals/gmx-v2/interfaces/IReferralStorage.sol";

import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {MarketUtils} from "src/externals/gmx-v2/libraries/MarketUtils.sol";
import {Price} from "src/externals/gmx-v2/libraries/Price.sol";
import {Precision} from "src/externals/gmx-v2/libraries/Precision.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";

import {IOracle} from "src/interfaces/IOracle.sol";

import {Errors} from "./Errors.sol";

library GmxV2Lib {
    struct GetPositionNetAmount {
        Market.Props market;
        address dataStore;
        address reader;
        address referralStorage;
        bytes32 positionKey;
        address oracle;
    }

    /// @dev get all prices of maket tokens including long, short, and index tokens
    /// the return type is like the type that is required by gmx
    function getPrices(address oracle, Market.Props memory market)
        internal
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

    /// @dev calculate the total claimable amount in collateral token when closing the whole
    /// Note: collateral + pnlAfterPriceImpactUsd (pnl + price impact) -
    /// total fee costs (funding fee + borrowing fee + position fee) + claimable fundings
    function getPositionNetAmount(GetPositionNetAmount memory params) internal view returns (uint256) {
        MarketUtils.MarketPrices memory prices = getPrices(params.oracle, params.market);
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
            IOracle(params.oracle).getAssetPrice(positionInfo.position.addresses.collateralToken);
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

    function getExecutionFee(address dataStore, uint256 callbackGasLimit) internal view returns (uint256, uint256) {
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
}
