// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapV3SwapCallback} from "src/externals/uniswap/interfaces/IUniswapV3SwapCallback.sol";
import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";

/// @dev oracle based swap pool
contract UniswapV3MockPool {
    using SafeCast for uint256;
    using SafeCast for int256;

    address public immutable token0;
    address public immutable token1;
    IOracle public immutable oracle;
    int24 public immutable currentTick;

    constructor(address _token0, address _token1, address _oracle, int24 _currentTick) {
        bool zeroForOne = _token0 < _token1;
        token0 = zeroForOne ? _token0 : _token1;
        token1 = zeroForOne ? _token1 : _token0;
        oracle = IOracle(_oracle);
        currentTick = _currentTick;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160, /* sqrtPriceLimitX96 */
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        bool exactInput = amountSpecified > 0;
        int256 amountCalculated;
        if (zeroForOne == exactInput) {
            if (exactInput) {
                amountCalculated = -int256(oracle.convertTokenAmount(token0, token1, uint256(amountSpecified)));
            } else {
                amountCalculated = int256(oracle.convertTokenAmount(token0, token1, uint256(-amountSpecified)));
            }
            (amount0, amount1) = (amountSpecified, amountCalculated);
        } else {
            if (exactInput) {
                amountCalculated = -int256(oracle.convertTokenAmount(token1, token0, uint256(amountSpecified)));
            } else {
                amountCalculated = int256(oracle.convertTokenAmount(token1, token0, uint256(-amountSpecified)));
            }
            (amount0, amount1) = (amountCalculated, amountSpecified);
        }

        if (zeroForOne) {
            if (amount1 < 0) IERC20(token1).transfer(recipient, uint256(-amount1));
        } else {
            if (amount0 < 0) IERC20(token0).transfer(recipient, uint256(-amount0));
        }
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(currentTick) * (uint256(ManualSwapLogic.TWAP_INTERVAL).toInt256()).toInt56();
    }
}
