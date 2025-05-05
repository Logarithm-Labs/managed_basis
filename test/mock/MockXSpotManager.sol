// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {ISwapper} from "src/spot/ISwapper.sol";
import {InchAggregatorV6Logic} from "src/libraries/inch/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";

import {Constants} from "src/libraries/utils/Constants.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

contract MockXSpotManager is ISpotManager, ISwapper {
    using SafeERC20 for IERC20;

    struct CallbackParams {
        bool isPending;
        uint256 assets;
        uint256 products;
    }

    uint256 pendingAssets;
    CallbackParams pendingBuyParams;
    CallbackParams pendingSellParams;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct SpotManagerStorage {
        address strategy;
        address oracle;
        address asset;
        address product;
        uint256 exposure;
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

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorizes a caller if it is the specified account.
    modifier authCaller(address authorized) {
        if (msg.sender != authorized) {
            revert Errors.CallerNotAuthorized(authorized, msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address, /*_owner*/ address _strategy, address[] calldata _assetToProductSwapPath) external {
        SpotManagerStorage storage $ = _getSpotManagerStorage();
        address _asset = IBasisStrategy(_strategy).asset();
        address _product = IBasisStrategy(_strategy).product();

        $.strategy = _strategy;
        $.oracle = IBasisStrategy(_strategy).oracle();
        $.asset = _asset;
        $.product = _product;

        _setManualSwapPath(_assetToProductSwapPath, _asset, _product);

        // approve strategy to max amount
        IERC20(_asset).approve(_strategy, type(uint256).max);
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

    /*//////////////////////////////////////////////////////////////
                             BUY/SELL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Buys product in the spot market.
    ///
    /// @param amount The asset amount to be swapped to product.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        uint256 amountOut;
        if (swapType == SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), true, swapData);
            if (!success) {
                revert Errors.SwapFailed();
            }
        } else if (swapType == SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, assetToProductSwapPath());
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }
        pendingAssets += amount;

        pendingBuyParams = CallbackParams({isPending: true, assets: amount, products: amountOut});
        // IBasisStrategy(msg.sender).spotBuyCallback(amount, amountOut, block.timestamp);
    }

    /// @dev Sells product in the spot market.
    ///
    /// @param amount The product amount to be swapped to asset.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    function sell(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        uint256 amountOut;
        if (swapType == SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amount, asset(), product(), false, swapData);
            if (!success) {
                revert Errors.SwapFailed();
            }
        } else if (swapType == SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amount, productToAssetSwapPath());
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        pendingSellParams = CallbackParams({isPending: true, assets: amountOut, products: amount});
        // IBasisStrategy(msg.sender).spotSellCallback(amountOut, amount, block.timestamp);
    }

    function executeCallback() external {
        if (pendingBuyParams.isPending) {
            _getSpotManagerStorage().exposure += pendingBuyParams.products;
            delete pendingAssets;
            IBasisStrategy(strategy()).spotBuyCallback(
                pendingBuyParams.assets, pendingBuyParams.products, block.timestamp
            );
            delete pendingBuyParams;
        } else if (pendingSellParams.isPending) {
            _getSpotManagerStorage().exposure -= pendingSellParams.products;
            IBasisStrategy(strategy()).spotSellCallback(
                pendingSellParams.assets, pendingSellParams.products, block.timestamp
            );
            delete pendingSellParams;
        }
    }

    /// @dev Returns the product amount in asset.
    function getAssetValue() public view returns (uint256) {
        return pendingAssets + IOracle(oralce()).convertTokenAmount(product(), asset(), exposure());
    }

    /*//////////////////////////////////////////////////////////////
                             SWAP CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (amount0Delta > 0 || amount1Delta > 0) {
            if (data.length != 96) {
                revert Errors.InvalidCallback();
            }
            _verifyCallback();
            (address tokenIn,, address payer) = abi.decode(data, (address, address, address));
            uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
            if (payer == address(this)) {
                IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);
            } else {
                IERC20(tokenIn).safeTransferFrom(payer, msg.sender, amountToPay);
            }
        } else {
            // swaps entirely within 0-liquidity regions are not supported
            revert Errors.SwapWithZeroLiquidity();
        }
    }

    function _verifyCallback() internal view {
        if (!isSwapPool(msg.sender)) {
            revert Errors.InvalidCallback();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The strategy address.
    function strategy() public view returns (address) {
        return _getSpotManagerStorage().strategy;
    }

    /// @notice The oracle address.
    function oralce() public view returns (address) {
        return _getSpotManagerStorage().oracle;
    }

    /// @notice The asset address.
    function asset() public view returns (address) {
        return _getSpotManagerStorage().asset;
    }

    /// @dev The spot exposure that is needed to be hedged by the perpetual positions.
    function exposure() public view returns (uint256) {
        return _getSpotManagerStorage().exposure;
    }

    /// @notice The product address.
    function product() public view returns (address) {
        return _getSpotManagerStorage().product;
    }

    function assetToProductSwapPath() public view returns (address[] memory) {
        return _getSpotManagerStorage().assetToProductSwapPath;
    }

    function productToAssetSwapPath() public view returns (address[] memory) {
        return _getSpotManagerStorage().productToAssetSwapPath;
    }

    function isSwapPool(address pool) public view returns (bool) {
        return _getSpotManagerStorage().isSwapPool[pool];
    }
}
