// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ForkTest} from "test/base/ForkTest.sol";

import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";
import {ArbAddresses} from "script/utils/ArbAddresses.sol";

contract ManualSwapTest is ForkTest {
    address public asset = ArbAddresses.USDC; // USDC
    address public product = ArbAddresses.WETH; // WETH

    function setUp() public {
        _forkArbitrum(0);
    }

    function test_getSqrtTwapX96() public view {
        uint160 sqrtPriceX96 = ManualSwapLogic.getSqrtTwapX96(UNI_V3_POOL_WETH_USDC, 30);
        uint256 quote = ManualSwapLogic.getQuoteAmount(sqrtPriceX96, 1 ether, true);
        console.log("weth quote in usdc", quote);
    }

    function test_revert_frontrunning() public {
        uint256 assetsOfAttacker = 1_000_000_000_000;
        uint256 assetsOfVictim = 300_000_000;
        _writeTokenBalance(address(this), asset, assetsOfAttacker + assetsOfVictim);
        address[] memory swapPath = new address[](3);
        swapPath[0] = asset;
        swapPath[1] = UNI_V3_POOL_WETH_USDC;
        swapPath[2] = product;
        // do front running with huge assets
        ManualSwapLogic.swap(assetsOfAttacker, swapPath);
        // the following swap will get failed due to slippage
        vm.expectRevert();
        ManualSwapLogic.swap(assetsOfVictim, swapPath);
    }

    function test_swap_assetToProduct(uint256 amount) public {
        amount = bound(amount, 1 * 1e6, 10000 * 1e6);
        _writeTokenBalance(address(this), asset, amount);
        address[] memory swapPath = new address[](3);
        swapPath[0] = asset;
        swapPath[1] = UNI_V3_POOL_WETH_USDC;
        swapPath[2] = product;
        uint256 amountOut = ManualSwapLogic.swap(amount, swapPath);
        uint256 productBalance = IERC20(product).balanceOf(address(this));
        assertEq(amountOut, productBalance);
    }

    function test_swap_productToAsset(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 10 ether);
        _writeTokenBalance(address(this), product, amount);
        address[] memory swapPath = new address[](3);
        swapPath[0] = product;
        swapPath[1] = UNI_V3_POOL_WETH_USDC;
        swapPath[2] = asset;
        uint256 amountOut = ManualSwapLogic.swap(amount, swapPath);
        uint256 productBalance = IERC20(asset).balanceOf(address(this));
        assertEq(amountOut, productBalance);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address tokenIn,, address payer) = abi.decode(data, (address, address, address));
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        if (payer == address(this)) {
            IERC20(tokenIn).transfer(msg.sender, amountToPay);
        } else {
            IERC20(tokenIn).transferFrom(payer, msg.sender, amountToPay);
        }
    }
}
