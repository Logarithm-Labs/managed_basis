// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {InchTest} from "test/base/InchTest.sol";

import {InchAggregatorV6Logic} from "src/libraries/inch/InchAggregatorV6Logic.sol";
import {ArbiAddresses} from "script/utils/ArbiAddresses.sol";

contract InchSpecTest is InchTest {
    using stdStorage for StdStorage;

    address public usdcWhale = 0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7;

    address public asset = ArbiAddresses.USDC; // USDC
    address public product = ArbiAddresses.WETH; // WETH

    function setUp() public {
        _forkArbitrum(262638255);
    }

    function test_inchSwap() public {
        uint256 amount = 1000 * 1e6;
        _writeTokenBalance(address(this), asset, amount);
        bytes memory data = _generateInchCallData(asset, product, amount, address(this));
        InchAggregatorV6Logic.executeSwap(amount, asset, product, true, data);
        console.log("amountOut: ", IERC20(product).balanceOf(address(this)));
    }
}
