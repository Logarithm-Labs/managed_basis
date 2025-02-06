// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";
import {FixedPoint96} from "src/externals/uniswap/libraries/FixedPoint96.sol";
import {TickMath} from "src/externals/uniswap/libraries/TickMath.sol";

import {Errors} from "src/libraries/utils/Errors.sol";

library ManualSwapLogic {
    using SafeCast for uint256;

    uint32 constant TWAP_INTERVAL = 30; //30s
    uint16 constant SLIPPAGE_TOLERANCE_BPS = 50; // 100 bps = 1%

    function swap(uint256 amountIn, address[] memory path) external returns (uint256 amountOut) {
        address tokenIn = path[0];
        uint256 balance = IERC20(tokenIn).balanceOf(address(this));
        if (balance < amountIn) {
            revert Errors.SwapAmountExceedsBalance(amountIn, balance);
        }

        for (uint256 i; i <= path.length / 2; i += 2) {
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
        // quote output amounts based on twap
        uint160 sqrtTwapX96 = getSqrtTwapX96(pool, TWAP_INTERVAL);
        uint256 minAmountOut =
            getQuoteAmount(sqrtTwapX96, amountIn, zeroForOne) * (10000 - SLIPPAGE_TOLERANCE_BPS) / 10000;
        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            recipient,
            zeroForOne,
            amountIn.toInt256(),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            data
        );
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < minAmountOut) {
            revert Errors.SwapBelowMinimum(amountOut, minAmountOut);
        }
    }

    function getSqrtTwapX96(address uniswapV3Pool, uint32 twapInterval) internal view returns (uint160 sqrtPriceX96) {
        if (twapInterval == 0) {
            // return the current price if twapInterval == 0
            (sqrtPriceX96,,,,,,) = IUniswapV3Pool(uniswapV3Pool).slot0();
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = twapInterval; // from (before)
            secondsAgos[1] = 0; // to (now)

            (int56[] memory tickCumulatives,) = IUniswapV3Pool(uniswapV3Pool).observe(secondsAgos);
            int256 tickCumulativesDelta = int256(tickCumulatives[1] - tickCumulatives[0]);
            int256 twapIntervalInt256 = int256(uint256(twapInterval));
            int256 arithmeticMeanTick = tickCumulativesDelta / twapIntervalInt256;
            // Always round to negative infinity
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % twapIntervalInt256 != 0)) arithmeticMeanTick--;
            sqrtPriceX96 = TickMath.getSqrtRatioAtTick(SafeCast.toInt24(arithmeticMeanTick));
        }
    }

    function getQuoteAmount(uint160 sqrtPriceX96, uint256 amountIn, bool zeroForOne) internal pure returns (uint256) {
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        uint256 amountOut = zeroForOne
            ? Math.mulDiv(amountIn, priceX96, FixedPoint96.Q96)
            : Math.mulDiv(amountIn, FixedPoint96.Q96, priceX96);
        return amountOut;
    }
}
