// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {InchAggregatorV6Logic} from "src/libraries/inch/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

contract SpotManager is Initializable, OwnableUpgradeable, ISpotManager {
    using SafeERC20 for IERC20;
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct SpotManagerStorage {
        address strategy;
        address asset;
        address product;
        // manual swap state
        mapping(address => bool) isSwapPool;
        address[] productToAssetSwapPath;
        address[] assetToProductSwapPath;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.SpotManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SpotManagerStorageLocation =
        0x95ef178669169c185a874b31b21c7794e00401fe355c9bd013bddba6545f1000;

    function _getSpotManagerStorage() private pure returns (SpotManagerStorage storage $) {
        assembly {
            $.slot := SpotManagerStorageLocation
        }
    }

    modifier authCaller(address authorized) {
        if (_msgSender() != authorized) {
            revert Errors.CallerNotAuthorized(authorized, _msgSender());
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _owner,
        address _strategy,
        address _asset,
        address _product,
        address[] calldata _assetToProductSwapPath
    ) external initializer {
        __Ownable_init(_owner);

        SpotManagerStorage storage $ = _getSpotManagerStorage();

        $.strategy = _strategy;

        require(_asset != address(0) && _product != address(0));

        $.asset = _asset;
        $.product = _product;

        _setManualSwapPath(_assetToProductSwapPath, _asset, _product);

        // approve strategy to max amount
        IERC20(_asset).approve($.strategy, type(uint256).max);
    }

    function _setManualSwapPath(address[] calldata _assetToProductSwapPath, address _asset, address _product) private {
        SpotManagerStorage storage $ = _getSpotManagerStorage();
        uint256 length = _assetToProductSwapPath.length;
        if (length % 2 == 0 || _assetToProductSwapPath[0] != _asset || _assetToProductSwapPath[length - 1] != _product)
        {
            // length should be odd
            // the first element should be asset
            // the last element should be product
            revert();
        }

        address[] memory _productToAssetSwapPath = new address[](length);
        for (uint256 i; i < length; i++) {
            _productToAssetSwapPath[i] = _assetToProductSwapPath[length - i - 1];
            if (i % 2 != 0) {
                // odd index element of path should be swap pool address
                address pool = _assetToProductSwapPath[i];
                address tokenIn = _assetToProductSwapPath[i - 1];
                address tokenOut = _assetToProductSwapPath[i + 1];
                address token0 = IUniswapV3Pool(pool).token0();
                address token1 = IUniswapV3Pool(pool).token1();
                if ((tokenIn != token0 || tokenOut != token1) && (tokenOut != token0 || tokenIn != token1)) {
                    revert();
                }
                $.isSwapPool[pool] = true;
            }
        }
        $.assetToProductSwapPath = _assetToProductSwapPath;
        $.productToAssetSwapPath = _productToAssetSwapPath;
    }

    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        uint256 amountOut;
        if (swapType == SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), true, swapData);
            if (!success) {
                revert Errors.SwapFailed();
            }
        } else if (swapType == SwapType.MANUAL) {
            SpotManagerStorage storage $ = _getSpotManagerStorage();
            amountOut = ManualSwapLogic.swap(amount, $.assetToProductSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }
        IBasisStrategy(strategy()).spotBuyCallback(amount, amountOut);
    }

    function sell(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        uint256 amountOut;
        if (swapType == SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), false, swapData);
            if (!success) {
                revert Errors.SwapFailed();
            }
        } else if (swapType == SwapType.MANUAL) {
            SpotManagerStorage storage $ = _getSpotManagerStorage();
            amountOut = ManualSwapLogic.swap(amount, $.productToAssetSwapPath);
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }
        IBasisStrategy(strategy()).spotSellCallback(amountOut, amount);
    }

    function exposure() external view returns (uint256) {
        return IERC20(product()).balanceOf(address(this));
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        if (data.length != 96) {
            revert Errors.InvalidCallback();
        }
        _verifyCallback();
        (address tokenIn,, address payer) = abi.decode(data, (address, address, address));
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        if (payer == address(this)) {
            IERC20(tokenIn).safeTransfer(_msgSender(), amountToPay);
        } else {
            IERC20(tokenIn).safeTransferFrom(payer, _msgSender(), amountToPay);
        }
    }

    function _verifyCallback() internal view {
        SpotManagerStorage storage $ = _getSpotManagerStorage();
        if (!$.isSwapPool[_msgSender()]) {
            revert Errors.InvalidCallback();
        }
    }

    function strategy() public view returns (address) {
        return _getSpotManagerStorage().strategy;
    }

    function asset() public view returns (address) {
        return _getSpotManagerStorage().asset;
    }

    function product() public view returns (address) {
        return _getSpotManagerStorage().product;
    }
}
