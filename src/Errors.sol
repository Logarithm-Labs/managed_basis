// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Errors {
    error ZeroShares();
    error RequestNotExecuted(uint256 requestAmount, uint256 executedAmount);
    error RequestAlreadyClaimed();
    error UnauthoirzedClaimer(address claimer, address receiver);

    error InchSwapInvailidTokens();
    error InchSwapAmountExceedsBalance(uint256 swapAmount, uint256 balance);
    error InchInvalidReceiver();

    error IncosistentParamsLength();

    error OracleInvalidPrice();
    /// @notice try upgrading with unauthorized acc
    error UnauthoirzedUpgrade();
    /// @notice only callable by strategy
    error CallerNotStrategy();
    /// @notice invalid maket config when deploying pos manager
    error InvalidMarket();
    /// @notice asset and product are not matched with short and long tokens
    error InvalidInitializationAssets();
    /// @notice invalid gmx callback function caller
    error CallerNotOrderHandler();
}
