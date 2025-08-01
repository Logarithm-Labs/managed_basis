## Cross-chain Strategy Deployment

1. Deploy messengers
   https://github.com/Logarithm-Labs/logarithm_messenger/blob/master/README.md

2. Deploy `GasStation` and `Beacon(BrotherSwapper)` on the destination chain

   ```script
   forge script .\script\01_DeployCommon.s.sol:XDeploy --rpc-url <dest-chain-rpc> --broadcast
   ```

3. Configure messengers on source and destination chains.

- Set messenger addresses [here](script/utils/).
  The messenger address resides in `[Chain]Addresses.sol` format files.
- Set the addresses of `GasStation` and `Beacon(BrotherSwapper)` [here](script/utils/ProtocolAddresses.sol)
- Configure messengers with the deployed gas station and wire on Arbitrum (source) chain.

  ```script
  forge script .\script\crosschain\ConfigMessenger.s.sol:ArbConfigScript --broadcast
  ```

- Configure messengers with the deployed gas station and wire on destination chains.

  ```script
  forge script .\script\crosschain\ConfigMessenger.s.sol:EthConfigScript --broadcast
  ```

4. Deploy and configure strategy collection contracts.

- Upgrade all existing beacon contracts (OffChainManager, SpotManager, XSpotManager, BasisStrategy, LogarithmVault) on Arbitrum chain.

- Deploy proxies for arbitrum (sou.rce) chain strategy collection.

  ```script
  forge script .\script\04_Deploy_X_VIRTUAL_USDC_HL_Prod.s.sol:ArbDeploy --broadcast
  ```

  **Important**: Make sure all strategy parameters are set properly.

- Set the deployed proxy addresses (Vault, Strategy, XSpotManager, OffChainPositionManager) [here](script/utils/ProtocolAddresses.sol)

- Deploy `BrotherSwapper` proxy on destination chain.

  ```script
  forge script .\script\04_Deploy_X_VIRTUAL_USDC_HL_Prod.s.sol:BaseDeploy --broadcast
  ```

- Set the deployed `BrotherSwapper` address [here](script/utils/ProtocolAddresses.sol)

- Register `XSpotManager` with the deployed swapper address.

  ```script
  forge script .\script\04_Deploy_X_VIRTUAL_USDC_HL_Prod.s.sol:ConfigXSpot --broadcast
  ```
