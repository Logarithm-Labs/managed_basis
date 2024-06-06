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
    /// @notice only callable by factory
    error CallerNotFactory();
    /// @notice only callable by strategy
    error CallerNotStrategy();
    /// @notice only callable by keeper
    error CallerNotKeeper();
    /// @notice invalid maket config when deploying pos manager
    error InvalidMarket();
    /// @notice asset and product are not matched with short and long tokens
    error InvalidInitializationAssets();
    /// @notice invalid gmx callback function caller
    error CallbackNotAllowed();
    /// @notice zero address check
    error ZeroAddress();
    /// @notice arrays are expected to have same length
    error ArrayLengthMissmatch();
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
    /// @notice provided execution fee is not enough
    error InsufficientExecutionFee(uint256 expectedExecutionFee, uint256 executionFee);

    error OracleInvalidPrice();
    error InsufficientIdleBalanceForUtilize(uint256 idleBalance, uint256 utilizeAmount);
    error InsufficientProdcutBalanceForDeutilize(uint256 productBalance, uint256 deutilizeAmount);

    error UnsupportedSwapType();

    // @notice upkeep validation
    error UnAuthorizedForwarder(address fowarder);

    // @notice there is no positive when decrease collateral
    error NotPositivePnl();

    error ActiveRequestIsNotClosed(bytes32 requestId);

    error AlreadyUtilizing();

    error NotUtilizing();

    error NegativePendingUtilization(uint256 pendingUtilization);

    error ZeroAmountUtilization();

    error CallerNotPositionManager();
}
