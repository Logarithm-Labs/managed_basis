// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Errors {
    error ZeroShares();
    error RequestNotExecuted();
    error RequestAlreadyClaimed();
    error UnauthorizedClaimer(address claimer, address receiver);

    error InchSwapInvailidTokens();
    error InchSwapAmountExceedsBalance(uint256 swapAmount, uint256 balance);
    error InchInvalidReceiver();

    error IncosistentParamsLength();

    error OracleInvalidPrice();

    error CallerNotFactory();
    error InsufficientIdleBalanceForUtilize(uint256 idleBalance, uint256 utilizeAmount);
    error InsufficientProdcutBalanceForDeutilize(uint256 productBalance, uint256 deutilizeAmount);
}
