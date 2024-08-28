// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "src/externals/1inch/interfaces/IAggregationRouterV6.sol";
import "src/externals/uniswap/interfaces/IUniswapPool.sol";

import "./AddressLib.sol";
import "./ProtocolLib.sol";

import "forge-std/console.sol";

library InchAggregatorV6Logic {
    using AddressLib for Address;
    using ProtocolLib for Address;

    error InchInvalidSourceToken(address sourceToken, address requiredSourceToken);
    error InchInvalidDestinationToken(address destinationToken, address requiredDestinationToken);
    error InchInvalidReceiver(address receiver, address requiredReceiver);
    error InchInsufficientSourceBalance(uint256 sourceAmount, uint256 sourceBalance);
    error InchInvalidAmount(uint256 requestedAmountIn, uint256 unpackedAmountIn);

    address private constant _AGGREGATOR_V6_ADDRESS = 0x111111125421cA6dc452d289314280a0f8842A65;
    uint256 private constant _UNISWAP_ZERO_FOR_ONE_OFFSET = 247;
    uint256 private constant _UNISWAP_ZERO_FOR_ONE_MASK = 0x01;
    uint256 private constant _CURVE_TO_COINS_SELECTOR_OFFSET = 208;
    uint256 private constant _CURVE_TO_COINS_SELECTOR_MASK = 0xff;
    uint256 private constant _CURVE_TO_COINS_ARG_OFFSET = 216;
    uint256 private constant _CURVE_TO_COINS_ARG_MASK = 0xff;
    address private constant _ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 private constant _CURVE_COINS_SELECTORS = 0x87cb4f5723746eb8c6610657b739953eb9947eb0000000000000000000000000;

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
            address pool = dex.get();
            assembly ("memory-safe") {
                function reRevert() {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
                function curveCoins(curvePool, selectorOffset, index) -> coin {
                    mstore(0, _CURVE_COINS_SELECTORS)
                    mstore(add(selectorOffset, 4), index)
                    if iszero(staticcall(gas(), curvePool, selectorOffset, 0x24, 0, 0x20)) { reRevert() }
                    coin := mload(0)
                }
                let toSelectorOffset := and(shr(_CURVE_TO_COINS_SELECTOR_OFFSET, dex), _CURVE_TO_COINS_SELECTOR_MASK)
                let toTokenIndex := and(shr(_CURVE_TO_COINS_ARG_OFFSET, dex), _CURVE_TO_COINS_ARG_MASK)
                tokenOut := curveCoins(pool, toSelectorOffset, toTokenIndex)
            }
        }
    }

    function executeSwap(uint256 amount, address asset, address product, bool isUtilize, bytes calldata data)
        external
        returns (uint256 amountOut, bool success)
    {
        // unpack swap data
        (address srcToken, address dstToken, uint256 amountIn, address receiver) = _unpackSwapData(data);

        // validate swap data and approve ERC20
        if (amount != amountIn) {
            revert InchInvalidAmount(amount, amountIn);
        }
        if (isUtilize) {
            if (srcToken != asset) {
                revert InchInvalidSourceToken(srcToken, asset);
            }
            if (dstToken != product) {
                revert InchInvalidDestinationToken(dstToken, product);
            }
        } else {
            if (srcToken != product) {
                revert InchInvalidSourceToken(srcToken, product);
            }
            if (dstToken != asset) {
                revert InchInvalidDestinationToken(dstToken, asset);
            }
        }
        if (receiver != address(this)) {
            revert InchInvalidReceiver(receiver, address(this));
        }
        uint256 sourceBalance;
        if (srcToken == _ETH_ADDRESS) {
            sourceBalance = address(this).balance;
        } else {
            sourceBalance = IERC20(srcToken).balanceOf(address(this));
            IERC20(srcToken).approve(_AGGREGATOR_V6_ADDRESS, amountIn);
        }
        if (sourceBalance < amountIn) {
            revert InchInsufficientSourceBalance(amountIn, sourceBalance);
        }

        // perform swap
        bytes memory result;
        (success, result) = _AGGREGATOR_V6_ADDRESS.call{value: msg.value}(data);
        if (success) {
            amountOut = abi.decode(result, (uint256));
        } else {
            IERC20(srcToken).approve(_AGGREGATOR_V6_ADDRESS, 0);
        }
    }

    function _unpackSwapData(bytes calldata data)
        internal
        view
        returns (address srcToken, address dstToken, uint256 amountIn, address receiver)
    {
        bytes4 selector = bytes4(data[:4]);
        if (selector == IAggregationRouterV6.swap.selector) {
            ( /*address executor*/ , IAggregationRouterV6.SwapDescription memory desc, /*bytes memory swapData*/ ) =
                abi.decode(data[4:], (address, IAggregationRouterV6.SwapDescription, bytes));
            srcToken = desc.srcToken;
            dstToken = desc.dstToken;
            amountIn = desc.amount;
            receiver = desc.dstReceiver;
        } else {
            Address finalDex;
            if (selector == IAggregationRouterV6.unoswap.selector) {
                (Address token, uint256 amount, /*uint256 minReturn*/, Address dex) =
                    abi.decode(data[4:], (Address, uint256, uint256, Address));
                srcToken = token.get();
                finalDex = dex;
                amountIn = amount;
                receiver = address(this);
            } else if (selector == IAggregationRouterV6.unoswapTo.selector) {
                (Address to, Address token, uint256 amount, /*uint256 minReturn*/, Address dex) =
                    abi.decode(data[4:], (Address, Address, uint256, uint256, Address));
                srcToken = token.get();
                finalDex = dex;
                amountIn = amount;
                receiver = to.get();
            } else if (selector == IAggregationRouterV6.unoswap2.selector) {
                (Address token, uint256 amount, /*uint256 minReturn*/, /*Address dex*/, Address dex2) =
                    abi.decode(data[4:], (Address, uint256, uint256, Address, Address));
                srcToken = token.get();
                finalDex = dex2;
                amountIn = amount;
                receiver = address(this);
            } else if (selector == IAggregationRouterV6.unoswapTo2.selector) {
                (Address to, Address token, uint256 amount, /*uint256 minReturn*/, /*Address dex*/, Address dex2) =
                    abi.decode(data[4:], (Address, Address, uint256, uint256, Address, Address));
                srcToken = token.get();
                finalDex = dex2;
                amountIn = amount;
                receiver = to.get();
            } else if (selector == IAggregationRouterV6.unoswap3.selector) {
                (Address token, uint256 amount, /*uint256 minReturn*/, /*Address dex*/, /*Address dex2*/, Address dex3)
                = abi.decode(data[4:], (Address, uint256, uint256, Address, Address, Address));
                srcToken = token.get();
                finalDex = dex3;
                amountIn = amount;
                receiver = address(this);
            } else if (selector == IAggregationRouterV6.unoswapTo3.selector) {
                (
                    Address to,
                    Address token,
                    uint256 amount, /*uint256 minReturn*/
                    , /*Address dex*/
                    , /*Address dex2*/
                    ,
                    Address dex3
                ) = abi.decode(data[4:], (Address, Address, uint256, uint256, Address, Address, Address));
                srcToken = token.get();
                finalDex = dex3;
                amountIn = amount;
                receiver = to.get();
            } else if (selector == IAggregationRouterV6.ethUnoswap.selector) {
                ( /*uint256 minReturn*/ , Address dex) = abi.decode(data[4:], (uint256, Address));
                srcToken = _ETH_ADDRESS;
                finalDex = dex;
                amountIn = msg.value;
                receiver = address(this);
            } else if (selector == IAggregationRouterV6.ethUnoswapTo.selector) {
                (Address to, /*uint256 minReturn*/, Address dex) = abi.decode(data[4:], (Address, uint256, Address));
                srcToken = _ETH_ADDRESS;
                finalDex = dex;
                amountIn = msg.value;
                receiver = to.get();
            } else if (selector == IAggregationRouterV6.ethUnoswap2.selector) {
                ( /*uint256 minReturn*/ , /*Address dex*/, Address dex2) =
                    abi.decode(data[4:], (uint256, Address, Address));
                srcToken = _ETH_ADDRESS;
                finalDex = dex2;
                amountIn = msg.value;
                receiver = address(this);
            } else if (selector == IAggregationRouterV6.ethUnoswapTo2.selector) {
                (Address to, /*uint256 minReturn*/, /*Address dex*/, Address dex2) =
                    abi.decode(data[4:], (Address, uint256, Address, Address));
                srcToken = _ETH_ADDRESS;
                finalDex = dex2;
                amountIn = msg.value;
                receiver = to.get();
            } else if (selector == IAggregationRouterV6.ethUnoswap3.selector) {
                ( /*uint256 minReturn*/ , /*Address dex*/, /*Address dex2*/, Address dex3) =
                    abi.decode(data[4:], (uint256, Address, Address, Address));
                srcToken = _ETH_ADDRESS;
                finalDex = dex3;
                amountIn = msg.value;
                receiver = address(this);
            } else if (selector == IAggregationRouterV6.ethUnoswapTo3.selector) {
                (Address to, /*uint256 minReturn*/, /*Address dex*/, /*Address dex2*/, Address dex3) =
                    abi.decode(data[4:], (Address, uint256, Address, Address, Address));
                srcToken = _ETH_ADDRESS;
                finalDex = dex3;
                amountIn = msg.value;
                receiver = to.get();
            }
            dstToken = _getTokenOut(finalDex);
        }
    }
}
