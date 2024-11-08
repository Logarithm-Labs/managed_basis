// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Errors {
    error RequestNotExecuted();
    error RequestAlreadyClaimed();
    error InchInvalidReceiver();
    error InchInvalidAmount(uint256 requestedAmountIn, uint256 unpackedAmountIn);

    error SwapAmountExceedsBalance(uint256 swapAmount, uint256 balance);

    error IncosistentParamsLength();

    /// @notice only callable by strategy
    error CallerNotStrategy();
    /// @notice invalid maket config when deploying pos manager
    error InvalidMarket();
    /// @notice asset and product are not matched with short and long tokens
    error InvalidInitializationAssets();
    /// @notice invalid gmx callback function caller
    error CallbackNotAllowed();
    /// @notice zero address check
    error ZeroAddress();

    /// @notice only one gmx order pending allowed
    error AlreadyPending();

    // errors from gmx oracle

    /// @notice invalid chainlink price feed
    error InvalidFeedPrice(address token, int256 price);
    /// @notice chainlink price feed not updated
    error PriceFeedNotUpdated(address token, uint256 timestamp, uint256 heartbeatDuration);
    /// @notice price feed was not configured
    error PriceFeedNotConfigured();
    /// @notice price feed multiplier not configured
    error EmptyPriceFeedMultiplier(address token);

    error UnsupportedSwapType();

    // @notice there is not enough positive pnl when decrease collateral
    error NotEnoughPnl();

    error NotEnoughCollateral();

    error ZeroPendingUtilization();

    error ZeroAmountUtilization();

    error CallerNotPositionManager();

    error CallerNotAgent();

    error InvalidCallback();

    error NoActiveRequests();

    error CallerNotOperator();

    error InvalidAdjustmentParams();

    error InvalidStrategyStatus(uint8 status);

    error InvalidCollateralRequest(uint256 collateralDeltaAmount, bool isIncrease);

    // vault
    error ManagementFeeTransfer(address feeRecipient);

    error SwapFailed();

    error FailedStopStrategy();

    error CallerNotOwnerOrVault();

    error VaultShutdown();

    error InvalidSecurityManager();

    error NotWhitelisted(address user);
}
