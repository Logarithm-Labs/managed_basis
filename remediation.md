# 1. Unable to redeem all user shares or sell all products and close the hedge when the decreaseSizeMax config is different from type(uint256).max.

## Status: Acknowledged

## Remediation

Used your remediation.
Git commit: [`49b26fd63295a4f0f820331de8fe98f759e5a6cb`](https://github.com/Logarithm-Labs/managed_basis/commit/49b26fd63295a4f0f820331de8fe98f759e5a6cb)

# 2. pendingDecreaseCollateral variable isn't excluded from the positionNetBalance() value in the leverage and rebalance calculations, which may lead to incorrect rebalance actions for the strategy.

# 3. The strategy does not pause when the deviation of sizeDeltaInTokens exceeds the threshold.

# 4. Last withdrawer could give next depositor 0 share.

# 5. Lack of slippage protection for manual swap in SpotManager.

# 6. $.pendingDecreaseCollateral variable will be updated incorrectly if the agent executes an insufficient response, leading to an imbalance in the strategy after unpausing.

# 7. Not all pendingDecreaseCollateral is utilized due to the max limit.

# 8. Loss of fees due to lack of updates before the \_lastHarvestedTimestamp is updated.

# 9. Unable to execute the final withdrawal due to utilizedAssets() not being zero.

# 10. Redundant and ineffective staleness check implementation.

# 11. The change in priority after requestWithdraw may block the claiming of the withdrawal request.

# 12. LogarithmVault.sol::maxMint is returning super.maxDeposit instead of super.maxMint.

# 13. Missing Asset/Product Check When Setting New Strategy.

# 14. Invalidation of setLimitDecreaseCollateral Validation Logic when setting new setCollateralMinMax.

# 15. Missing disableinitializers() to prevent uninitialized contract.

# 16. BasisStrategy::\_afterIncreasePosition may send asset to vault without LogarithmVault.processingPendingWithdrawRequest.

# 17. Use Custom Error.

# 18. Use Ownable2StepUpgradeable for all contract.

# 19. Constant variables should be marked as private
