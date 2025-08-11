// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IBasisStrategy} from "../../strategy/IBasisStrategy.sol";
import {IOracle} from "../../oracle/IOracle.sol";
import {ISpotManager} from "../ISpotManager.sol";
import {Errors} from "../../libraries/utils/Errors.sol";
import {Constants} from "../../libraries/utils/Constants.sol";
import {IMessageRecipient} from "../../messenger/IMessageRecipient.sol";
import {ILogarithmMessenger, SendParams} from "../../messenger/ILogarithmMessenger.sol";

import {AssetValueTransmitter} from "./AssetValueTransmitter.sol";

/// @title XSpotManager
//
/// @author Logarithm Labs
//
/// @notice A spot manager smart contract that sends/receives the asset token
/// to/from BrotherSwapper in the destination blockchain and tracks the product exposure.
///
/// @dev Deployed according to the upgradeable beacon proxy pattern.
contract XSpotManager is Initializable, AssetValueTransmitter, OwnableUpgradeable, IMessageRecipient, ISpotManager {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint16 constant SLIPPAGE_TOLERANCE_BPS = 500; // 5%

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/
    struct XSpotManagerStorage {
        address strategy;
        address oracle;
        address asset;
        address product;
        uint256 exposure;
        address messenger;
        uint256 dstChainId;
        bytes32 swapper;
        uint256 pendingAssets;
        uint128 buyReqGasLimit;
        uint128 buyResGasLimit;
        uint128 sellReqGasLimit;
        uint128 sellResGasLimit;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.XSpotManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant XSpotManagerStorageLocation =
        0x3abd7422ff158b0d91b3113cc1ba11199e6b642a3f69c4ac6a03a1db62498500;

    function _getXSpotManagerStorage() private pure returns (XSpotManagerStorage storage $) {
        assembly {
            $.slot := XSpotManagerStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event SwapperUpdated(address indexed account, bytes32 indexed newSwapper);
    event BuyReqGasLimitUpdated(address indexed account, uint128 indexed newBuyReqGasLimit);
    event BuyResGasLimitUpdated(address indexed account, uint128 indexed newBuyResGasLimit);
    event SellReqGasLimitUpdated(address indexed account, uint128 indexed newSellReqGasLimit);
    event SellResGasLimitUpdated(address indexed account, uint128 indexed newSellResGasLimit);
    event BuyRequested(address indexed caller, SwapType indexed swapType, uint256 assetsSent);
    event SellRequested(address indexed caller, SwapType indexed swapType, uint256 products);
    event MessengerUpdated(address indexed caller, address indexed newMessenger);

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

    modifier onlySwapper(bytes32 sender) {
        if (sender != swapper()) {
            revert Errors.InvalidSender();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address _owner, address _strategy, address _messenger, uint256 _dstChainId)
        external
        initializer
    {
        XSpotManagerStorage storage $ = _getXSpotManagerStorage();
        address _asset = IBasisStrategy(_strategy).asset();
        address _product = IBasisStrategy(_strategy).product();

        $.strategy = _strategy;
        $.oracle = IBasisStrategy(_strategy).oracle();
        $.asset = _asset;
        $.product = _product;

        $.dstChainId = _dstChainId;

        __AssetValueTransmitter_init(_product);
        __Ownable_init(_owner);

        // set big enough initially
        _setBuyReqGasLimit(500_000); // lzCompose()
        _setBuyResGasLimit(300_000); // lzReceive()
        _setSellReqGasLimit(300_000); // lzReceive()
        _setSellResGasLimit(400_000); // lzCompose()
        _setMessenger(_messenger);

        // approve strategy to max amount
        IERC20(_asset).approve(_strategy, type(uint256).max);
    }

    function _setBuyReqGasLimit(uint128 newLimit) internal {
        if (buyReqGasLimit() != newLimit) {
            _getXSpotManagerStorage().buyReqGasLimit = newLimit;
            emit BuyReqGasLimitUpdated(_msgSender(), newLimit);
        }
    }

    function _setBuyResGasLimit(uint128 newLimit) internal {
        if (buyResGasLimit() != newLimit) {
            _getXSpotManagerStorage().buyResGasLimit = newLimit;
            emit BuyResGasLimitUpdated(_msgSender(), newLimit);
        }
    }

    function _setSellReqGasLimit(uint128 newLimit) internal {
        if (sellReqGasLimit() != newLimit) {
            _getXSpotManagerStorage().sellReqGasLimit = newLimit;
            emit SellReqGasLimitUpdated(_msgSender(), newLimit);
        }
    }

    function _setSellResGasLimit(uint128 newLimit) internal {
        if (sellResGasLimit() != newLimit) {
            _getXSpotManagerStorage().sellResGasLimit = newLimit;
            emit SellResGasLimitUpdated(_msgSender(), newLimit);
        }
    }

    function _setMessenger(address newMessenger) internal {
        if (messenger() != newMessenger) {
            _getXSpotManagerStorage().messenger = newMessenger;
            emit MessengerUpdated(_msgSender(), newMessenger);
        }
    }

    /// @notice Sets the address of BrotherSwapper which is in the destination chain.
    ///
    /// @dev Should be set before running stratey.
    function setSwapper(bytes32 newSwapper) external onlyOwner {
        if (newSwapper == bytes32(0)) {
            revert Errors.ZeroAddress();
        }
        if (swapper() != newSwapper) {
            _getXSpotManagerStorage().swapper = newSwapper;
            emit SwapperUpdated(_msgSender(), newSwapper);
        }
    }

    function setBuyReqGasLimit(uint128 newLimit) external onlyOwner {
        _setBuyReqGasLimit(newLimit);
    }

    function setBuyResGasLimit(uint128 newLimit) external onlyOwner {
        _setBuyResGasLimit(newLimit);
    }

    function setSellReqGasLimit(uint128 newLimit) external onlyOwner {
        _setSellReqGasLimit(newLimit);
    }

    function setSellResGasLimit(uint128 newLimit) external onlyOwner {
        _setSellResGasLimit(newLimit);
    }

    function setMessenger(address newMessenger) external onlyOwner {
        _setMessenger(newMessenger);
    }

    /*//////////////////////////////////////////////////////////////
                               MAIN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISpotManager
    function buy(uint256 amountLD, SwapType swapType, bytes calldata hedgeData) external authCaller(strategy()) {
        _getXSpotManagerStorage().pendingAssets = amountLD;
        address _asset = asset();
        // calc min amount
        uint256 oracleAmount = IOracle(oracle()).convertTokenAmount(_asset, product(), amountLD);
        uint256 minOutAmount = oracleAmount * (10000 - SLIPPAGE_TOLERANCE_BPS) / 10000;
        // build message data
        bytes memory messageData = abi.encode(buyResGasLimit(), _toSD(minOutAmount), swapType, hedgeData);
        ILogarithmMessenger _messenger = ILogarithmMessenger(messenger());
        // send
        IERC20(_asset).safeTransfer(address(_messenger), amountLD);
        _messenger.send(
            SendParams({
                dstChainId: dstChainId(),
                receiver: swapper(),
                token: _asset,
                gasLimit: buyReqGasLimit(),
                amount: amountLD,
                data: messageData
            })
        );
        emit BuyRequested(_msgSender(), swapType, amountLD);
    }

    /// @inheritdoc ISpotManager
    function sell(uint256 amountLD, SwapType swapType, bytes calldata hedgeData) external authCaller(strategy()) {
        uint256 oracleAmount = IOracle(oracle()).convertTokenAmount(product(), asset(), amountLD);
        uint256 minOutAmount = oracleAmount * (10000 - SLIPPAGE_TOLERANCE_BPS) / 10000;
        bytes memory messageData =
            abi.encode(sellResGasLimit(), _toSD(amountLD), _toSD(minOutAmount), swapType, hedgeData);
        ILogarithmMessenger(messenger()).send(
            SendParams({
                dstChainId: dstChainId(),
                receiver: swapper(),
                token: address(0),
                gasLimit: sellReqGasLimit(),
                amount: 0, // 0 because none of token gets transferred
                data: messageData
            })
        );
        emit SellRequested(_msgSender(), swapType, amountLD);
    }

    /// @notice The product value exposed by this spot manager.
    function exposure() public view returns (uint256) {
        return _getXSpotManagerStorage().exposure;
    }

    /// @notice The asset value hold by this spot manager.
    function getAssetValue() public view returns (uint256) {
        return pendingAssets() + IOracle(oracle()).convertTokenAmount(product(), asset(), exposure());
    }

    /*//////////////////////////////////////////////////////////////
                               FALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Called after buying.
    function receiveMessage(bytes32 sender, bytes calldata data) external authCaller(messenger()) onlySwapper(sender) {
        // abi.encode(uint64(productsSD), uint256(block.timestamp));
        (uint64 productsSD, uint256 timestamp) = abi.decode(data, (uint64, uint256));
        uint256 productsLD = _toLD(productsSD);
        uint256 _pendingAssets = pendingAssets();
        delete _getXSpotManagerStorage().pendingAssets;
        _getXSpotManagerStorage().exposure += productsLD;

        IBasisStrategy(strategy()).spotBuyCallback(_pendingAssets, productsLD, timestamp);
    }

    /// @dev Called after selling.
    function receiveToken(bytes32 sender, address token, uint256 amountLD, bytes calldata data)
        external
        authCaller(messenger())
        onlySwapper(sender)
    {
        if (token != asset()) {
            revert Errors.InvalidTokenSend();
        }
        (uint64 productsSD, uint256 timestamp) = abi.decode(data, (uint64, uint256));
        uint256 productsLD = _toLD(productsSD);
        (, uint256 newExposure) = exposure().trySub(productsLD);
        _getXSpotManagerStorage().exposure = newExposure;

        IBasisStrategy(strategy()).spotSellCallback(amountLD, productsLD, timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of BrotherSwapper on the dest chain.
    function swapper() public view returns (bytes32) {
        return _getXSpotManagerStorage().swapper;
    }

    /// @notice The asset amount that is being processed to buy spot on dest chain.
    function pendingAssets() public view returns (uint256) {
        return _getXSpotManagerStorage().pendingAssets;
    }

    /// @dev The gas limit of lzCompose(swap + lzSend) on dest chain.
    function buyReqGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().buyReqGasLimit;
    }

    /// @dev The gas limit of lzSend(adjustPosition) on original chain.
    function buyResGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().buyResGasLimit;
    }

    /// @dev The gas limit of lzReceive(swap + sendToken) on dest chain.
    function sellReqGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().sellReqGasLimit;
    }

    /// @dev The gas limit of lzCompose() on original chain.
    function sellResGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().sellResGasLimit;
    }

    function strategy() public view returns (address) {
        return _getXSpotManagerStorage().strategy;
    }

    function oracle() public view returns (address) {
        return _getXSpotManagerStorage().oracle;
    }

    /// @inheritdoc ISpotManager
    function asset() public view returns (address) {
        return _getXSpotManagerStorage().asset;
    }

    /// @inheritdoc ISpotManager
    function product() public view returns (address) {
        return _getXSpotManagerStorage().product;
    }

    /// @notice The address of Logarithm cross-chain messenger.
    function messenger() public view returns (address) {
        return _getXSpotManagerStorage().messenger;
    }

    /// @notice The chain id that is used by the messenger, where the swapper is located.
    function dstChainId() public view returns (uint256) {
        return _getXSpotManagerStorage().dstChainId;
    }

    /// @inheritdoc ISpotManager
    function isXChain() public pure returns (bool) {
        return true;
    }
}
