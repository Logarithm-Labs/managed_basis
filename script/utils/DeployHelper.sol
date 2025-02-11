// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";

import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";

import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";

import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {ArbAddresses} from "./ArbAddresses.sol";

import {console} from "forge-std/console.sol";

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
                    GmxConfig.initialize.selector, owner, ArbAddresses.GMX_EXCHANGE_ROUTER, ArbAddresses.GMX_READER
                )
            )
        );
        GmxConfig gmxConfig = GmxConfig(gmxConfigProxy);
        require(gmxConfig.owner() == owner, "GmxConfig owner is not the expected owner");
        return gmxConfig;
    }

    function deployGasStation(address owner) internal returns (GasStation) {
        address gasStationImpl = address(new GasStation());
        address gasStationProxy =
            address(new ERC1967Proxy(gasStationImpl, abi.encodeWithSelector(GasStation.initialize.selector, owner)));
        return GasStation(payable(gasStationProxy));
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
        GmxV2PositionManager positionManager = GmxV2PositionManager(payable(gmxPositionManagerProxy));
        BasisStrategy(params.strategy).setHedgeManager(address(positionManager));
        require(
            BasisStrategy(params.strategy).hedgeManager() == address(positionManager),
            "Strategy positionManager is not the expected positionManager"
        );
        GasStation(payable(params.gasStation)).registerManager(address(positionManager), true);
        return positionManager;
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

    struct DeployXSpotManagerParams {
        address beacon;
        address owner;
        address strategy;
        address messenger;
        uint256 dstChainId;
    }

    function deployXSpotManager(DeployXSpotManagerParams memory params) internal returns (XSpotManager) {
        address xSpotManagerProxy = address(
            new BeaconProxy(
                params.beacon,
                abi.encodeWithSelector(
                    XSpotManager.initialize.selector, params.owner, params.strategy, params.messenger, params.dstChainId
                )
            )
        );
        XSpotManager spotManager = XSpotManager(payable(xSpotManagerProxy));
        BasisStrategy(params.strategy).setSpotManager(xSpotManagerProxy);
        return spotManager;
    }

    struct DeployBrotherSwapperParams {
        address beacon;
        address owner;
        address asset;
        address product;
        address messenger;
        bytes32 spotManager;
        uint256 dstChainId;
        address[] assetToProductSwapPath;
    }

    function deployBrotherSwapper(DeployBrotherSwapperParams memory params) internal returns (BrotherSwapper) {
        address swapperProxy = address(
            new BeaconProxy(
                params.beacon,
                abi.encodeWithSelector(
                    BrotherSwapper.initialize.selector,
                    params.owner,
                    params.asset,
                    params.product,
                    params.messenger,
                    params.spotManager,
                    params.dstChainId,
                    params.assetToProductSwapPath
                )
            )
        );
        return BrotherSwapper(payable(swapperProxy));
    }

    struct DeployHLVaultParams {
        address owner;
        string name;
        string symbol;
        address asset;
        address product;
        address productPriceFeed;
        uint256 productPriceFeedHeartbeats;
        uint256 entryCost;
        uint256 exitCost;
        address operator;
        address agent;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        address[] assetToProductSwapPath;
    }

    function deployHLVault(DeployHLVaultParams memory params) internal {
        // configure oracle
        LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        uint256[] memory heartbeats = new uint256[](1);
        assets[0] = params.product;
        feeds[0] = params.productPriceFeed;
        heartbeats[0] = params.productPriceFeedHeartbeats;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        console.log("Product oracle configured!");

        // deploy LogarithmVault
        LogarithmVaultDeployParams memory vaultDeployParams = LogarithmVaultDeployParams({
            beacon: Arb.BEACON_VAULT,
            owner: params.owner,
            asset: params.asset,
            priorityProvider: address(0),
            entryCost: params.entryCost,
            exitCost: params.exitCost,
            name: params.name,
            symbol: params.symbol
        });
        LogarithmVault vault = deployLogarithmVault(vaultDeployParams);
        console.log("Vault: ", address(vault));

        // deploy BasisStrategy
        BasisStrategyDeployParams memory strategyDeployParams = BasisStrategyDeployParams({
            owner: params.owner,
            beacon: Arb.BEACON_STRATEGY,
            config: Arb.CONFIG_STRATEGY,
            product: params.product,
            vault: address(vault),
            oracle: Arb.ORACLE,
            operator: params.operator,
            targetLeverage: params.targetLeverage,
            minLeverage: params.minLeverage,
            maxLeverage: params.maxLeverage,
            safeMarginLeverage: params.safeMarginLeverage
        });
        BasisStrategy strategy = deployBasisStrategy(strategyDeployParams);
        console.log("Strategy: ", address(strategy));

        // deploy SpotManager
        SpotManager spotManager =
            deploySpotManager(Arb.BEACON_SPOT_MANAGER, params.owner, address(strategy), params.assetToProductSwapPath);
        console.log("SpotManager: ", address(spotManager));

        // deploy OffChainPositionManager
        OffChainPositionManager positionManager = deployOffChainPositionManager(
            OffChainPositionManagerDeployParams({
                owner: params.owner,
                config: Arb.CONFIG_HL,
                beacon: Arb.BEACON_OFF_CHAIN_POSITION_MANAGER,
                strategy: address(strategy),
                agent: params.agent,
                oracle: Arb.ORACLE,
                product: params.product,
                asset: params.asset,
                isLong: false
            })
        );
        console.log("OffChainPositionManager: ", address(positionManager));
    }

    struct DeployHLVaultXParams {
        address owner;
        string name;
        string symbol;
        address asset;
        address product;
        address productPriceFeed;
        uint256 productPriceFeedHeartbeats;
        uint256 entryCost;
        uint256 exitCost;
        address operator;
        address agent;
        uint256 targetLeverage;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 safeMarginLeverage;
        uint256 dstChainId;
    }

    function deployHLVaultX(DeployHLVaultXParams memory params) internal {
        // configure oracle
        LogarithmOracle oracle = LogarithmOracle(Arb.ORACLE);
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        uint256[] memory heartbeats = new uint256[](1);
        assets[0] = params.product;
        feeds[0] = params.productPriceFeed;
        heartbeats[0] = params.productPriceFeedHeartbeats;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        console.log("Product oracle configured!");

        // deploy LogarithmVault
        DeployHelper.LogarithmVaultDeployParams memory vaultDeployParams = DeployHelper.LogarithmVaultDeployParams({
            beacon: Arb.BEACON_VAULT,
            owner: params.owner,
            asset: params.asset,
            priorityProvider: address(0),
            entryCost: params.entryCost,
            exitCost: params.exitCost,
            name: params.name,
            symbol: params.symbol
        });
        LogarithmVault vault = DeployHelper.deployLogarithmVault(vaultDeployParams);
        console.log("Vault: ", address(vault));

        // deploy BasisStrategy
        DeployHelper.BasisStrategyDeployParams memory strategyDeployParams = DeployHelper.BasisStrategyDeployParams({
            owner: params.owner,
            beacon: Arb.BEACON_STRATEGY,
            config: Arb.CONFIG_STRATEGY,
            product: params.product,
            vault: address(vault),
            oracle: Arb.ORACLE,
            operator: params.operator,
            targetLeverage: params.targetLeverage,
            minLeverage: params.minLeverage,
            maxLeverage: params.maxLeverage,
            safeMarginLeverage: params.safeMarginLeverage
        });
        BasisStrategy strategy = DeployHelper.deployBasisStrategy(strategyDeployParams);
        console.log("Strategy: ", address(strategy));

        // deploy XSpotManager
        // deploy Gmx spot manager
        DeployHelper.DeployXSpotManagerParams memory xSpotDeployParams = DeployHelper.DeployXSpotManagerParams({
            beacon: Arb.BEACON_X_SPOT_MANAGER,
            owner: params.owner,
            strategy: address(strategy),
            messenger: ArbAddresses.LOGARITHM_MESSENGER,
            dstChainId: params.dstChainId
        });
        XSpotManager xSpotManager = DeployHelper.deployXSpotManager(xSpotDeployParams);
        console.log("XSpotManager: ", address(xSpotManager));

        // deploy OffChainPositionManager
        OffChainPositionManager positionManager = DeployHelper.deployOffChainPositionManager(
            DeployHelper.OffChainPositionManagerDeployParams({
                owner: params.owner,
                config: Arb.CONFIG_HL,
                beacon: Arb.BEACON_OFF_CHAIN_POSITION_MANAGER,
                strategy: address(strategy),
                agent: params.agent,
                oracle: Arb.ORACLE,
                product: params.product,
                asset: params.asset,
                isLong: false
            })
        );
        console.log("OffChainPositionManager: ", address(positionManager));
    }
}
