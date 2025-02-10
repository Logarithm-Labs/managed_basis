// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";
import {DataProvider} from "src/DataProvider.sol";

contract ArbDeploy is Script {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    // HL config
    uint256 constant increaseSizeMin = 15 * 1e6;
    uint256 constant decreaseSizeMin = 15 * 1e6;
    uint256 constant increaseCollateralMin = 5 * 1e6;
    uint256 constant decreaseCollateralMin = 10 * 1e6;
    uint256 constant limitDecreaseCollateral = 50 * 1e6;

    function run() public {
        vm.startBroadcast();

        LogarithmOracle oracle = DeployHelper.deployLogarithmOracle(owner);
        // configure oracle for DOGE
        address[] memory assets = new address[](1);
        address[] memory feeds = new address[](1);
        uint256[] memory heartbeats = new uint256[](1);
        assets[0] = ArbAddresses.USDC;
        feeds[0] = ArbAddresses.CHL_USDC_USD_PRICE_FEED;
        heartbeats[0] = 24 * 3600;
        oracle.setPriceFeeds(assets, feeds);
        oracle.setHeartbeats(feeds, heartbeats);
        console.log("Oracle: ", address(oracle));

        // use the current deployed gas station
        // // deploy GasStation
        // GasStation gasStation = DeployHelper.deployGasStation(owner);
        // console.log("GasStation:", address(gasStation));

        // deploy LogarithmVaultBeacon
        address vaultBeacon = DeployHelper.deployBeacon(address(new LogarithmVault()), owner);
        console.log("Beacon(Vault): ", vaultBeacon);

        // deploy BasisStrategyBeacon
        address strategyBeacon = DeployHelper.deployBeacon(address(new BasisStrategy()), owner);
        console.log("Beacon(Strategy): ", strategyBeacon);

        address spotManagerBeacon = DeployHelper.deployBeacon(address(new SpotManager()), owner);
        console.log("Beacon(SpotManager): ", spotManagerBeacon);

        address xSpotManagerBeacon = DeployHelper.deployBeacon(address(new XSpotManager()), owner);
        console.log("Beacon(XSpotManager): ", xSpotManagerBeacon);

        // deploy OffChainPositionManagerBeacon
        address offchainPositionManagerBeacon = DeployHelper.deployBeacon(address(new OffChainPositionManager()), owner);
        console.log("Beacon(OffChainPositionManager): ", offchainPositionManagerBeacon);

        // deploy BasisStrategyConfig
        StrategyConfig strategyConfig = DeployHelper.deployStrategyConfig(owner);
        console.log("Strategy Config: ", address(strategyConfig));

        // deploy HL Config
        OffChainConfig hlConfig = DeployHelper.deployOffChainConfig(owner);
        hlConfig.setSizeMin(increaseSizeMin, decreaseSizeMin);
        hlConfig.setCollateralMin(increaseCollateralMin, decreaseCollateralMin);
        hlConfig.setLimitDecreaseCollateral(limitDecreaseCollateral);
        console.log("HL Config: ", address(hlConfig));

        // deploy DataProvider
        DataProvider dataProvider = new DataProvider();
        console.log("DataProvider:", address(dataProvider));

        vm.stopBroadcast();
    }
}

contract XDeploy is Script {
    address constant owner = 0xDaFed9a0A40f810FCb5C3dfCD0cB3486036414eb;

    function run() public {
        vm.startBroadcast();
        // deploy BrotherSwapper beacon
        address swapperBeacon = DeployHelper.deployBeacon(address(new BrotherSwapper()), owner);
        console.log("Beacon(BrotherSwapper): ", swapperBeacon);
        vm.stopBroadcast();
    }
}
