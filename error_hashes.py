from eth_utils import keccak

# List of error signatures
error_signatures = [
    "ZeroShares()",
    "RequestNotExecuted()",
    "RequestAlreadyClaimed()",
    "UnauthorizedClaimer(address,address)",
    "InchSwapInvailidTokens()",
    "InchSwapAmountExceedsBalance(uint256,uint256)",
    "InchInvalidReceiver()",
    "InchInvalidAmount(uint256,uint256)",
    "IncosistentParamsLength()",
    "CallerNotFactory()",
    "CallerNotStrategy()",
    "CallerNotKeeper()",
    "InvalidMarket()",
    "InvalidInitializationAssets()",
    "CallbackNotAllowed()",
    "ZeroAddress()",
    "ArrayLengthMissmatch()",
    "AlreadyPending()",
    "InvalidFeedPrice(address,int256)",
    "PriceFeedNotUpdated(address,uint256,uint256)",
    "PriceFeedNotConfigured()",
    "EmptyPriceFeedMultiplier(address)",
    "InsufficientExecutionFee(uint256,uint256)",
    "OracleInvalidPrice()",
    "InsufficientIdleBalanceForUtilize(uint256,uint256)",
    "InsufficientProdcutBalanceForDeutilize(uint256,uint256)",
    "UnsupportedSwapType()",
    "UnAuthorizedForwarder(address)",
    "NotPositivePnl()",
    "ActiveRequestIsNotClosed(bytes32)",
    "StatusNotIdle()",
    "ZeroPendingUtilization()",
    "ZeroAmountUtilization()",
    "CallerNotPositionManager()",
    "CallerNotAgent()",
    "InvalidRequestId(bytes32,bytes32)",
    "InvalidCallback()",
    "InvalidActiveRequestType()",
    "InsufficientCollateralBalance(uint256,uint256)",
    "NoActiveRequests()",
    "CallerNotOperator()",
    "InvalidStrategyStatus(uint8)"
]

# Calculate Keccak256 hash and selectors
for signature in error_signatures:
    hash_bytes = keccak(text=signature)
    selector = hash_bytes[:4].hex()
    print(f"{signature}: 0x{selector}")
