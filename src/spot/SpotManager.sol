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

/// @title SpotManager
///
/// @author Logarithm Labs
///
/// @notice SpotManager is a dedicated smart contract that manages spot positions
/// for a trading strategy, enabling it to buy or sell assets on a decentralized exchange (DEX)
/// or other spot market. This manager operates in tandem with a basis strategy,
/// allowing it to adjust the spot position dynamically based on the strategy’s target exposure.
/// The primary objective is to provide liquidity for the basis trade, maintaining optimal
/// spot exposure relative to the short hedge position.
///
/// @dev SpotManager is an upgradeable smart contract, deployed through the beacon proxy pattern.
contract SpotManager is Initializable, Ownable2StepUpgradeable, ISpotManager, ISwapper {
    using SafeERC20 for IERC20;

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

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorizes a caller if it is the specified account.
    modifier authCaller(address authorized) {
        if (_msgSender() != authorized) {
            revert Errors.CallerNotAuthorized(authorized, _msgSender());
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address _owner, address _strategy, address[] calldata _assetToProductSwapPath)
        external
        initializer
    {
        __Ownable_init(_owner);

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

    /// @inheritdoc ISpotManager
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
        _getSpotManagerStorage().exposure += amountOut;
        emit SwapProcessed(swapType, amount, amountOut, true);

        IBasisStrategy(_msgSender()).spotBuyCallback(amount, amountOut, block.timestamp);
    }

    /// @inheritdoc ISpotManager
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
        _getSpotManagerStorage().exposure -= amount;
        emit SwapProcessed(swapType, amountOut, amount, false);

        IBasisStrategy(_msgSender()).spotSellCallback(amountOut, amount, block.timestamp);
    }

    /// @inheritdoc ISpotManager
    function getAssetValue() public view returns (uint256) {
        return IOracle(oralce()).convertTokenAmount(product(), asset(), exposure());
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
                IERC20(tokenIn).safeTransfer(_msgSender(), amountToPay);
            } else {
                IERC20(tokenIn).safeTransferFrom(payer, _msgSender(), amountToPay);
            }
        } else {
            // swaps entirely within 0-liquidity regions are not supported
            revert Errors.SwapWithZeroLiquidity();
        }
    }

    function _verifyCallback() internal view {
        if (!isSwapPool(_msgSender())) {
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

    /// @inheritdoc ISpotManager
    function asset() public view returns (address) {
        return _getSpotManagerStorage().asset;
    }

    /// @inheritdoc ISpotManager
    function exposure() public view returns (uint256) {
        return _getSpotManagerStorage().exposure;
    }

    /// @inheritdoc ISpotManager
    function product() public view returns (address) {
        return _getSpotManagerStorage().product;
    }

    /// @inheritdoc ISwapper
    function assetToProductSwapPath() public view returns (address[] memory) {
        return _getSpotManagerStorage().assetToProductSwapPath;
    }

    /// @inheritdoc ISwapper
    function productToAssetSwapPath() public view returns (address[] memory) {
        return _getSpotManagerStorage().productToAssetSwapPath;
    }

    /// @inheritdoc ISwapper
    function isSwapPool(address pool) public view returns (bool) {
        return _getSpotManagerStorage().isSwapPool[pool];
    }

    /// @inheritdoc ISpotManager
    function isXChain() public pure returns (bool) {
        return false;
    }
}
