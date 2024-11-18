// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MessagingFee, OFTReceipt, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IStargate, Ticket} from "src/externals/stargate/interfaces/IStargate.sol";

import {IBasisStrategy} from "src/strategy/IBasisStrategy.sol";
import {IGasStation} from "src/gas-station/IGasStation.sol";
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
contract XSpotManager is Initializable, OwnableUpgradeable, ISpotManager {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/
    struct XSpotManagerStorage {
        address strategy;
        address asset;
        address product;
        address gasStation;
        address stargate;
        address brotherSwapper;
        uint32 dstEid;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.XSpotManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant XSpotManagerStorageLocation =
        0x95ef178669169c185a874b31b21c7794e00401fe355c9bd013bddba6545f1000;

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

    function initialize(address _owner, address _strategy, address _gasStation, address _stargate, uint32 _dstEid)
        external
        initializer
    {
        __Ownable_init(_owner);

        XSpotManagerStorage storage $ = _getXSpotManagerStorage();
        address _asset = IBasisStrategy(_strategy).asset();
        address _product = IBasisStrategy(_strategy).product();

        $.strategy = _strategy;
        $.asset = _asset;
        $.product = _product;

        // validate gasStation
        if (_gasStation == address(0)) revert Errors.ZeroAddress();
        $.gasStation = _gasStation;

        // validate stargate
        if (IStargate(_stargate).token() != _asset) {
            revert Errors.InvalidStargate();
        }

        $.stargate = _stargate;
        $.dstEid = _dstEid;

        // approve strategy to max amount
        IERC20(_asset).approve(_strategy, type(uint256).max);
    }

    /// @notice Sets the address of BrotherSwapper which is in the destination chain.
    ///
    /// @dev Should be set before running stratey.
    function setBrotherSwapper(address _swapper) external onlyOwner {
        if (_swapper == address(0)) {
            revert Errors.ZeroAddress();
        }
        _getXSpotManagerStorage().brotherSwapper = _swapper;
    }

    /*//////////////////////////////////////////////////////////////
                             BUY/SELL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Requests BrotherSwapper to buy product.
    ///
    /// @param amount The asset amount to be used to buy product.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {
        bytes memory _composeMsg = abi.encode(swapType, swapData);
        address composer = _validateBrotherSwapper();
        address _stargate = stargate();

        IERC20(asset()).forceApprove(_stargate, amount);

        (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) =
            StargateUtils.prepareTakeTaxiAndSwap(_stargate, dstEid(), amount, composer, _composeMsg);

        IGasStation(gasStation()).withdraw(valueToSend);
        IStargate(_stargate).sendToken{value: valueToSend}(sendParam, messagingFee, address(this));
    }

    function sell(uint256 amount, SwapType swapType, bytes calldata swapData) external {}
    function exposure() external view returns (uint256) {}

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
        address _brotherSwapper = brotherSwapper();
        if (_brotherSwapper == address(0)) {
            revert Errors.BrotherSwapperNotInit();
        }
        return _brotherSwapper;
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The strategy address.
    function strategy() public view returns (address) {
        return _getXSpotManagerStorage().strategy;
    }

    /// @notice The asset address.
    function asset() public view returns (address) {
        return _getXSpotManagerStorage().asset;
    }

    /// @notice The product address.
    function product() public view returns (address) {
        return _getXSpotManagerStorage().product;
    }

    /// @notice The gasStation address.
    function gasStation() public view returns (address) {
        return _getXSpotManagerStorage().gasStation;
    }

    /// @notice The address of stargate pool
    function stargate() public view returns (address) {
        return _getXSpotManagerStorage().stargate;
    }

    /// @notice The address of BrotherSwapper on the dest chain.
    function brotherSwapper() public view returns (address) {
        return _getXSpotManagerStorage().brotherSwapper;
    }

    /// @notice The destinationEndpointId for a destination chain, provided by stargate.
    function dstEid() public view returns (uint32) {
        return _getXSpotManagerStorage().dstEid;
    }
}
