// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ForkTest} from "./ForkTest.sol";

import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";
import {ReaderUtils} from "src/externals/gmx-v2/libraries/ReaderUtils.sol";
import {Market} from "src/externals/gmx-v2/libraries/Market.sol";
import {GmxV2Lib} from "src/libraries/GmxV2Lib.sol";
import {GmxV2PositionManager} from "src/GmxV2PositionManager.sol";

contract GmxV2Test is ForkTest {
    address constant GMX_DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address constant GMX_EXCHANGE_ROUTER = 0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8;
    address constant GMX_ORDER_HANDLER = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;
    address constant GMX_ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    address constant GMX_READER = 0xdA5A70c885187DaA71E7553ca9F728464af8d2ad;
    address constant GMX_ETH_USDC_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;
    address constant GMX_KEEPER = 0xE47b36382DC50b90bCF6176Ddb159C4b9333A7AB;

    GmxV2PositionManager positionManager;

    function _executeOrder(bytes32 key) internal {
        if (key != bytes32(0)) {
            IOrderHandler.SetPricesParams memory oracleParams;
            address indexToken = positionManager.indexToken();
            address longToken = positionManager.longToken();
            address shortToken = positionManager.shortToken();
            if (indexToken == longToken) {
                address[] memory tokens = new address[](2);
                tokens[0] = indexToken;
                tokens[1] = shortToken;
                oracleParams.priceFeedTokens = tokens;
            } else {
                address[] memory tokens = new address[](3);
                tokens[0] = indexToken;
                tokens[1] = longToken;
                tokens[2] = shortToken;
                oracleParams.priceFeedTokens = tokens;
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
