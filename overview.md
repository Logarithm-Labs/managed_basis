# Extended Audit Overview

## Introduction

We have introduced cross-chain spot buy/sell operations to enhance protocol functionality and efficiency.

## Scope

### New Components

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

- **`LzLogMessenger.sol`**  
  _Path: `logarithm-messenger/contracts/LzLogMessenger.sol`_

  - Manages cross-chain messaging by utilizing LayerZero.
  - Bridges assets (e.g., USDC) between smart contracts across multiple chains by utilizing Stargate.

- **`GasConsumer.sol`**  
  _Path: `logarithm-messenger/contracts/common/GasConsumer.sol`_
  - Common interface for utilizing the Gas Station.

## New Features

### 1. Asynchronous Deutilization

- **Description:** Spot operations require time, creating inefficiencies in hedge adjustments.
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

- **Description:**
- **Solution:** Capped the utilization/deutilization amount by a certain threshold that is derived by percentage of `idleAssets + utilizedAssets`.
- **Git Commit:** `79c23e6d95bb4b84eea3ac4ebc7ace2822eb3323`

## Self-Found Issues and Fixes

### 1. DoS in `LogarithmVault.requestRedeem`

- **Issue:** An attacker could manipulate asset transfers, leading to failed redemption requests.
- **PoC:**
  1. Vault initially holds 100,000 assets.
  2. Victim deposits 199,999,999 assets and receives `199,999,999 * (0 + 1) / (100,000 + 1) = 1,999` shares.
  3. Operator utilizes all assets.
  4. Attacker transfers 1 asset to the Vault.
  5. Victim’s redemption request fails due to incorrect share calculations resulting in none-zero 1 shares to withdraw immediately utilizing the idle assets in the Vault. The calculated asset amount to withdraw immediately becomes `1 * 200,100,000 / 1,999 = 100,100` which is bigger than 1.
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
  2. Other depositors withdraw, benefiting from whale’s entry fee.
  3. The depositor re-deposits, exploiting the system.
- **Fix:** Reserved entry/exit fees for utilization/deutilization operations.
- **Git Commit:** `01912ca8596bd20e82679d9cb827920db976a847`
