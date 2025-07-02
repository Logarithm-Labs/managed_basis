// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

library Errors {
    /*//////////////////////////////////////////////////////////////
                                 VAULT
    //////////////////////////////////////////////////////////////*/
    /// @notice Withdraw request is not executed.
    error RequestNotExecuted();
    /// @notice Withdraw request is already claimed.
    error RequestAlreadyClaimed();
    /// @notice User is not allowed to use protocol.
    error NotWhitelisted(address user);
    /// @notice Requested assets to withdraw exceeded the max amounts.
    error ExceededMaxRequestWithdraw(address owner, uint256 assets, uint256 max);
    /// @notice Requested shares to redeem exceeded the max amounts.
    error ExceededMaxRequestRedeem(address owner, uint256 shares, uint256 max);
    /// @notice Transferring of shares from/to the fee recipient is not allowed.
    error ManagementFeeTransfer(address feeRecipient);
    /// @notice Reverts minting with 0 shares
    error ZeroShares();
    /// @notice Validation for strategy
    error InvalidStrategy();

    /*//////////////////////////////////////////////////////////////
                                 1INCH
    //////////////////////////////////////////////////////////////*/
    error InchInvalidAmount(uint256 requestedAmountIn, uint256 unpackedAmountIn);
    error InchInvalidSourceToken(address sourceToken, address requiredSourceToken);
    error InchInvalidDestinationToken(address destinationToken, address requiredDestinationToken);
    error InchInvalidReceiver(address receiver, address requiredReceiver);
    error InchInsufficientSourceBalance(uint256 sourceAmount, uint256 sourceBalance);

    /*//////////////////////////////////////////////////////////////
                                 MANUAL
    //////////////////////////////////////////////////////////////*/
    error SwapAmountExceedsBalance(uint256 swapAmount, uint256 balance);
    error SwapBelowMinimum(uint256 out, uint256 min);
    error SwapWithZeroLiquidity();

    /*//////////////////////////////////////////////////////////////
                                 ORACLE
    //////////////////////////////////////////////////////////////*/
    error IncosistentParamsLength();
    /// @notice invalid chainlink price feed
    error InvalidFeedPrice(address token, int256 price);
    /// @notice chainlink price feed not updated
    error PriceFeedNotUpdated(address token, uint256 timestamp, uint256 heartbeatDuration);
    /// @notice price feed was not configured
    error PriceFeedNotConfigured();
    /// @notice Asset decimal was not set
    error DecimalNotConfigured(address asset);

    /*//////////////////////////////////////////////////////////////
                                STRATEGY
    //////////////////////////////////////////////////////////////*/
    /// @notice zero address check
    error ZeroAddress();
    /// @notice price feed multiplier not configured
    error EmptyPriceFeedMultiplier(address token);
    error ZeroPendingUtilization();
    error ZeroAmountUtilization();
    error InvalidStrategyStatus(uint8 currentStatus, uint8 targetStatus);
    error HedgeInvalidSizeResponse();
    error HedgeInvalidCollateralResponse();
    error HedgeWrongCloseResponse();

    /*//////////////////////////////////////////////////////////////
                            POSITION MANAGER
    //////////////////////////////////////////////////////////////*/
    /// @notice only callable by strategy
    error CallerNotStrategy();
    /// @notice invalid maket config when deploying pos manager
    error InvalidMarket();
    /// @notice asset and product are not matched with short and long tokens
    error InvalidInitializationAssets();
    /// @notice invalid gmx callback function caller
    error CallbackNotAllowed();
    /// @notice only one gmx order pending allowed
    error AlreadyPending();
    // @notice there is not enough positive pnl when decrease collateral
    error NotEnoughPnl();
    error NotEnoughCollateral();
    error NoActiveRequests();
    error InvalidAdjustmentParams();
    error InvalidSizeRequest(uint256 sizeDeltaInTokens, bool isIncrease);
    error InvalidCollateralRequest(uint256 collateralDeltaAmount, bool isIncrease);
    error ProcessingRequest();

    /*//////////////////////////////////////////////////////////////
                              SPOT MANAGER
    //////////////////////////////////////////////////////////////*/
    error UnsupportedSwapType();
    error SwapFailed();
    error InvalidStargate();
    error InvalidSender();
    error InvalidTokenSend();
    error RequestInPending();
    error NoPendingRequest();
    error ExceedsSlippage();

    /*//////////////////////////////////////////////////////////////
                              AUTH CALLER
    //////////////////////////////////////////////////////////////*/
    error CallerNotAuthorized(address authorized, address caller);
    error GasCallerNotAllowed();
    error CallerNotAgent();
    error InvalidCallback();
    error CallerNotOwnerOrVault();
    error InvalidSecurityManager();
    error CallerNotRegisteredPool();
}
