# Extended Audit Overview

## Table of Contents

- [Introduction](#introduction)
- [System Architecture](#system-architecture)
- [New Features](#new-features)
- [Refactors](#refactors)
- [Self-Found Issues and Fixes](#self-found-issues-and-fixes)

## Introduction

We have introduced cross-chain spot buy/sell operations to enhance protocol functionality and efficiency.

## System Architecture

The system consists of several key components that work together to enable cross-chain spot operations:

1. **Core Components**

   - `XSpotManager`: Initiates and manages cross-chain spot operations
   - `BrotherSwapper`: Executes swaps on remote chains
   - `AssetValueTransmitter`: Handles cross-chain asset value conversions
   - `GasStation`: Manages cross-chain gas fees
   - `TimelockManager`: Implements administrative controls

2. **Messaging Layer**

   - `LzLogMessenger`: Handles cross-chain messaging via LayerZero
   - `GasConsumer`: Common interface for gas management

## Detailed Description

### New Features

- **`XSpotManager.sol`**  
  _Path: `managed_basis/src/spot/crosschain/XSpotManager.sol`_

  - Initiates spot sell/buy requests from strategy.
  - Receives swap results from remote chains.
  - Utilizes our own messenger smart contract.

- **`BrotherSwapper.sol`**  
  _Path: `managed_basis/src/spot/crosschain/BrotherSwapper.sol`_

  - Executes swaps on remote chains.
  - Sends swap results back to the original chain.
  - Utilizes our own messenger smart contract.

- **`AssetValueTransmitter.sol`**  
  _Path: `managed_basis/src/spot/crosschain/AssetValueTransmitter.sol`_

  - Handles different decimal representations of product assets across multiple chains.

- **`GasStation.sol`**  
  _Path: `managed_basis/src/gas-station/GasStation.sol`_

  - Provides native token fees for protocol smart contracts for cross-chain operations.

- **`TimelockManager.sol`**  
  _Path: `managed_basis/src/timelock/TimelockManager.sol`_

  - As being the owner of all smart contracts, adds timelock to the administrative functionalities for the protocol except several direct functions.

- **`LzLogMessenger.sol`**  
  _Path: `logarithm-messenger/contracts/LzLogMessenger.sol`_

  - Manages cross-chain messaging by utilizing LayerZero.
  - Bridges assets (e.g., USDC) between smart contracts across multiple chains by utilizing Stargate.

- **`GasConsumer.sol`**  
  _Path: `logarithm-messenger/contracts/common/GasConsumer.sol`_
  - Common interface for utilizing the Gas Station.

## Refactors

### 1. Asynchronous Deutilization

- **Description:** Spot operations require time, resulting in a considerable delay between the hedge operation.
- **Solution:** Initiate both operations within the same transaction.
- **Git Commit:** `9720d968e08140ecd733b17c92fdff9fc9e14e8e`

### 2. Strategy Pause Logic Update

- **Description:** Previous logic paused the strategy when the hedge response exceeded the threshold.
- **Solution:** Implemented a revert logic instead.
- **Git Commits:**
  - `ce8488f1351f171139064b6586b9fc0406528ffb`
  - `8318140d342eaf30cdf0a4b1a91d575d5ed0e07c`
  - `aa358cc0f9df0b27db41bc3e30df0d46153025c5`

### 3. Hedge Collateral Reservation

- **Description:** Hedge adjustments are not synchronized with spot operations, allowing withdrawals that could disrupt hedge positions.
- **Solution:** Reserved collateral to prevent failures in spot buy callbacks.
- **Git Commits:**
  - `2fb2a5b3efad8caca43c76e3256b32e854f7444f`
  - `f1d64c8ee8d3cbb483420c509176697d781545e3`

### 4. Swap Timestamp in Event Parameters

- **Description:** Added a timestamp to swap event logs for better traceability.
- **Git Commit:** `6aecedfd86316a56c76f00049b0de7be4ee2d976`

### 5. Usage of 1Inch Swap Data with Slightly Different Amount

- **Description:** With cross-chain setup and replacement of full deutilization amount, the amount that was used to get 1inch swap data is changed slightly on-chain.
- **Solution:** Unpacked the swap data and repacked it with modified amount and minimum amount.
- **Git Commit:** `dc85e1beae9c648c8c37e0f404a0d636827b93dc`

### 6. Threshold Apply for Utilization/Deutilization

- **Description:** The utilization/deutilization amount can affect the external protocols like HyperLiquid. During our live testing, we decided on applying limit the amounts on-chain.
- **Solution:** Capped the utilization/deutilization amount by a certain threshold that is derived by percentage of `idleAssets + utilizedAssets`.
- **Git Commit:** `79c23e6d95bb4b84eea3ac4ebc7ace2822eb3323`

### 7. Semi-Asynchronous utilization

- **Description:** Spot operations require time, resulting in a considerable delay between the hedge operation.
- **Solution:** Initiate both operations within the same transaction in case of cross-chain setup, otherwise sync one. This is because the hedge delta size to increase cannot be exact one with the async one. Applied it only to the cross-chain setup.
- **Git Commit:** `dc1ebb857cf7ca679cb4d913787e8fbe5c484652`, `a827afff6bb1327127c95f9f598a2af74665441e`

### 8. Grant the access of entry/exit cost modification to a security manager

- **Description:** Utilizing/Deutilizing costs keep changing all the time due to price spread.
- **Solution:** Granted the access to a security manager so that he can handle based on the current strategy status.
- **Git Commit:** `5d493903003cdf9d3ca6ea22d6bb56760d846408`

### 9. Introduced Withdraw Buffer to reduce frequent deutilize operation

- **Description:** Users ask to withdraw frequently, resulting in gas consumption for the operator.
- **Solution:** Updated the logic for calculating pendingUtilization.For pending utilization we want to implement withdrawBuffer. The idea is that when we are utilizing we want to always keep the withdrawBuffer amount of idle assets in the vault, so users with small amounts can withdraw directly. The strategy does not take any direct actions to fill in withdraw buffer if it is empty, the withdraw buffer is depleted by new withdraws and filled in by new deposits. Withdraw buffer should have no affect on the rebalancing logic. For IDLE STATUS if pendingUtilization is smaller then withdraw buffer, then pendingUtilization should be zero.
- **Git Commit:** `80dbdc6b0e9b5e63bac134ee0965b84510be44cb`

### 10. Removed hedge size and collateral validation within strategy

- **Description:** The hedge operation is done within the same tx with utilize/deutilize and the hedge manager has a reverting logic to validate the size and collateral adjustment. So don't need to double check it within strategy.
- **Solution:** Removed the logic in strategy.
- **Git Commit:** `6fd1ab546188d47598856b90d292ec682da35a5f`

## Self-Found Issues and Fixes

### 1. DoS in `LogarithmVault.requestRedeem`

- **Issue:** An attacker could manipulate asset transfers, leading to failed redemption requests.
- **PoC:**
  1. Vault initially holds 100,000 assets.
  2. Victim deposits 199,999,999 assets and receives `199,999,999 * (0 + 1) / (100,000 + 1) = 1,999` shares.
  3. Operator utilizes all assets.
  4. Attacker transfers 1 asset to the Vault.
  5. Victim's redemption request fails due to incorrect share calculations resulting in none-zero 1 shares to withdraw immediately utilizing the idle assets in the Vault. The calculated asset amount to withdraw immediately becomes `1 * 200,100,000 / 1,999 = 100,100` which is bigger than 1.
- **Fix:**
  1. Modified rounding calculation of `LogarithmVault.maxRedeem` from ceil to floor.
  2. Changed the logic of `LogarithmVault.requestRedeem` from share-based to asset-based.
- **Git Commit:** `776ccfdc3a37b38f450d4e0c93e13a8cb796cd87`

### 2. DoS of Last Redemption Claimability

- **Issue:** If `BasisStrategy.deutilize` executed with an amount slightly smaller than pending deutilization, the last redemption could become unclaimable.
- **PoC:** See test file: `test/unit/BasisStrategy.t.sol:test_deutilize_withSmallerAmount_WhenLastRedeem`.
- **Fix:** Ensured full redemption execution for the last claim.
- **Git Commit:** `6fd7985e11ac0f07893557e11f55758d6719fbe2`

### 3. Free Riding of Entry/Exit Fees

- **Issue:** Entry/exit fees were freed immediately after deposit/withdrawal, enabling unintended profits to the existing depositors.
- **PoC:**
  1. A whale deposits with considerable fees.
  2. Other depositors withdraw, benefiting from whale's entry fee.
  3. The depositor re-deposits, exploiting the system.
- **Fix:** Reserved entry/exit fees for utilization/deutilization operations.
- **Git Commit:** `01912ca8596bd20e82679d9cb827920db976a847`

### 4. Performance Fee Calculation

- **Issue:** The performance fee is not harvested gradually based on the current strategy performance.
- **PoC:**
  1. Assume below parameters:
  - Performance Fee: 20%
  - Hurdle Rate: 5% annually
  2. User deposits $1000 at Day 0.
  3. Strategy generates profits $5 for 36.5 days. (`profit_rate_annual = 5 / 1000 * 10 = 0.05 = 5% where PF is not harvested because the profit rate is not bigger than the hurdle rate`)
  4. Another user deposits $10000 at the same time.
  5. Strategy generates profits $10 for another 3.65 days. (`profit_rate_annual = 15 / 11000 / 0.11 = 0.0124 = 1.24% < hurdle_rate`)
  6. Strategy generates profits $90 for another 3.65 \* 9 days. (`profit_rate_annual = 105 / 11000 * 5 = 0.0477 = 4.77% < hurdle_rate`)
  7. Strategy generates profits $100 for another 36.5 days. (`profit_rate_annual = 205 / 11000 * 10 / 3 = 0.0621 = 6.21% > hurdle_rate`)
  8. Harvest `performance_fee = $205 * 0.2 = $41`
     Ideally, the performance fee should be harvested gradually from Step 5 instead of being done at Step 7.
- **Fix:** Reset the profit calculation by updating `lastHarvestedTimestamp` and `HWM` whenever there is a user action. For `HWM`, it is reset only when the strategy generates profits.
- **Git Commit:** `2e79c33b78506028ca2f40b2321e6b2eaa01fdfd`

### 5. Unwanted Performance Fee Generation

- **Issue:** Performance fee was being calculated and collected even when there was no actual profit above the hurdle rate, due to incorrect HWM management during withdrawal operations.
- **PoC:** When users withdraw, the performance fee calculation was triggered even when the strategy had not generated sufficient profits to exceed the hurdle rate, leading to incorrect fee collection.
- **Fix:** Implemented proper HWM management to ensure performance fees are only calculated when there is actual profit above the hurdle rate, preventing unwanted fee collection.
- **Git Commit:** `6a975f56d8c737661334caf38253e4ee33c7c6c3`

### 6. CEI Pattern Violation in Performance Fee Collection

- **Issue:** Performance fee collection was affected by entry/exit costs due to violation of the Checks-Effects-Interactions (CEI) pattern, potentially leading to incorrect fee calculations.
- **PoC:** When users deposit or withdraw, the performance fee calculation was influenced by the entry/exit costs, which could result in incorrect fee amounts being collected.
- **Fix:** Implemented proper CEI pattern to ensure performance fee calculations are not affected by entry/exit costs, maintaining accurate fee collection.
- **Git Commit:** `91898982d9a102f23eb9f2a68db07ca9ccb4217e`

### 7. Hurdle Rate Guarantee Before Collecting Performance Fee

- **Issue:** Performance fee calculation could potentially invade the hurdle rate, meaning users might not receive the guaranteed minimum profit above the hurdle rate.
- **PoC:** In certain scenarios, the performance fee calculation could result in users receiving less than the hurdle rate profit, violating the intended fee structure.
- **Fix:** Implemented logic to guarantee that performance fees never invade the hurdle rate, ensuring users always receive at least the hurdle rate profit before any performance fees are collected.
- **Git Commit:** `3dd6b3924a3455d6162b503a3deccb5eb22f8f9f`
