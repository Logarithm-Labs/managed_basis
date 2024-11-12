// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {PositionMngerForkTest} from "./PositionMngerForkTest.sol";

import {IDataStore} from "src/externals/gmx-v2/interfaces/IDataStore.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {Keys} from "src/externals/gmx-v2/libraries/Keys.sol";
import {GmxV2Lib} from "src/libraries/gmx/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/hedge/gmx/GmxV2PositionManager.sol";
import {GmxGasStation} from "src/hedge/gmx/GmxGasStation.sol";
import {GmxConfig} from "src/hedge/gmx/GmxConfig.sol";
import {IHedgeManager} from "src/hedge/IHedgeManager.sol";

import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";
import {DeployHelper} from "script/utils/DeployHelper.sol";

contract GmxV2Test is PositionMngerForkTest {
    address constant GMX_DATA_STORE = ArbiAddresses.GMX_DATA_STORE;
    address constant GMX_EXCHANGE_ROUTER = ArbiAddresses.GMX_EXCHANGE_ROUTER;
    address constant GMX_ORDER_HANDLER = ArbiAddresses.GMX_ORDER_HANDLER;
    address constant GMX_ORDER_VAULT = ArbiAddresses.GMX_ORDER_VAULT;
    address constant GMX_READER = ArbiAddresses.GMX_READER;
    address constant GMX_ETH_USDC_MARKET = ArbiAddresses.GMX_ETH_USDC_MARKET;
    address constant GMX_KEEPER = ArbiAddresses.GMX_KEEPER;

    address constant CHAINLINK_PRICE_FEED_PROVIDER = 0x527FB0bCfF63C47761039bB386cFE181A92a4701;

    GmxV2PositionManager hedgeManager;

    function _initPositionManager(address owner, address strategy) internal override returns (address) {
        vm.startPrank(owner);
        // deploy config
        GmxConfig config = DeployHelper.deployGmxConfig(owner);
        vm.label(address(config), "config");

        // deploy gmxGasStation
        GmxGasStation gmxGasStation = DeployHelper.deployGmxGasStation(owner);
        vm.label(address(gmxGasStation), "gmxGasStation");

        // topup gmxGasStation with some native token, in practice, its don't through gmxGasStation
        vm.deal(address(gmxGasStation), 10000 ether);

        // deploy hedgeManager beacon
        address hedgeManagerBeacon = DeployHelper.deployBeacon(address(new GmxV2PositionManager()), owner);
        // deploy positionMnager beacon proxy
        hedgeManager = DeployHelper.deployGmxPositionManager(
            DeployHelper.GmxPositionManagerDeployParams(
                hedgeManagerBeacon, address(config), strategy, address(gmxGasStation), GMX_ETH_USDC_MARKET
            )
        );
        vm.label(address(hedgeManager), "hedgeManager");
        vm.stopPrank();

        return address(hedgeManager);
    }

    function _executeOrder() internal override {
        _executeOrder(hedgeManager.pendingDecreaseOrderKey());
        _executeOrder(hedgeManager.pendingIncreaseOrderKey());
    }

    function _hedgeManager() internal view override returns (IHedgeManager) {
        return IHedgeManager(hedgeManager);
    }

    function _executeOrder(bytes32 key) internal {
        if (key != bytes32(0)) {
            IOrderHandler.SetPricesParams memory oracleParams;
            address indexToken = hedgeManager.indexToken();
            address longToken = hedgeManager.longToken();
            address shortToken = hedgeManager.shortToken();
            vm.startPrank(GMX_ORDER_HANDLER);
            IDataStore(GMX_DATA_STORE).setAddress(
                Keys.oracleProviderForTokenKey(indexToken), CHAINLINK_PRICE_FEED_PROVIDER
            );
            IDataStore(GMX_DATA_STORE).setAddress(
                Keys.oracleProviderForTokenKey(longToken), CHAINLINK_PRICE_FEED_PROVIDER
            );
            IDataStore(GMX_DATA_STORE).setAddress(
                Keys.oracleProviderForTokenKey(shortToken), CHAINLINK_PRICE_FEED_PROVIDER
            );
            if (indexToken == longToken) {
                address[] memory tokens = new address[](2);
                tokens[0] = indexToken;
                tokens[1] = shortToken;

                address[] memory providers = new address[](2);
                providers[0] = CHAINLINK_PRICE_FEED_PROVIDER;
                providers[1] = CHAINLINK_PRICE_FEED_PROVIDER;

                bytes[] memory data = new bytes[](2);
                data[0] = "";
                data[1] = "";

                oracleParams.tokens = tokens;
                oracleParams.providers = providers;
                oracleParams.data = data;
            } else {
                address[] memory tokens = new address[](3);
                tokens[0] = indexToken;
                tokens[1] = longToken;
                tokens[2] = shortToken;

                address[] memory providers = new address[](3);
                providers[0] = CHAINLINK_PRICE_FEED_PROVIDER;
                providers[1] = CHAINLINK_PRICE_FEED_PROVIDER;
                providers[2] = CHAINLINK_PRICE_FEED_PROVIDER;

                bytes[] memory data = new bytes[](3);
                data[0] = "";
                data[1] = "";
                data[2] = "";

                oracleParams.tokens = tokens;
                oracleParams.providers = providers;
                oracleParams.data = data;
            }
            vm.startPrank(GMX_KEEPER);
            IOrderHandler(GMX_ORDER_HANDLER).executeOrder(key, oracleParams);
        }
    }

    function _getPositionInfo(address oracle) internal view returns (ReaderUtils.PositionInfo memory) {
        return GmxV2Lib.getPositionInfo(
            GmxV2Lib.GmxParams({
                market: Market.Props({
                    marketToken: hedgeManager.marketToken(),
                    indexToken: hedgeManager.indexToken(),
                    longToken: hedgeManager.longToken(),
                    shortToken: hedgeManager.shortToken()
                }),
                dataStore: GMX_DATA_STORE,
                reader: GMX_READER,
                account: address(hedgeManager),
                collateralToken: hedgeManager.collateralToken(),
                isLong: hedgeManager.isLong()
            }),
            oracle,
            IOrderHandler(GMX_ORDER_HANDLER).referralStorage()
        );
    }
}
