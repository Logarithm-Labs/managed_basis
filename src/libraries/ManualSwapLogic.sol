// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "src/externals/uniswap/libraries/TickMath.sol";

import {Errors} from "src/libraries/Errors.sol";

library ManualSwapLogic {
    using SafeCast for uint256;

    function swap(uint256 amountIn, address[] memory path) external returns (uint256 amountOut) {
        address tokenIn = path[0];
        uint256 balance = IERC20(tokenIn).balanceOf(address(this));
        if (balance < amountIn) {
            revert Errors.SwapAmountExceedsBalance(amountIn, balance);
        }

        uint256 amountInCached = amountIn;
        for (uint256 i = 0; i <= path.length / 2; i += 2) {
            address pool = path[i + 1];
            amountIn = exactInputInternal(
                amountIn, address(this), pool, path[i] < path[i + 2], abi.encode(path[i], path[i + 2], address(this))
            );
        }
        amountOut = amountIn;
    }

    function exactInputInternal(uint256 amountIn, address recipient, address pool, bool zeroForOne, bytes memory data)
        internal
        returns (uint256 amountOut)
    {
        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            recipient,
            zeroForOne,
            amountIn.toInt256(),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            data
        );
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }
}
