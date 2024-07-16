// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {IPriceFeed} from "src/externals/chainlink/interfaces/IPriceFeed.sol";

import {MockPriceFeed} from "../mock/MockPriceFeed.sol";
import {ArbGasInfoMock} from "../mock/ArbGasInfoMock.sol";
import {ArbSysMock} from "../mock/ArbSysMock.sol";

contract ForkTest is Test {
    uint256 constant USDC_PRECISION = 1e6;

    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    address constant USDC_WHALE = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;
    address constant WETH_WHALE = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;

    function _forkArbitrum() internal {
        uint256 arbitrumFork = vm.createFork(vm.rpcUrl("arbitrum_one"));
        vm.selectFork(arbitrumFork);
        // vm.rollFork(213168025);

        // L2 contracts explicitly reference 0x64 for the ArbSys precompile
        // and 0x6C for the ArbGasInfo precompile
        // We'll replace it with the mock
        address _arbsys = address(new ArbSysMock());
        address _arbgasinfo = address(new ArbGasInfoMock());
        vm.etch(address(100), _arbsys.code);
        vm.etch(address(108), _arbgasinfo.code);
    }

    function _mockChainlinkPriceFeed(address priceFeed) internal {
        (uint80 roundID, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IPriceFeed(priceFeed).latestRoundData();
        uint8 decimals = IPriceFeed(priceFeed).decimals();
        address mockPriceFeed = address(new MockPriceFeed());
        vm.etch(priceFeed, mockPriceFeed.code);
        MockPriceFeed(priceFeed).setOracleData(roundID, answer, startedAt, updatedAt, answeredInRound, decimals);
    }

    function _mockChainlinkPriceFeedAnswer(address priceFeed, int256 answer) internal {
        MockPriceFeed(priceFeed).updatePrice(answer);
    }

    function _moveTimestamp(uint256 deltaTime, address[] memory priceFeeds) internal {
        uint256 targetTimestamp = vm.getBlockTimestamp() + deltaTime;
        vm.warp(targetTimestamp);
        uint256 len = priceFeeds.length;
        for (uint256 i; i < len; i++) {
            MockPriceFeed(priceFeeds[i]).setUpdatedAt(targetTimestamp);
        }
    }
}
