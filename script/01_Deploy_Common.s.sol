// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {ArbAddresses} from "script/utils/ArbAddresses.sol";
import {Arb, Bsc} from "script/utils/ProtocolAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

import {LogarithmOracle} from "src/oracle/LogarithmOracle.sol";
import {LogarithmVault} from "src/vault/LogarithmVault.sol";
import {BasisStrategy} from "src/strategy/BasisStrategy.sol";
import {GasStation} from "src/gas-station/GasStation.sol";
import {SpotManager} from "src/spot/SpotManager.sol";
import {XSpotManager} from "src/spot/crosschain/XSpotManager.sol";
import {BrotherSwapper} from "src/spot/crosschain/BrotherSwapper.sol";
import {OffChainPositionManager} from "src/hedge/offchain/OffChainPositionManager.sol";
import {StrategyConfig} from "src/strategy/StrategyConfig.sol";
import {OffChainConfig} from "src/hedge/offchain/OffChainConfig.sol";
// import {DataProvider} from "src/DataProvider.sol";

contract ArbDeploy is Script {
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

    // HL config
    uint256 constant increaseSizeMin = 50 * 1e6;
    uint256 constant decreaseSizeMin = 50 * 1e6;
    uint256 constant increaseCollateralMin = 5 * 1e6;
    uint256 constant decreaseCollateralMin = 1000 * 1e6;
    uint256 constant limitDecreaseCollateral = 5000 * 1e6;

    function run() public {
        // uint256 privateKey = vm.envUint("PRIVATE_KEY");
        // vm.createSelectFork("arbitrum_one");
        vm.startBroadcast( /* privateKey */ );

        LogarithmOracle oracle = DeployHelper.deployLogarithmOracle(owner);
        // configure oracle for USDC
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
        address vaultImpl = address(new LogarithmVault());
        console.log("Impl(Vault): ", vaultImpl);
        address vaultBeacon = DeployHelper.deployBeacon(vaultImpl, owner);
        console.log("Beacon(Vault): ", vaultBeacon);

        // deploy BasisStrategyBeacon
        address strategyImpl = address(new BasisStrategy());
        console.log("Impl(Strategy): ", strategyImpl);
        address strategyBeacon = DeployHelper.deployBeacon(strategyImpl, owner);
        console.log("Beacon(Strategy): ", strategyBeacon);

        // deploy SpotManagerBeacon
        address spotManagerImpl = address(new SpotManager());
        console.log("Impl(SpotManager): ", spotManagerImpl);
        address spotManagerBeacon = DeployHelper.deployBeacon(spotManagerImpl, owner);
        console.log("Beacon(SpotManager): ", spotManagerBeacon);

        // deploy XSpotManagerBeacon
        address xSpotManagerImpl = address(new XSpotManager());
        console.log("Impl(XSpotManager): ", xSpotManagerImpl);
        address xSpotManagerBeacon = DeployHelper.deployBeacon(xSpotManagerImpl, owner);
        console.log("Beacon(XSpotManager): ", xSpotManagerBeacon);

        // deploy OffChainPositionManagerBeacon
        address OffChainPositionManagerImpl = address(new OffChainPositionManager());
        console.log("Impl(OffChainPositionManager): ", OffChainPositionManagerImpl);
        address offchainPositionManagerBeacon = DeployHelper.deployBeacon(OffChainPositionManagerImpl, owner);
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
        // DataProvider dataProvider = new DataProvider();
        // console.log("DataProvider:", address(dataProvider));

        vm.stopBroadcast();
    }
}

contract XDeploy is Script {
    address constant owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;

    function run() public {
        vm.startBroadcast();
        // deploy GasStation
        GasStation gasStation = DeployHelper.deployGasStation(owner);
        console.log("GasStation:", address(gasStation));
        // deploy BrotherSwapper beacon
        address swapperBeacon = DeployHelper.deployBeacon(address(new BrotherSwapper()), owner);
        console.log("Beacon(BrotherSwapper): ", swapperBeacon);
        vm.stopBroadcast();
    }
}
