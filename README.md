
# Basis Strategy Smart Contract System

## Overview

The basis strategy smart contract system is designed to execute a strategy that buys assets in spot markets and hedges these positions by selling perpetual contracts. This approach offsets market exposure and generates revenue from funding payments on perpetual contracts. The system includes four main components:

1. **LogarithmVault** - Manages user deposits and withdrawals and approves the strategy to access its funds.
2. **BasisStrategy** - Implements the basis strategy by orchestrating trades between `SpotManager` and `HedgeManager`.
3. **SpotManager** - Handles trading in spot markets (e.g., Uniswap).
4. **HedgeManager** - Manages perpetual positions on protocols like GMX to offset spot exposure.

---

## Components and Interactions

### 1. LogarithmVault

**Purpose**: The `LogarithmVault` serves as the user interface for depositing and withdrawing funds. It also approves the `BasisStrategy` to use its funds, allowing it to execute trades. `LogarithmVault` tracks individual user balances and overall vault balance.

**Core Functions**:
- **deposit/mint**: Accepts user funds, adding them to the pool available for the basis strategy.
- **requestWithdraw/requestRedeem**: Allows users to withdraw their funds, including any accrued gains.
- **isClaimable/claim**: Allows users to claim assets from the executed withdraw requests.

### 2. BasisStrategy

**Purpose**: The `BasisStrategy` contract manages the basis trading logic by utilizing `SpotManager` for spot trades and `HedgeManager` for perpetual trades. It maintains a market-neutral position by holding opposite positions in spot and perpetual markets, generating funding payment revenue.

**Core Functions**:
- **utilize**: Uses `SpotManager` to buy assets in the spot market and `HedgeManager` to place short positions in the perpetual market, thereby hedging the spot exposure.
- **deutilize**: Reallocates spot and perpetual holdings based on funding rates, user withdrawals, and market volatility.
- **pendingUtilizations**: Helps operators determine the parameters of calling `utilize`/`deutilize` functions by returning the maximum amounts.
- **checkUpkeep/performUpkeep**: Allows keepers to safe the perpetual position's leverage, claim funding payments, and rehedge the spot.

### 3. SpotManager

**Purpose**: `SpotManager` is responsible for executing trades in the spot market, such as Uniswap, to gain exposure to the underlying asset.

**Core Functions**:
- **buy**: Executes buy orders for specific assets in the spot market.
- **sell**: Executes sell orders to reduce spot exposure or free up liquidity.

### 4. HedgeManager

**Purpose**: The `HedgeManager` adjusts the perpetual hedge, selling short to offset spot exposure. It interacts with perpetual protocols (e.g., GMX) and manages funding payments to generate revenue.

**Core Functions**:
- **adjustPosition**: Places short orders in the perpetual market to hedge the spot position. Closes or adjusts short positions in response to changing conditions or withdrawal demands. Modifies the short position size based on market prices and funding rate trends.
- **keep**: Collects funding payments and distributes them back to the collateral of the perpetual position.

#### **Implementations**:
Different protocol-specific managers are implemented to operate across different perpetual protocols.
- `GmxV2PositionManager`: `HedgeManager` specific for GMX protocol.
- `OffChainPositionManager`: `HedgeManager` specific for off-chain perpetual protocols including HyperLiquid.

---