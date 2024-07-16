// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library ConfigKeys {
    // @dev key for the address of the exchangeRouter of gmx v2
    bytes32 constant GMX_EXCHANGE_ROUTER = keccak256(abi.encode("GMX_EXCHANGE_ROUTER"));
    // @dev key for the address of the dataStore of gmx v2
    bytes32 constant GMX_DATA_STORE = keccak256(abi.encode("GMX_DATA_STORE"));
    // @dev key for the address of the orderHandler of gmx v2
    bytes32 constant GMX_ORDER_HANDLER = keccak256(abi.encode("GMX_ORDER_HANDLER"));
    // @dev key for the address of the orderVault of gmx v2
    bytes32 constant GMX_ORDER_VAULT = keccak256(abi.encode("GMX_ORDER_VAULT"));
    // @dev key for the address of the referralStorage of gmx v2
    bytes32 constant GMX_REFERRAL_STORAGE = keccak256(abi.encode("GMX_REFERRAL_STORAGE"));
    // @dev key for the address of the reader of gmx v2
    bytes32 constant GMX_READER = keccak256(abi.encode("GMX_READER"));

    // @dev key for the gas limit uint value of the gmx position manager's callback function
    bytes32 constant GMX_CALLBACK_GAS_LIMIT = keccak256(abi.encode("GMX_CALLBACK_GAS_LIMIT"));
    // @dev key for the byte32 value of the gmx position manager's referralCode
    bytes32 constant GMX_REFERRAL_CODE = keccak256(abi.encode("GMX_REFERRAL_CODE"));

    // @dev key for the address of the keeper smart contract
    bytes32 constant KEEPER = keccak256(abi.encode("KEEPER"));
    // @dev key for the address of the oracle smart contract
    bytes32 constant ORACLE = keccak256(abi.encode("ORACLE"));

    // @dev key for the address of the gmx v2 markets
    bytes32 constant GMX_MARKET_LIST = keccak256(abi.encode("GMX_MARKET_LIST"));

    // @dev key for the bool value if a position manager registered
    bytes32 constant IS_POSITION_MANAGER = keccak256(abi.encode("IS_POSITION_MANAGER"));

    // @dev key for the gmx market list
    // @param asset the strategy's asset address for the list
    // @param product the strategy's product address for the list
    function gmxMarketKey(address asset, address product) internal pure returns (bytes32) {
        return keccak256(abi.encode(GMX_MARKET_LIST, asset, product));
    }

    // @dev key for checking if a position manager has been registered
    // @param positionManager the address of position manager
    function isPositionManagerKey(address positionManager) internal pure returns (bytes32) {
        return keccak256(abi.encode(IS_POSITION_MANAGER, positionManager));
    }
}
