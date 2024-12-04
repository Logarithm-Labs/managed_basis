// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {MessagingFee, SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IStargate} from "src/externals/stargate/interfaces/IStargate.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IGasStation} from "src/gas-station/IGasStation.sol";
import {IOracle} from "src/oracle/IOracle.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {StargateUtils} from "src/libraries/stargate/StargateUtils.sol";
import {Errors} from "src/libraries/utils/Errors.sol";
import {Constants} from "src/libraries/utils/Constants.sol";
import {AddressCast} from "src/libraries/utils/AddressCast.sol";

import {IMessageRecipient} from "./IMessageRecipient.sol";
import {ILogarithmMessenger, SendParams} from "./ILogarithmMessenger.sol";
import {AssetValueTransmitter} from "./AssetValueTransmitter.sol";

/// @title XSpotManager
//
/// @author Logarithm Labs
//
/// @notice A spot manager smart contract that sends/receives the asset token
/// to/from BrotherSwapper in the destination blockchain and tracks the product exposure.
///
/// @dev Deployed according to the upgradeable beacon proxy pattern.
contract XSpotManager is
    Initializable,
    AssetValueTransmitter,
    OwnableUpgradeable,
    IMessageRecipient,
    ILayerZeroComposer,
    ISpotManager
{
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/
    struct XSpotManagerStorage {
        address strategy;
        address oracle;
        address asset;
        address product;
        address stargate;
        address gasStation;
        address endpoint;
        address messenger;
        uint32 dstEid;
        uint32 srcEid;
        bytes32 swapper;
        uint256 exposure;
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
    event BuyRequested(address indexed caller, SwapType indexed swapType, uint256 assetsSent, uint256 assetsReceived);
    event SellRequested(address indexed caller, SwapType indexed swapType, uint256 indexed products);

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

    function initialize(
        address _owner,
        address _strategy,
        address _gasStation,
        address _endpoint,
        address _stargate,
        address _messenger,
        uint32 _dstEid
    ) external initializer {
        XSpotManagerStorage storage $ = _getXSpotManagerStorage();
        address _asset = IBasisStrategy(_strategy).asset();
        address _product = IBasisStrategy(_strategy).product();

        $.strategy = _strategy;
        $.oracle = IBasisStrategy(_strategy).oracle();
        $.asset = _asset;
        $.product = _product;
        $.gasStation = _gasStation;

        // validate stargate
        if (IStargate(_stargate).token() != _asset) {
            revert Errors.InvalidStargate();
        }

        $.stargate = _stargate;
        $.dstEid = _dstEid;
        $.srcEid = ILayerZeroEndpointV2(_endpoint).eid();

        $.messenger = _messenger;
        $.endpoint = _endpoint;

        __AssetValueTransmitter_init(_product);
        __Ownable_init(_owner);

        // set big enough initially
        _setBuyReqGasLimit(4_000_000);
        _setBuyResGasLimit(4_000_000);
        _setSellReqGasLimit(4_000_000);
        _setSellResGasLimit(4_000_000);

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

    function withdraw(address payable _to, uint256 _amount) external onlyOwner {
        (bool success,) = _to.call{value: _amount}("");
        if (!success) {
            revert();
        }
    }

    /*//////////////////////////////////////////////////////////////
                               MAIN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Requests Swapper to buy product.
    ///
    /// @param amountLD The asset amount in local decimals to buy product.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    /// Important: In case of 1Inch swapData, it must be derived on the dest chain.
    /// At this time, the amount decimals should be the one on the dest chain as well.
    function buy(uint256 amountLD, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        address composer = _validateBrotherSwapper();
        // build compose message
        bytes memory _composeMsg = abi.encode(buyResGasLimit(), swapType, swapData);
        address _stargate = stargate();
        // prepare send
        (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) =
            StargateUtils.prepareTakeTaxi(_stargate, dstEid(), amountLD, composer, buyReqGasLimit(), _composeMsg);
        // withdraw fee
        IGasStation(gasStation()).withdraw(valueToSend);
        // send token
        IERC20(asset()).forceApprove(_stargate, amountLD);
        (, OFTReceipt memory receipt,) =
            IStargate(_stargate).sendToken{value: valueToSend}(sendParam, messagingFee, address(this));
        // always receipt.amountSentLD <= amountLD
        uint256 dust = amountLD - receipt.amountSentLD;
        if (dust > 0) {
            // refund dust
            IERC20(asset()).safeTransfer(_msgSender(), dust);
        }
        _getXSpotManagerStorage().pendingAssets = receipt.amountSentLD;
        emit BuyRequested(_msgSender(), swapType, receipt.amountSentLD, receipt.amountReceivedLD);
    }

    /// @dev Requests Swapper to sell product.
    ///
    /// @param amountLD The product amount in local decimals to be sold.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    /// Important: In case of 1Inch swapData, it must be derived on the dest chain.
    /// At this time, the amount decimals should be the one on the dest chain as well.
    function sell(uint256 amountLD, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        uint64 amountSD = _toSD(amountLD);
        bytes memory payload = abi.encode(sellResGasLimit(), amountSD, swapType, swapData);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(sellReqGasLimit(), 0);
        bytes32 receiver = swapper();
        SendParams memory params =
            SendParams({dstEid: dstEid(), value: 0, receiver: receiver, payload: payload, lzReceiveOption: options});
        address _messenger = messenger();
        (uint256 nativeFee,) = ILogarithmMessenger(_messenger).quote(address(this), params);
        IGasStation(gasStation()).withdraw(nativeFee);
        ILogarithmMessenger(_messenger).sendMessage{value: nativeFee}(params);
        emit SellRequested(_msgSender(), swapType, amountLD);
    }

    function exposure() public view returns (uint256) {
        return _getXSpotManagerStorage().exposure;
    }

    function getAssetValue() public view returns (uint256) {
        return pendingAssets() + IOracle(oracle()).convertTokenAmount(product(), asset(), exposure());
    }

    /*//////////////////////////////////////////////////////////////
                               FALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Called after buying.
    function receiveMessage(bytes32 _sender, bytes calldata _payload) external payable {
        require(_msgSender() == messenger());
        require(_sender == swapper());
        // abi.encode(uint64(productsSD), uint256(block.timestamp));
        (uint64 productsSD, uint256 timestamp) = abi.decode(_payload, (uint64, uint256));
        uint256 productsLD = _toLD(productsSD);
        uint256 _pendingAssets = pendingAssets();
        delete _getXSpotManagerStorage().pendingAssets;
        _getXSpotManagerStorage().exposure += productsLD;
        emit SpotBuy(_pendingAssets, productsLD);

        IBasisStrategy(strategy()).spotBuyCallback(_pendingAssets, productsLD, timestamp);
    }

    /// @dev Called after selling.
    function lzCompose(
        address _from,
        bytes32, /*_guid*/
        bytes calldata _message,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) external payable {
        require(_from == stargate(), "!stargate");
        require(_msgSender() == endpoint(), "!endpoint");
        bytes32 sender = OFTComposeMsgCodec.composeFrom(_message);
        require(sender == swapper(), "!swapper");
        uint256 assetsLD = OFTComposeMsgCodec.amountLD(_message);
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);
        (uint64 productsSD, uint256 timestamp) = abi.decode(composeMsg, (uint64, uint256));
        uint256 productsLD = _toLD(productsSD);
        (, uint256 newExposure) = exposure().trySub(productsLD);
        _getXSpotManagerStorage().exposure = newExposure;
        emit SpotSell(assetsLD, productsLD);

        IBasisStrategy(strategy()).spotSellCallback(assetsLD, productsLD, timestamp);
    }

    /// @dev Refunds eth
    receive() external payable {
        address _gasStation = gasStation();
        if (_msgSender() != _gasStation) {
            // if caller is not the gas station, refund eth to the gasStation
            (bool success,) = _gasStation.call{value: msg.value}("");
            assert(success);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VALIDATIONS
    //////////////////////////////////////////////////////////////*/

    function _validateBrotherSwapper() internal view returns (address) {
        bytes32 _swapper = swapper();
        if (_swapper == bytes32(0)) {
            revert Errors.BrotherSwapperNotInit();
        }
        return AddressCast.bytes32ToAddress(_swapper);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of BrotherSwapper on the dest chain.
    function swapper() public view returns (bytes32) {
        return _getXSpotManagerStorage().swapper;
    }

    function pendingAssets() public view returns (uint256) {
        return _getXSpotManagerStorage().pendingAssets;
    }

    function buyReqGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().buyReqGasLimit;
    }

    function buyResGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().buyResGasLimit;
    }

    function sellReqGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().sellReqGasLimit;
    }

    function sellResGasLimit() public view returns (uint128) {
        return _getXSpotManagerStorage().sellResGasLimit;
    }

    function strategy() public view returns (address) {
        return _getXSpotManagerStorage().strategy;
    }

    function oracle() public view returns (address) {
        return _getXSpotManagerStorage().oracle;
    }

    function asset() public view returns (address) {
        return _getXSpotManagerStorage().asset;
    }

    function product() public view returns (address) {
        return _getXSpotManagerStorage().product;
    }

    function stargate() public view returns (address) {
        return _getXSpotManagerStorage().stargate;
    }

    function gasStation() public view returns (address) {
        return _getXSpotManagerStorage().gasStation;
    }

    function endpoint() public view returns (address) {
        return _getXSpotManagerStorage().endpoint;
    }

    function messenger() public view returns (address) {
        return _getXSpotManagerStorage().messenger;
    }

    function dstEid() public view returns (uint32) {
        return _getXSpotManagerStorage().dstEid;
    }

    function srcEid() public view returns (uint32) {
        return _getXSpotManagerStorage().srcEid;
    }
}
