# 1. Unable to redeem all user shares or sell all products and close the hedge when the decreaseSizeMax config is different from type(uint256).max.

## Status: Acknowledged

## Remediation

Used your remediation. <br>
Git commit: [`49b26fd63295a4f0f820331de8fe98f759e5a6cb`](https://github.com/Logarithm-Labs/managed_basis/commit/49b26fd63295a4f0f820331de8fe98f759e5a6cb)

# 2. pendingDecreaseCollateral variable isn't excluded from the positionNetBalance() value in the leverage and rebalance calculations, which may lead to incorrect rebalance actions for the strategy.

## Status: Rejected

## Description

We just don't want to mix `pendingDecreaseCollateral` with `positionNetBalance` and `currentLeverage` because it is only for the strategy itself.
If we mix them, then we have to implement another additional logic to calculate the utilized assets of the strategy.
The current implementation is as follows:

```solidity
// scr/strategy/BasisStrategy.sol#L707-L710

function utilizedAssets() public view returns (uint256) {
BasisStrategyStorage storage $ = \_getBasisStrategyStorage();
return $.spotManager.getAssetValue() + $.hedgeManager.positionNetBalance() + assetsToWithdraw();
}
```

Importantly, the incorrect rebalance actions what you are concerning doesn't happen.
Here are the arguments.

1. For rebalancing up
   When decreasing collateral for rebalancing up, `pendingDecreaseCollateral` is reduced within the function `_afterDecreasePosition` by the decreased amount. So the concern of the incorrect leverage state what you mentioned in your scenario won't happen.

   ```solidity
    // scr/strategy/BasisStrategy.sol

    function performUpkeep(bytes calldata /*performData*/ ) external whenIdle {
        [...]
        else if (result.deltaCollateralToDecrease > 0) {
            if (!_adjustPosition(0, result.deltaCollateralToDecrease, false)) {
                _setStrategyStatus(StrategyStatus.IDLE);
            }
        }
        [...]
    }
   ```

   ```solidity
   // scr/strategy/BasisStrategy.sol

   function _afterDecreasePosition(IHedgeManager.AdjustPositionPayload calldata responseParams)
    private
    returns (bool shouldPause)
   {
    [...]
    if (responseParams.collateralDeltaAmount > 0) {
        // the case when deutilizing for withdrawals and rebalancing Up
        (, $.pendingDecreaseCollateral) = $.pendingDecreaseCollateral.trySub(responseParams.collateralDeltaAmount);
        _asset.safeTransferFrom(_msgSender(), address(this), responseParams.collateralDeltaAmount);
    }
    [...]
   }
   ```

2. For rebalancing down
   In the case when the position leverage is bigger than the max limit, we break the logic of accounting for `pendingDecreaseCollateral` because it is for keeping the current safe leverage when executing the partial deutilization.
   That's why we don't account for `pendingDecreaseCollateral` into the calculation of `pendingDeutilization` as well as into the `_checkUpkeep` logic, while setting it as 0 within the function `performUpkeep`.

   ```solidity
   // scr/strategy/BasisStrategy.sol

   function _pendingDeutilization(InternalPendingDeutilization memory params) private view returns (uint256) {
       [...]
       if (params.processingRebalanceDown) {
           // for rebalance
           uint256 currentLeverage = params.hedgeManager.currentLeverage();
           uint256 _targetLeverage = $.targetLeverage;
           if (currentLeverage > _targetLeverage) {
               // calculate deutilization product
               // when totalPendingWithdraw is enough big to prevent increasing collateral
               uint256 deltaLeverage = currentLeverage - _targetLeverage;
               deutilization = positionSizeInTokens.mulDiv(deltaLeverage, currentLeverage);
               uint256 deutilizationInAsset = $.oracle.convertTokenAmount(params.product, params.asset, deutilization);

               // when totalPendingWithdraw is not enough big to prevent increasing collateral
               if (totalPendingWithdraw < deutilizationInAsset) {
                   uint256 num = deltaLeverage + _targetLeverage.mulDiv(totalPendingWithdraw, positionNetBalance);
                   uint256 den = currentLeverage + _targetLeverage.mulDiv(positionSizeInAssets, positionNetBalance);
                   deutilization = positionSizeInTokens.mulDiv(num, den);
               }
           }
       }
       [...]
   }
   ```

   ```solidity
   // scr/strategy/BasisStrategy.sol

   function _checkUpkeep() private view returns (InternalCheckUpkeepResult memory result) {
       [...]
       if (rebalanceDownNeeded) {
           uint256 idleAssets = _vault.idleAssets();
           (uint256 minIncreaseCollateral,) = _hedgeManager.increaseCollateralMinMax();
           result.deltaCollateralToIncrease = _calculateDeltaCollateralForRebalance(
               _hedgeManager.positionNetBalance(), currentLeverage, _targetLeverage
           );
           if (result.deltaCollateralToIncrease < minIncreaseCollateral) {
               result.deltaCollateralToIncrease = minIncreaseCollateral;
           }

           // deutilize when idle assets are not enough to increase collateral
           // and when processingRebalanceDown is true
           // and when deleverageNeeded is false
           if (
               !deleverageNeeded && _processingRebalanceDown && (idleAssets == 0 || idleAssets < minIncreaseCollateral)
           ) {
               result.deltaCollateralToIncrease = 0;
               return result;
           }

           // emergency deutilize when idleAssets are not enough to increase collateral
           // in case currentLeverage is bigger than safeMarginLeverage
           if (deleverageNeeded && (result.deltaCollateralToIncrease > idleAssets)) {
               (, uint256 deltaLeverage) = currentLeverage.trySub(_maxLeverage);
               result.emergencyDeutilizationAmount =
                   _hedgeManager.positionSizeInTokens().mulDiv(deltaLeverage, currentLeverage);
               (uint256 min, uint256 max) = _hedgeManager.decreaseSizeMinMax();
               // @issue amount can be 0 because of clamping that breaks emergency rebalance down
               result.emergencyDeutilizationAmount = _clamp(min, result.emergencyDeutilizationAmount, max);
           }
           return result;
       }
       [...]
   }
   ```

   ```solidity

   function performUpkeep(bytes calldata /*performData*/ ) external whenIdle {
       [...]
       if (result.emergencyDeutilizationAmount > 0) {
           $.pendingDecreaseCollateral = 0;
           $.processingRebalanceDown = true;
           $.spotManager.sell(result.emergencyDeutilizationAmount, ISpotManager.SwapType.MANUAL, "");
       } else if (result.deltaCollateralToIncrease > 0) {
           $.pendingDecreaseCollateral = 0;
           $.processingRebalanceDown = true;
           uint256 idleAssets = $.vault.idleAssets();
           if (
               !_adjustPosition(
                   0,
                   idleAssets < result.deltaCollateralToIncrease ? idleAssets : result.deltaCollateralToIncrease,
                   true
               )
           ) _setStrategyStatus(StrategyStatus.IDLE);
       }
       [...]
   }
   ```

# 3. The strategy does not pause when the deviation of sizeDeltaInTokens exceeds the threshold.

## Status: Acknowledged

## Remediation

Fixed a little bit different from your recommendation. <br>
Git commit: [8e8b733e93dcb060237efc56f944dfb0afc1f5f5](https://github.com/Logarithm-Labs/managed_basis/commit/8e8b733e93dcb060237efc56f944dfb0afc1f5f5)

# 4. Last withdrawer could give next depositor 0 share.

## Status: Acknowledged

## Remediation

1. Removed the logic that makes the first depositor avoiding the OZ's decimal offset calculation.
   Git commit: [af468f1213cf35dc5942b9195e706ee4758d1633](https://github.com/Logarithm-Labs/managed_basis/commit/af468f1213cf35dc5942b9195e706ee4758d1633)
2. Added the logic of reverting when minting with zero shares, as you recommended.
   Git commit: [55fe528f7ec208c0db4dee1b9288790eee737eeb](https://github.com/Logarithm-Labs/managed_basis/commit/55fe528f7ec208c0db4dee1b9288790eee737eeb)

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
