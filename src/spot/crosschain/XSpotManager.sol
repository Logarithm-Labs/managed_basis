// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MessagingFee, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IStargate} from "src/externals/stargate/interfaces/IStargate.sol";
import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IGasStation} from "src/gas-station/IGasStation.sol";
import {IMessageRecipient} from "src/messenger/IMessageRecipient.sol";
import {ISpotManager} from "src/spot/ISpotManager.sol";
import {StargateUtils} from "src/libraries/stargate/StargateUtils.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title XSpotManager
//
/// @author Logarithm Labs
//
/// @notice A spot manager smart contract that sends/receives the asset token
/// to/from BrotherSwapper in the destination blockchain and tracks the product exposure.
///
/// @dev Deployed according to the upgradeable beacon proxy pattern.
contract XSpotManager is Initializable, OwnableUpgradeable, IMessageRecipient, ISpotManager {
    using SafeERC20 for IERC20;

    address public immutable strategy;
    address public immutable asset;
    address public immutable product;
    address public immutable gasStation;
    address public immutable stargate;
    // destination configure
    uint32 public immutable dstEid;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/
    struct XSpotManagerStorage {
        bytes32 swapper;
        uint256 exposure;
        uint256 pendingAssets;
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

    constructor(address _strategy, address _gasStation, address _stargate, uint32 _dstEid) {
        address _asset = IBasisStrategy(_strategy).asset();
        address _product = IBasisStrategy(_strategy).product();

        strategy = _strategy;
        asset = _asset;
        product = _product;

        // validate gasStation
        if (_gasStation == address(0)) revert Errors.ZeroAddress();
        gasStation = _gasStation;

        // validate stargate
        if (IStargate(_stargate).token() != _asset) {
            revert Errors.InvalidStargate();
        }

        stargate = _stargate;
        dstEid = _dstEid;

        // approve strategy to max amount
        IERC20(_asset).approve(_strategy, type(uint256).max);
    }

    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
    }

    /// @notice Sets the address of BrotherSwapper which is in the destination chain.
    ///
    /// @dev Should be set before running stratey.
    function setBrotherSwapper(bytes32 _swapper) external onlyOwner {
        if (_swapper == bytes32(0)) {
            revert Errors.ZeroAddress();
        }
        _getXSpotManagerStorage().swapper = _swapper;
    }

    /*//////////////////////////////////////////////////////////////
                             BUY/SELL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Requests BrotherSwapper to buy product.
    ///
    /// @param amount The asset amount to be used to buy product.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy) {
        bytes memory _composeMsg = abi.encode(swapType, swapData);
        address composer = _validateBrotherSwapper();

        IERC20(asset).forceApprove(stargate, amount);

        (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) =
            StargateUtils.prepareTakeTaxiAndSwap(stargate, dstEid, amount, composer, _composeMsg);

        IGasStation(gasStation).withdraw(valueToSend);
        _getXSpotManagerStorage().pendingAssets = amount;
        IStargate(stargate).sendToken{value: valueToSend}(sendParam, messagingFee, address(this));
    }

    function sell(uint256 amount, SwapType swapType, bytes calldata swapData) external {}
    function exposure() external view returns (uint256) {}

    function receiveMessage(bytes32 _sender, bytes calldata _payload) external payable {
        require(_sender == swapper());
        uint256 amountOut = abi.decode(_payload, (uint256));
        uint256 _pendingAssets = pendingAssets();
        delete _getXSpotManagerStorage().pendingAssets;
        _getXSpotManagerStorage().exposure += amountOut;
        IBasisStrategy(strategy).spotBuyCallback(_pendingAssets, amountOut);
    }

    /// @dev Refunds eth
    receive() external payable {
        if (_msgSender() != gasStation) {
            // if caller is not the gas station, refund eth to the gasStation
            (bool success,) = gasStation.call{value: msg.value}("");
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
        return StargateUtils.bytes32ToAddress(_swapper);
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
}
