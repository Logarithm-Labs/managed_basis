// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IStargate} from "src/externals/stargate/interfaces/IStargate.sol";
import {IUniswapV3Pool} from "src/externals/uniswap/interfaces/IUniswapV3Pool.sol";

import {ISpotManager} from "src/spot/ISpotManager.sol";
import {ILogarithmMessenger, SendParams as LogSendParams} from "src/messenger/ILogarithmMessenger.sol";
import {InchAggregatorV6Logic} from "src/libraries/inch/InchAggregatorV6Logic.sol";
import {ManualSwapLogic} from "src/libraries/uniswap/ManualSwapLogic.sol";
import {StargateUtils} from "src/libraries/stargate/StargateUtils.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

contract BrotherSwapper is Initializable, OwnableUpgradeable, ILayerZeroComposer {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    address public immutable asset;
    address public immutable product;
    address public immutable endpoint;
    address public immutable stargate;
    address public immutable messenger;
    bytes32 public immutable dstSpotManager;
    uint32 public immutable dstEid;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/
    struct BrotherSwapperStorage {
        // manual swap state
        mapping(address => bool) isSwapPool;
        address[] assetToProductSwapPath;
        address[] productToAssetSwapPath;
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
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _asset,
        address _product,
        address _endpoint,
        address _stargate,
        address _messenger,
        bytes32 _dstSpotManager,
        uint32 _dstEid
    ) {
        asset = _asset;
        product = _product;
        // validate stargate
        if (IStargate(_stargate).token() != _asset) {
            revert Errors.InvalidStargate();
        }
        stargate = _stargate;
        endpoint = _endpoint;
        messenger = _messenger;
        dstEid = _dstEid;
        dstSpotManager = _dstSpotManager;
    }

    function initialize(address _owner, address[] calldata _assetToProductSwapPath) external initializer {
        __Ownable_init(_owner);
        _setManualSwapPath(_assetToProductSwapPath, asset, product);
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

    /*//////////////////////////////////////////////////////////////
                            CROSSCHAIN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Called after asset has been transferred to this.
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable {
        require(_from == stargate, "!stargate");
        require(_msgSender() == endpoint, "!endpoint");
        require(msg.value >= StargateUtils.COMPOSE_CALL_VALUE);

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        bytes memory _composeMessage = OFTComposeMsgCodec.composeMsg(_message);

        (ISpotManager.SwapType swapType, bytes memory swapData) =
            abi.decode(_composeMessage, (ISpotManager.SwapType, bytes));

        uint256 amountOut;
        if (swapType == ISpotManager.SwapType.INCH_V6) {
            bool success;
            (amountOut, success) = InchAggregatorV6Logic.executeSwap(amountLD, asset, product, true, swapData);
            if (!success) {
                revert Errors.SwapFailed();
            }
        } else if (swapType == ISpotManager.SwapType.MANUAL) {
            amountOut = ManualSwapLogic.swap(amountLD, assetToProductSwapPath());
        } else {
            // TODO: fallback swap
            revert Errors.UnsupportedSwapType();
        }

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        ILogarithmMessenger(messenger).sendMessage{value: msg.value}(
            LogSendParams({
                dstEid: dstEid,
                receiver: dstSpotManager,
                payload: abi.encode(amountOut),
                lzReceiveOption: options
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                            UNISWAP CALLBACK
    //////////////////////////////////////////////////////////////*/

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
        if (isSwapPool(_msgSender())) {
            revert Errors.InvalidCallback();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    function isSwapPool(address pool) public view returns (bool) {
        return _getBrotherSwapperStorage().isSwapPool[pool];
    }

    function assetToProductSwapPath() public view returns (address[] memory) {
        return _getBrotherSwapperStorage().assetToProductSwapPath;
    }

    function productToAssetSwapPath() public view returns (address[] memory) {
        return _getBrotherSwapperStorage().productToAssetSwapPath;
    }

    receive() external payable {}
}
