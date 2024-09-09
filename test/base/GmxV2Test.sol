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
import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";
import {GmxGasStation} from "src/GmxGasStation.sol";
import {GmxConfig} from "src/GmxConfig.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

contract GmxV2Test is PositionMngerForkTest {
    address constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_EXCHANGE_ROUTER = 0x69C527fC77291722b52649E45c838e41be8Bf5d5;
    address constant GMX_ORDER_HANDLER = 0xB0Fc2a48b873da40e7bc25658e5E6137616AC2Ee;
    address constant GMX_ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address constant GMX_READER = 0x5Ca84c34a381434786738735265b9f3FD814b824;
    address constant GMX_ETH_USDC_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address constant GMX_KEEPER = 0xE47b36382DC50b90bCF6176Ddb159C4b9333A7AB;

    address constant CHAINLINK_PRICE_FEED_PROVIDER = 0x527FB0bCfF63C47761039bB386cFE181A92a4701;

    GmxV2PositionManager positionManager;

    function _initPositionManager(address owner, address strategy) internal override returns (address) {
        vm.startPrank(owner);
        // deploy config
        GmxConfig config = new GmxConfig();
        config.initialize(owner, GMX_EXCHANGE_ROUTER, GMX_READER);
        vm.label(address(config), "config");

        // deploy gmxGasStation
        address gmxGasStationImpl = address(new GmxGasStation());
        address gmxGasStationProxy = address(
            new ERC1967Proxy(gmxGasStationImpl, abi.encodeWithSelector(GmxGasStation.initialize.selector, owner))
        );
        GmxGasStation gmxGasStation = GmxGasStation(payable(gmxGasStationProxy));
        vm.label(address(gmxGasStation), "gmxGasStation");

        // topup gmxGasStation with some native token, in practice, its don't through gmxGasStation
        vm.deal(address(gmxGasStation), 10000 ether);

        // deploy positionManager impl
        address positionManagerImpl = address(new GmxV2PositionManager());
        // deploy positionManager beacon
        address positionManagerBeacon = address(new UpgradeableBeacon(positionManagerImpl, owner));
        // deploy positionMnager beacon proxy
        address positionManagerProxy = address(
            new BeaconProxy(
                positionManagerBeacon,
                abi.encodeWithSelector(
                    GmxV2PositionManager.initialize.selector,
                    owner,
                    strategy,
                    address(config),
                    address(gmxGasStation),
                    GMX_ETH_USDC_MARKET
                )
            )
        );
        positionManager = GmxV2PositionManager(payable(positionManagerProxy));

        vm.label(address(positionManager), "positionManager");

        gmxGasStation.registerPositionManager(positionManagerProxy, true);
        vm.stopPrank();

        return address(positionManager);
    }

    function _excuteOrder() internal override {
        _executeOrder(positionManager.pendingDecreaseOrderKey());
        _executeOrder(positionManager.pendingIncreaseOrderKey());
    }

    function _positionManager() internal view override returns (IPositionManager) {
        return IPositionManager(positionManager);
    }

    function _executeOrder(bytes32 key) internal {
        if (key != bytes32(0)) {
            IOrderHandler.SetPricesParams memory oracleParams;
            address indexToken = positionManager.indexToken();
            address longToken = positionManager.longToken();
            address shortToken = positionManager.shortToken();
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
                    marketToken: positionManager.marketToken(),
                    indexToken: positionManager.indexToken(),
                    longToken: positionManager.longToken(),
                    shortToken: positionManager.shortToken()
                }),
                dataStore: GMX_DATA_STORE,
                reader: GMX_READER,
                account: address(positionManager),
                collateralToken: positionManager.collateralToken(),
                isLong: positionManager.isLong()
            }),
            oracle,
            IOrderHandler(GMX_ORDER_HANDLER).referralStorage()
        );
    }
}
