// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

// @title Keys
// @dev Keys for values in the DataStore
library Keys {
    // @dev key for the base gas limit used when estimating execution fee
    bytes32 public constant ESTIMATED_GAS_FEE_BASE_AMOUNT = keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT"));
    // @dev key for the base gas limit used when estimating execution fee
    bytes32 public constant ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1 =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    bytes32 public constant MAX_CALLBACK_GAS_LIMIT = keccak256(abi.encode("MAX_CALLBACK_GAS_LIMIT"));

    // @dev key for the multiplier used when estimating execution fee
    bytes32 public constant ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    // @dev key for the estimated gas limit for increase orders
    bytes32 public constant INCREASE_ORDER_GAS_LIMIT = keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    // @dev key for the estimated gas limit for decrease orders
    bytes32 public constant DECREASE_ORDER_GAS_LIMIT = keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));
    // @dev key for the max position impact factor for liquidations
    bytes32 public constant MAX_POSITION_IMPACT_FACTOR_FOR_LIQUIDATIONS =
        keccak256(abi.encode("MAX_POSITION_IMPACT_FACTOR_FOR_LIQUIDATIONS"));
    // @dev key for the position fee factor
    bytes32 internal constant POSITION_FEE_FACTOR = keccak256(abi.encode("POSITION_FEE_FACTOR"));

    // @dev key for the min collateral factor
    bytes32 public constant MIN_COLLATERAL_FACTOR = keccak256(abi.encode("MIN_COLLATERAL_FACTOR"));
    // @dev key for the min collateral factor for open interest multiplier
    bytes32 public constant MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER =
        keccak256(abi.encode("MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER"));

    bytes32 public constant OPEN_INTEREST = keccak256(abi.encode("OPEN_INTEREST"));

    // @dev key for claimable funding amount
    bytes32 public constant CLAIMABLE_FUNDING_AMOUNT = keccak256(abi.encode("CLAIMABLE_FUNDING_AMOUNT"));

    // @dev key for oracle provider for token
    bytes32 public constant ORACLE_PROVIDER_FOR_TOKEN = keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN"));

    // @dev key for the max position impact factor for liquidations
    // @param market the market address to check
    // @return key for the max position impact factor
    function maxPositionImpactFactorForLiquidationsKey(address market) internal pure returns (bytes32) {
        return keccak256(abi.encode(MAX_POSITION_IMPACT_FACTOR_FOR_LIQUIDATIONS, market));
    }

    // @dev key for position fee factor
    // @param market the market address to check
    // @param forPositiveImpact whether the fee is for an action that has a positive price impact
    // @return key for position fee factor
    function positionFeeFactorKey(address market, bool forPositiveImpact) internal pure returns (bytes32) {
        return keccak256(abi.encode(POSITION_FEE_FACTOR, market, forPositiveImpact));
    }

    // @dev the min collateral factor key
    // @param the market for the min collateral factor
    function minCollateralFactorKey(address market) internal pure returns (bytes32) {
        return keccak256(abi.encode(MIN_COLLATERAL_FACTOR, market));
    }

    // @dev the min collateral factor for open interest multiplier key
    // @param the market for the factor
    function minCollateralFactorForOpenInterestMultiplierKey(address market, bool isLong)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(MIN_COLLATERAL_FACTOR_FOR_OPEN_INTEREST_MULTIPLIER, market, isLong));
    }

    // @dev key for open interest
    // @param market the market to check
    // @param collateralToken the collateralToken to check
    // @param isLong whether to check the long or short open interest
    // @return key for open interest
    function openInterestKey(address market, address collateralToken, bool isLong) internal pure returns (bytes32) {
        return keccak256(abi.encode(OPEN_INTEREST, market, collateralToken, isLong));
    }

    // @dev key for claimable funding amount by account
    // @param market the market to check
    // @param token the token to check
    // @param account the account to check
    // @return key for claimable funding amount
    function claimableFundingAmountKey(address market, address token, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CLAIMABLE_FUNDING_AMOUNT, market, token, account));
    }

    // @dev key for oracle provider for token
    // @param token the token
    // @return key for oracle provider for token
    function oracleProviderForTokenKey(address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(ORACLE_PROVIDER_FOR_TOKEN, token));
    }
}
