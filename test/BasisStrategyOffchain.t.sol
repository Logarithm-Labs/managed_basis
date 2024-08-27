// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {InchTest} from "./base/InchTest.sol";
import {GmxV2Test} from "./base/GmxV2Test.sol";
import {OffChainTest} from "./base/OffChainTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";

import {OffChainPositionManager} from "src/OffChainPositionManager.sol";
import {LogarithmOracle} from "src/LogarithmOracle.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {BasisStrategyBaseTest} from "./BasisStrategyBase.t.sol";
import {IPositionManager} from "src/interfaces/IPositionManager.sol";

import {console} from "forge-std/console.sol";

contract BasisStrategyOffchainTest is BasisStrategyBaseTest, OffChainTest {
    function _initTest() internal override {
        // deploy position manager
        address positionManagerImpl = address(new OffChainPositionManager());
        address positionManagerProxy = address(
            new ERC1967Proxy(
                positionManagerImpl,
                abi.encodeWithSelector(
                    OffChainPositionManager.initialize.selector,
                    address(strategy),
                    agent,
                    address(oracle),
                    product,
                    asset,
                    false
                )
            )
        );
        positionManager = OffChainPositionManager(positionManagerProxy);
        vm.label(address(positionManager), "positionManager");

        strategy.setPositionManager(positionManagerProxy);

        _initOffChainTest(asset, product, address(oracle));
    }

    function _positionManager() internal view override returns (IPositionManager) {
        return IPositionManager(positionManager);
    }

    function _excuteOrder() internal override {
        _fullOffChainExecute();
    }

    function _mockChainlinkPriceFeedAnswer(address priceFeed, int256 answer) internal override {
        super._mockChainlinkPriceFeedAnswer(priceFeed, answer);
        _updatePositionNetBalance(positionManager.positionNetBalance());
    }
}
