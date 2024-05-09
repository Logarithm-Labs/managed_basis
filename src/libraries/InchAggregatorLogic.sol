// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/interfaces/IERC20.sol";
import "src/interfaces/IAggregationRouter.sol";
import "src/interfaces/IUniswapPool.sol";
import "src/libraries/AddressLib.sol";
import "src/libraries/ProtocolLib.sol";

library InchAggregatorLogic {
    using AddressLib for Address;
    using ProtocolLib for Address;

    uint256 private constant _UNISWAP_ZERO_FOR_ONE_OFFSET = 247;
    uint256 private constant _UNISWAP_ZERO_FOR_ONE_MASK = 0x01;

    function _getZeroForOne(Address dex) internal pure returns (bool zeroForOne) {
        assembly ("memory-safe") {
            zeroForOne := and(shr(_UNISWAP_ZERO_FOR_ONE_OFFSET, dex), _UNISWAP_ZERO_FOR_ONE_MASK)
        }
    }

    function _getTokenOut(Address dex) internal view returns (address tokenOut) {
        ProtocolLib.Protocol protocol = dex.protocol();
        if (protocol != ProtocolLib.Protocol.Curve) {
            bool zeroForOne;
            assembly ("memory-safe") {
                zeroForOne := and(shr(_UNISWAP_ZERO_FOR_ONE_OFFSET, dex), _UNISWAP_ZERO_FOR_ONE_MASK)
            }
            address pool = dex.get();
            tokenOut = zeroForOne ? IUniswapPool(pool).token1() : IUniswapPool(pool).token0();
        } else {
            

        }

    }

    function _prepareInchSwap(
        address asset, 
        address product,
        bool isUtilize, 
        bytes calldata data
    ) internal {
        bytes4 selector = bytes4(data[:4]);
        address srcToken;
        address dstToken;
        uint256 amount;
        if (selector == IAggregationRouter.swap.selector) {
            (address executor, IAggregationRouter.SwapDescription memory desc, bytes memory swapData) = abi.decode(data[4:], (address, IAggregationRouter.SwapDescription, bytes));
            srcToken = desc.srcToken;
            dstToken = desc.dstToken;
            amount = desc.amount;
        } else if (selector == IAggregationRouter.unoswap.selector) {
            (Address token, uint256 amount, uint256 minReturn, Address dex) = abi.decode(data[4:], (Address, uint256, uint256, Address));
            srcToken = token.get();
            ProtocolLib.Protocol protocol = dex.protocol();
            if (protocol == ProtocolLib.Protocol.UniswapV2) {

            }


        }
    }
}