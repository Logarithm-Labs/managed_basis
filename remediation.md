# 1. Unable to redeem all user shares or sell all products and close the hedge when the decreaseSizeMax config is different from type(uint256).max.

## Status: Refactored

## Description

We have removed the max limit logic as it is supposed not to use it for the future versions.
Git commit: [bd3d08648f9b32743b177c44580c598766916e7a](https://github.com/Logarithm-Labs/managed_basis/commit/bd3d08648f9b32743b177c44580c598766916e7a)

# 2. pendingDecreaseCollateral variable isn't excluded from the positionNetBalance() value in the leverage and rebalance calculations, which may lead to incorrect rebalance actions for the strategy.

## Status: Refactored

## Description

`pendingDecreaseCollateral` was used only in the case of partial deutilization with small amounts, in order to keep the current leverage as long as possible while saving the execution cost.
But the oracle price keeps changing, so there is no guarantee that the leverage is safe under the operation. Even it makes the strategy logic more complicated.
As a result, we have removed the `pendingDecreaseCollateral` logic throughout the strategy.
Then you may come with the question what happens with the partial deutilization with small amounts.
In that case, we have agreed on decreasing only sizes of spot and hedge, that resulted in leveraging down.
Leveraging down is acceptable for us and we have the rebalancing up logic on the other hand. <br>
Git commit: [cac461f907029391efc403f4b10ba03a92caa57d](https://github.com/Logarithm-Labs/managed_basis/commit/cac461f907029391efc403f4b10ba03a92caa57d)

# 3. The strategy does not pause when the deviation of sizeDeltaInTokens exceeds the threshold.

## Status: Acknowledged and fixed

## Description

Fixed in a similar way to your recommendation. <br>
Git commit: [8e8b733e93dcb060237efc56f944dfb0afc1f5f5](https://github.com/Logarithm-Labs/managed_basis/commit/8e8b733e93dcb060237efc56f944dfb0afc1f5f5)

# 4. Last withdrawer could give next depositor 0 share.

## Status: Acknowledged and fixed

## Description

1. Removed the logic that makes the first depositor avoiding the OZ's decimal offset calculation.
   Git commit: [af468f1213cf35dc5942b9195e706ee4758d1633](https://github.com/Logarithm-Labs/managed_basis/commit/af468f1213cf35dc5942b9195e706ee4758d1633)
2. Added the logic of reverting when minting with zero shares, as you recommended.
   Git commit: [55fe528f7ec208c0db4dee1b9288790eee737eeb](https://github.com/Logarithm-Labs/managed_basis/commit/55fe528f7ec208c0db4dee1b9288790eee737eeb)

# 5. Lack of slippage protection for manual swap in SpotManager.

## Status: Acknowledged and fixed

## Description

Validated the output amount by calculating the minimum amount based on TWAP and slippage.
Git commit: [3cf11627b7ff5e0530ea68fafdb828b5fdb3b490](https://github.com/Logarithm-Labs/managed_basis/commit/3cf11627b7ff5e0530ea68fafdb828b5fdb3b490)

# 6. $.pendingDecreaseCollateral variable will be updated incorrectly if the agent executes an insufficient response, leading to an imbalance in the strategy after unpausing.

## Status: Refactored

## Description

Please refer to the description to issue 2.

# 7. Not all pendingDecreaseCollateral is utilized due to the max limit.

## Status: Refactored

## Description

Please refer to the descriptions to issue 1 and 2.

# 8. Loss of fees due to lack of updates before the \_lastHarvestedTimestamp is updated.

## Status: No action required

## Description

The performance fee gets harvested based on `lastHarvestedTimestamp` while the management fee gets accrued based on `lastAccruedTimestamp`.
And regarding to the management accruement, it is done before all actions where share balances get updated, as you can see below.

```solidity
    /// @dev Accrues the management fee when it is set.
    ///
    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        address _feeRecipient = feeRecipient();
        address _whitelistProvider = whitelistProvider();

        if (
            to != address(0) && to != _feeRecipient && _whitelistProvider != address(0)
                && !IWhitelistProvider(_whitelistProvider).isWhitelisted(to)
        ) {
            revert Errors.NotWhitelisted(to);
        }

        if (_feeRecipient != address(0)) {
            if ((from == _feeRecipient && to != address(0)) || (from != address(0) && to == _feeRecipient)) {
                revert Errors.ManagementFeeTransfer(_feeRecipient);
            }

            if (from != address(0) || to != _feeRecipient) {
                // called when minting to none of recipient
                // to stop infinite loop
                _accrueManagementFeeShares(_feeRecipient);
            }
        }

        super._update(from, to, value);
    }
```

FYI, we decided to implement them separately because the management fee is always accrued based on the elapsed timestamp while the performance fee is done mainly based on the high water mark.

# 9. Unable to execute the final withdrawal due to utilizedAssets() not being zero.

## Status: Acknowledged partially and mitigated

## Description

We had two decentralized functions `Strategy.processAssetsToWithdraw` and `HedgeManager.clearIdleCollateral` to clear the idle assets under the assumption that protocol is deployed on Arbitrum chain where front running is impossible.
To make things more efficient, we added the logic as you mentioned.
Git commit: [ad85e6d24dd3e70750916ed8ffa29993bf70e2c3](https://github.com/Logarithm-Labs/managed_basis/commit/ad85e6d24dd3e70750916ed8ffa29993bf70e2c3)

# 10. Redundant and ineffective staleness check implementation.

## Status: Acknowledged and fixed

## Description

We have removed the redundant check.
Git commit: [5821580ea72a38b15bbc5bc4efd6ae388218bbd9](https://github.com/Logarithm-Labs/managed_basis/commit/5821580ea72a38b15bbc5bc4efd6ae388218bbd9)

# 11. The change in priority after requestWithdraw may block the claiming of the withdrawal request.

## Status: Acknowledged and fixed

## Description

We have fixed as you recommended.
Git commit: [eef32a16b38e017024a639d8942482ae6643f25d](https://github.com/Logarithm-Labs/managed_basis/commit/eef32a16b38e017024a639d8942482ae6643f25d)

# 12. LogarithmVault.sol::maxMint is returning super.maxDeposit instead of super.maxMint.

## Status: Acknowledged and fixed

## Description

We have fixed.
Git commit: [3ac9b0ee05697f1739a5ceadb6af3775ec6d27fb](https://github.com/Logarithm-Labs/managed_basis/commit/3ac9b0ee05697f1739a5ceadb6af3775ec6d27fb)

# 13. Missing Asset/Product Check When Setting New Strategy.

## Status: Acknowledged and fixed

## Description

We have added the validation checks of asset, product and vault of strategy.
Git commit: [b8d238d8796d37bd36c6b70f96acff64dc4ed255](https://github.com/Logarithm-Labs/managed_basis/commit/b8d238d8796d37bd36c6b70f96acff64dc4ed255)

# 14. Invalidation of setLimitDecreaseCollateral Validation Logic when setting new setCollateralMinMax.

## Status: Acknowledged and fixed

## Description

We have added the validation.
Git commit: [a223b2c1d71272a72d83a9df687247d26742dfae](https://github.com/Logarithm-Labs/managed_basis/commit/a223b2c1d71272a72d83a9df687247d26742dfae)

# 15. Missing disableinitializers() to prevent uninitialized contract.

## Status: Acknowledged and fixed

## Description

We have added the function to each of the upgradeable smart contracts.
Git commit: [9153bb7d5ee6896f71c5b0c9a62eeb6fdd2a63df](https://github.com/Logarithm-Labs/managed_basis/commit/9153bb7d5ee6896f71c5b0c9a62eeb6fdd2a63df)

# 16. BasisStrategy::\_afterIncreasePosition may send asset to vault without LogarithmVault.processingPendingWithdrawRequest.

## Status: Acknowledged and fixed

## Description

We have acknowledged and fixed. And, in addition to `BasisStrategy::_afterIncreasePosition`, we have added that logic to `BasisStrategy::spotBuyCallback` because the spot callbacks will be asynchronous for cross-chain modes in the future version. <br>
Git commit: [4f6d1844b076ea46a8ff38647baeecbe8f28d89a](https://github.com/Logarithm-Labs/managed_basis/commit/4f6d1844b076ea46a8ff38647baeecbe8f28d89a)

# 17. Use Custom Error.

## Status: Acknowledged and fixed

## Description

We have used the custom errors only for the user interfaces.
Git commit: [313c9c712fe1da45f1bf5aa9e70aa242949624b5](https://github.com/Logarithm-Labs/managed_basis/commit/313c9c712fe1da45f1bf5aa9e70aa242949624b5)

# 18. Use Ownable2StepUpgradeable for all contract.

## Status: Acknowledged and fixed

## Description

We have used `Ownable2StepUpgradeable` in all smart contracts.
Git commit: [5dd34a1957856404a3aaa2917e8d9d6b1b07d0c2](https://github.com/Logarithm-Labs/managed_basis/commit/5dd34a1957856404a3aaa2917e8d9d6b1b07d0c2)

# 19. Constant variables should be marked as private

## Status: Acknowledged and fixed

## Description

We have acknowledged and fixed.
Git commit: [eb92369922a0015b22c25e28cdd85a02a8fd5eff](https://github.com/Logarithm-Labs/managed_basis/commit/eb92369922a0015b22c25e28cdd85a02a8fd5eff)
