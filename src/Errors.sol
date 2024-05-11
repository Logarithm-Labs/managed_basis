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
}