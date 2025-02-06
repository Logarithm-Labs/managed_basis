**Issue 9:**
In the function BasisStrategy.processAssetsToWithdraw(), it already pulls the asset from the `hedgeManager`.

**_Status_**: Acknowledged and fixed <br>
**_Description_**: We were going to use `OffchainPositionManager.clearIdleCollateral()` separately from `BasisStrategy.processAssetsToWithdraw()`, but don't see any use cases for it. So removed it. <br>
Git commit: [557bb383bf1d2a71554aab97bd12799dff219749](https://github.com/Logarithm-Labs/managed_basis/commit/557bb383bf1d2a71554aab97bd12799dff219749)

---

**Issue 5:**
The mitigation of the issue in ManualSwapLogic.sol introducing the getSqrtTwapX96() fn line 57. This function may have an issue line 67 where they calculate:
int256 twapTick = int256(tickCumulatives[1] - tickCumulatives[0]) / int256(uint256(twapInterval));

**_Status_**: Acknowledged and fixed <br>
**_Description_**: We have fixed in the way as you recommended. <br>
Git commit: [4cc09c752e831465810eee99267693d726971c99](https://github.com/Logarithm-Labs/managed_basis/commit/4cc09c752e831465810eee99267693d726971c99)
