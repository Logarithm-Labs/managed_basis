// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";

import {ISpotManager} from "src/spot/ISpotManager.sol";
import {ISwapper} from "src/spot/ISwapper.sol";
import {InchAggregatorV6Logic} from "src/libraries/inch/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";
import {IMessageRecipient} from "src/messenger/IMessageRecipient.sol";
import {ILogarithmMessenger, SendParams} from "src/messenger/ILogarithmMessenger.sol";

import {AssetValueTransmitter} from "./AssetValueTransmitter.sol";

contract BrotherSwapper is Initializable, AssetValueTransmitter, OwnableUpgradeable, IMessageRecipient, ISwapper {
    using SafeERC20 for IERC20;

    struct SwapRequest {
        uint256 amount;
        uint256 minOutAmount;
        ISpotManager.SwapType swapType;
        bool isBuy;
        uint128 gasLimit;
        uint256 round;
        uint256 collateralDeltaAmount;
    }

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/
    struct BrotherSwapperStorage {
        address asset;
        address product;
        address messenger;
        bytes32 spotManager;
        uint256 dstChainId;
        // manual swap state
        mapping(address => bool) isSwapPool;
        address[] assetToProductSwapPath;
        address[] productToAssetSwapPath;
        SwapRequest pendingRequest;
        address operator;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.BrotherSwapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BrotherSwapperStorageLocation =
        0xabc3963a5264186f9e97dea2c679c9f12f278465b7a504a419228ef309a2c300;

    function _getBrotherSwapperStorage() private pure returns (BrotherSwapperStorage storage $) {
        assembly {
            $.slot := BrotherSwapperStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when swap operation is requested.
    event SwapRequested(ISpotManager.SwapType indexed swapType, uint256 indexed quoteAmount, bool indexed isBuy);

    /// @dev Emitted when cross-chain messenger gets updated.
    event MessengerUpdated(address indexed caller, address indexed newMessenger);

    /// @dev Emitted when a new hedge request from strategy is created.
    event CreateRequest(
        uint256 indexed round, uint256 sizeDeltaInTokens, uint256 collateralDeltaAmount, bool isIncrease
    );

    event OperatorSet(address indexed newOperator);

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

    modifier onlySpotManager(bytes32 sender) {
        if (sender != spotManager()) {
            revert Errors.InvalidSender();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _owner,
        address _operator,
        address _asset,
        address _product,
        address _messenger,
        bytes32 _spotManager,
        uint256 _dstChainId,
        address[] calldata _assetToProductSwapPath
    ) external initializer {
        BrotherSwapperStorage storage $ = _getBrotherSwapperStorage();
        $.asset = _asset;
        $.product = _product;

        $.dstChainId = _dstChainId;
        $.spotManager = _spotManager;

        _setOperator(_operator);
        _setMessenger(_messenger);
        __AssetValueTransmitter_init(_product);
        __Ownable_init(_owner);
        _setManualSwapPath(_assetToProductSwapPath, _asset, _product);
    }

    function _setManualSwapPath(address[] calldata _assetToProductSwapPath, address _asset, address _product) private {
        BrotherSwapperStorage storage $ = _getBrotherSwapperStorage();
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

    function _setMessenger(address newMessenger) internal {
        if (messenger() != newMessenger) {
            _getBrotherSwapperStorage().messenger = newMessenger;
            emit MessengerUpdated(_msgSender(), newMessenger);
        }
    }

    function _setOperator(address newOperator) internal {
        if (operator() != newOperator) {
            _getBrotherSwapperStorage().operator = newOperator;
            emit OperatorSet(newOperator);
        }
    }

    function _setPendingRequest(
        bool isBuy,
        uint256 amount,
        uint256 minOutAmount,
        ISpotManager.SwapType swapType,
        uint128 gasLimit,
        bytes memory hedgeData
    ) private {
        if (_getBrotherSwapperStorage().pendingRequest.amount != 0) {
            revert Errors.RequestInPending();
        }
        uint256 round;
        uint256 collateralDeltaAmount;
        if (hedgeData.length == 64) {
            (round, collateralDeltaAmount) = abi.decode(hedgeData, (uint256, uint256));
        }
        _getBrotherSwapperStorage().pendingRequest = SwapRequest({
            isBuy: isBuy,
            amount: amount,
            minOutAmount: minOutAmount,
            swapType: swapType,
            gasLimit: gasLimit,
            round: round,
            collateralDeltaAmount: collateralDeltaAmount
        });
        emit SwapRequested(swapType, amount, isBuy);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update cross-chain messenger.
    function setMessenger(address newMessenger) external onlyOwner {
        _setMessenger(newMessenger);
    }

    /// @notice Modify the manual swap path
    function setManualSwapPath(address[] calldata _assetToProductSwapPath) external onlyOwner {
        _setManualSwapPath(_assetToProductSwapPath, asset(), product());
    }

    /// @notice Configure the operator
    function setOperator(address newOperator) external onlyOwner {
        _setOperator(newOperator);
    }

    /*//////////////////////////////////////////////////////////////
                            CROSSCHAIN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Called when asset has been transferred to buy product.
    function receiveToken(bytes32 sender, address token, uint256 amountLD, bytes calldata data)
        external
        authCaller(messenger())
        onlySpotManager(sender)
    {
        if (token != asset()) {
            revert Errors.InvalidTokenSend();
        }
        // decode data
        // data = abi.encode(buyResGasLimit(), minOutAmount, swapType, swapData);
        (uint128 buyResGasLimit, uint64 minOutAmountSD, ISpotManager.SwapType swapType, bytes memory hedgeData) =
            abi.decode(data, (uint128, uint64, ISpotManager.SwapType, bytes));
        uint256 minOutAmountLD = _toLD(minOutAmountSD);
        _setPendingRequest(true, amountLD, minOutAmountLD, swapType, buyResGasLimit, hedgeData);
    }

    /// @dev Called when sell request has been sent from XSpotManager.
    function receiveMessage(bytes32 sender, bytes calldata data)
        external
        authCaller(messenger())
        onlySpotManager(sender)
    {
        (
            uint128 sellResGasLimit,
            uint64 productsSD,
            uint64 minOutAmountSD,
            ISpotManager.SwapType swapType,
            bytes memory hedgeData
        ) = abi.decode(data, (uint128, uint64, uint64, ISpotManager.SwapType, bytes));
        uint256 productsLD = _toLD(productsSD);
        uint256 minOutAmountLD = _toLD(minOutAmountSD);

        _setPendingRequest(false, productsLD, minOutAmountLD, swapType, sellResGasLimit, hedgeData);
    }

    /// @notice Execute swap that is pending
    ///
    /// @param swapData Data used in swap, e.g. Empty for manual swap and non-empty for 1inch.
    function executeSwap(bytes calldata swapData) external authCaller(operator()) {
        SwapRequest memory _pendingRequest = pendingRequest();
        delete _getBrotherSwapperStorage().pendingRequest;

        if (_pendingRequest.amount == 0) {
            revert Errors.NoPendingRequest();
        }

        if (_pendingRequest.isBuy) {
            uint256 productsLD;
            if (_pendingRequest.swapType == ISpotManager.SwapType.INCH_V6) {
                bool success;
                (productsLD, success) =
                    InchAggregatorV6Logic.executeSwap(_pendingRequest.amount, asset(), product(), true, swapData);
                if (!success) {
                    revert Errors.SwapFailed();
                }
                if (productsLD < _pendingRequest.minOutAmount) {
                    revert Errors.ExceedsSlippage();
                }
            } else if (_pendingRequest.swapType == ISpotManager.SwapType.MANUAL) {
                productsLD = ManualSwapLogic.swap(_pendingRequest.amount, assetToProductSwapPath());
            } else {
                // TODO: fallback swap
                revert Errors.UnsupportedSwapType();
            }

            ILogarithmMessenger(messenger()).send(
                SendParams({
                    dstChainId: dstChainId(),
                    receiver: spotManager(),
                    token: address(0),
                    gasLimit: _pendingRequest.gasLimit,
                    amount: 0, // 0 because none of token gets transferred
                    data: abi.encode(_toSD(productsLD), block.timestamp)
                })
            );

            emit SwapProcessed(_pendingRequest.swapType, _pendingRequest.amount, productsLD, true);
            if (_pendingRequest.round != 0) {
                emit CreateRequest(_pendingRequest.round, productsLD, _pendingRequest.collateralDeltaAmount, true);
            }
        } else {
            uint256 assetsLD;
            address _asset = asset();
            if (_pendingRequest.swapType == ISpotManager.SwapType.INCH_V6) {
                bool success;
                (assetsLD, success) =
                    InchAggregatorV6Logic.executeSwap(_pendingRequest.amount, _asset, product(), false, swapData);
                if (!success) {
                    revert Errors.SwapFailed();
                }
                if (assetsLD < _pendingRequest.minOutAmount) {
                    revert Errors.ExceedsSlippage();
                }
            } else if (_pendingRequest.swapType == ISpotManager.SwapType.MANUAL) {
                assetsLD = ManualSwapLogic.swap(_pendingRequest.amount, productToAssetSwapPath());
            } else {
                // TODO: fallback swap
                revert Errors.UnsupportedSwapType();
            }

            ILogarithmMessenger _messenger = ILogarithmMessenger(messenger());
            IERC20(_asset).safeTransfer(address(_messenger), assetsLD);
            _messenger.send(
                SendParams({
                    dstChainId: dstChainId(),
                    receiver: spotManager(),
                    token: _asset,
                    gasLimit: _pendingRequest.gasLimit,
                    amount: assetsLD,
                    data: abi.encode(_toSD(_pendingRequest.amount), block.timestamp)
                })
            );

            emit SwapProcessed(_pendingRequest.swapType, assetsLD, _pendingRequest.amount, false);
            if (_pendingRequest.round != 0) {
                emit CreateRequest(
                    _pendingRequest.round, _pendingRequest.amount, _pendingRequest.collateralDeltaAmount, false
                );
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            UNISWAP CALLBACK
    //////////////////////////////////////////////////////////////*/

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) public {
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

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function _verifyCallback() internal view {
        if (!isSwapPool(_msgSender())) {
            revert Errors.CallerNotRegisteredPool();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function asset() public view returns (address) {
        return _getBrotherSwapperStorage().asset;
    }

    function product() public view returns (address) {
        return _getBrotherSwapperStorage().product;
    }

    /// @notice The address of cross-chain messenger.
    function messenger() public view returns (address) {
        return _getBrotherSwapperStorage().messenger;
    }

    /// @notice The bytes32 value of the address of the spot manager on original chain
    function spotManager() public view returns (bytes32) {
        return _getBrotherSwapperStorage().spotManager;
    }

    /// @notice The chain id of original chain that is used in messenger
    function dstChainId() public view returns (uint256) {
        return _getBrotherSwapperStorage().dstChainId;
    }

    /// @inheritdoc ISwapper
    function isSwapPool(address pool) public view returns (bool) {
        return _getBrotherSwapperStorage().isSwapPool[pool];
    }

    /// @inheritdoc ISwapper
    function assetToProductSwapPath() public view returns (address[] memory) {
        return _getBrotherSwapperStorage().assetToProductSwapPath;
    }

    /// @inheritdoc ISwapper
    function productToAssetSwapPath() public view returns (address[] memory) {
        return _getBrotherSwapperStorage().productToAssetSwapPath;
    }

    /// @notice The struct `SwapRequest` value that is pending for swap.
    function pendingRequest() public view returns (SwapRequest memory) {
        return _getBrotherSwapperStorage().pendingRequest;
    }

    function operator() public view returns (address) {
        return _getBrotherSwapperStorage().operator;
    }
}
