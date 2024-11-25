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
        _forkArbitrum(0);
    }

    function test_inchSwap_woFees(uint256 amount) public {
        amount = bound(amount, 1000, 50000 * 1e6);
        _writeTokenBalance(address(this), asset, amount);
        bytes memory data = _generateInchCallData(asset, product, amount, address(this));
        (uint256 amountOut, bool success) = InchAggregatorV6Logic.executeSwap(amount, asset, product, true, data);
        assertTrue(success, "swap failed");
        uint256 productBalance = IERC20(product).balanceOf(address(this));
        assertEq(amountOut, productBalance, "product balance");
    }

    function test_inchSwap_withFees(uint256 amount) public {
        amount = bound(amount, 1000, 50000 * 1e6);
        uint256 amountWoFee = amount * 999 / 1000;
        _writeTokenBalance(address(this), asset, amountWoFee);
        bytes memory data = _generateInchCallData(asset, product, amount, address(this));
        (uint256 amountOut, bool success) = InchAggregatorV6Logic.executeSwap(amountWoFee, asset, product, true, data);
        assertTrue(success, "swap failed");
        uint256 productBalance = IERC20(product).balanceOf(address(this));
        assertEq(amountOut, productBalance, "product balance");
    }
}
