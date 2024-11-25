// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";
import {GmxGasStation} from "src/hedge/gmx/GmxGasStation.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";

import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";

import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";

import {ArbiAddresses} from "./ArbiAddresses.sol";

library DeployHelper {
    function deployBeacon(address implementation, address owner) internal returns (address) {
        UpgradeableBeacon beacon = new UpgradeableBeacon(implementation, owner);
        require(beacon.implementation() == implementation, "Beacon implementation is not the expected implementation");
        require(beacon.owner() == owner, "Beacon owner is not the expected owner");
        return address(beacon);
    }

    struct LogarithmVaultDeployParams {
        address beacon;
        address owner;
        address asset;
        address priorityProvider;
        uint256 entryCost;
        uint256 exitCost;
        string name;
        string symbol;
    }

    function deployLogarithmVault(LogarithmVaultDeployParams memory params) internal returns (LogarithmVault) {
        address vaultProxy = address(
            new BeaconProxy(
                params.beacon,
                abi.encodeWithSelector(
                    LogarithmVault.initialize.selector,
                    params.owner,
                    params.asset,
                    params.priorityProvider,
                    params.entryCost,
                    params.exitCost,
                    params.name,
                    params.symbol
                )
            )
        );
        LogarithmVault vault = LogarithmVault(vaultProxy);
        require(vault.owner() == params.owner, "Vault owner is not the expected owner");
        return vault;
    }

    function deployStrategyConfig(address owner) internal returns (StrategyConfig) {
        address strategyConfigImpl = address(new StrategyConfig());
        address strategyConfigProxy = address(
            new ERC1967Proxy(strategyConfigImpl, abi.encodeWithSelector(StrategyConfig.initialize.selector, owner))
        );
        StrategyConfig strategyConfig = StrategyConfig(strategyConfigProxy);
        require(strategyConfig.owner() == owner, "Config owner is not the expected owner");
        return strategyConfig;
    }

    struct BasisStrategyDeployParams {
        address owner;
        address beacon;
        address config;
        address product;
        address vault;
        address oracle;
        address operator;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
    }

    function deployBasisStrategy(BasisStrategyDeployParams memory params) internal returns (BasisStrategy) {
        address strategyProxy = address(
            new BeaconProxy(
                params.beacon,
                abi.encodeWithSelector(
                    BasisStrategy.initialize.selector,
                    params.config,
                    params.product,
                    params.vault,
                    params.oracle,
                    params.operator,
                    params.targetLeverage,
                    params.minLeverage,
                    params.maxLeverage,
                    params.safeMarginLeverage
                )
            )
        );
        BasisStrategy strategy = BasisStrategy(strategyProxy);
        require(strategy.owner() == params.owner, "Strategy owner is not the expected owner");

        LogarithmVault(params.vault).setStrategy(address(strategy));
        require(
            LogarithmVault(params.vault).strategy() == address(strategy), "Vault strategy is not the expected strategy"
        );

        return strategy;
    }

    function deploySpotManager(address beacon, address owner, address strategy, address[] memory assetToProductSwapPath)
        internal
        returns (SpotManager)
    {
        address spotManagerProxy = address(
            new BeaconProxy(
                beacon, abi.encodeWithSelector(SpotManager.initialize.selector, owner, strategy, assetToProductSwapPath)
            )
        );
        SpotManager spotManager = SpotManager(spotManagerProxy);
        BasisStrategy(strategy).setSpotManager(spotManagerProxy);
        return spotManager;
    }

    function deployGmxConfig(address owner) internal returns (GmxConfig) {
        address gmxConfigImpl = address(new GmxConfig());
        address gmxConfigProxy = address(
            new ERC1967Proxy(
                gmxConfigImpl,
                abi.encodeWithSelector(
                    GmxConfig.initialize.selector, owner, ArbiAddresses.GMX_EXCHANGE_ROUTER, ArbiAddresses.GMX_READER
                )
            )
        );
        GmxConfig gmxConfig = GmxConfig(gmxConfigProxy);
        require(gmxConfig.owner() == owner, "GmxConfig owner is not the expected owner");
        return gmxConfig;
    }

    function deployGmxGasStation(address owner) internal returns (GmxGasStation) {
        address gasStationImpl = address(new GmxGasStation());
        address gasStationProxy =
            address(new ERC1967Proxy(gasStationImpl, abi.encodeWithSelector(GmxGasStation.initialize.selector, owner)));
        return GmxGasStation(payable(gasStationProxy));
    }

    struct GmxPositionManagerDeployParams {
        address beacon;
        address config;
        address strategy;
        address gasStation;
        address marketKey;
    }

    function deployGmxPositionManager(GmxPositionManagerDeployParams memory params)
        internal
        returns (GmxV2PositionManager)
    {
        address gmxPositionManagerProxy = address(
            new BeaconProxy(
                params.beacon,
                abi.encodeWithSelector(
                    GmxV2PositionManager.initialize.selector,
                    params.strategy,
                    params.config,
                    params.gasStation,
                    params.marketKey
                )
            )
        );
        GmxV2PositionManager hedgeManager = GmxV2PositionManager(payable(gmxPositionManagerProxy));
        BasisStrategy(params.strategy).setHedgeManager(address(hedgeManager));
        require(
            BasisStrategy(params.strategy).hedgeManager() == address(hedgeManager),
            "Strategy hedgeManager is not the expected hedgeManager"
        );
        GmxGasStation(payable(params.gasStation)).registerPositionManager(address(hedgeManager), true);
        return hedgeManager;
    }

    function deployOffChainConfig(address owner) internal returns (OffChainConfig) {
        address hlConfigImpl = address(new OffChainConfig());
        address hlConfigProxy =
            address(new ERC1967Proxy(hlConfigImpl, abi.encodeWithSelector(OffChainConfig.initialize.selector, owner)));
        OffChainConfig hlConfig = OffChainConfig(hlConfigProxy);
        require(hlConfig.owner() == owner, "HL Config owner is not the expected owner");
        return hlConfig;
    }

    struct OffChainPositionManagerDeployParams {
        address owner;
        address config;
        address beacon;
        address strategy;
        address agent;
        address oracle;
        address product;
        address asset;
        bool isLong;
    }

    function deployOffChainPositionManager(OffChainPositionManagerDeployParams memory params)
        internal
        returns (OffChainPositionManager)
    {
        address hlPositionManagerProxy = address(
            new BeaconProxy(
                params.beacon,
                abi.encodeWithSelector(
                    OffChainPositionManager.initialize.selector,
                    params.config,
                    params.strategy,
                    params.agent,
                    params.oracle,
                    params.isLong
                )
            )
        );
        OffChainPositionManager hlPositionManager = OffChainPositionManager(hlPositionManagerProxy);
        require(hlPositionManager.owner() == params.owner, "PositionManager owner is not the expected owner");
        require(hlPositionManager.agent() == params.agent, "PositionManager agent is not the expected agent");
        require(hlPositionManager.oracle() == params.oracle, "PositionManager oracle is not the expected oracle");

        BasisStrategy(params.strategy).setHedgeManager(address(hlPositionManager));
        require(
            BasisStrategy(params.strategy).hedgeManager() == address(hlPositionManager),
            "Strategy hedgeManager is not the expected hedgeManager"
        );
        return hlPositionManager;
    }

    function deployLogarithmOracle(address owner) internal returns (LogarithmOracle) {
        address oracleImpl = address(new LogarithmOracle());
        address oracleProxy =
            address(new ERC1967Proxy(oracleImpl, abi.encodeWithSelector(LogarithmOracle.initialize.selector, owner)));
        LogarithmOracle oracle = LogarithmOracle(oracleProxy);
        return oracle;
    }
}
