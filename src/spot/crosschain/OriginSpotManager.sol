// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MessagingFee, OFTReceipt, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {IStargate, Ticket} from "src/externals/stargate/interfaces/IStargate.sol";

import {ISpotManager} from "src/spot/ISpotManager.sol";
import {Errors} from "src/libraries/utils/Errors.sol";

/// @title OriginSpotManager
/// @author Logarithm Labs
/// @notice A spot manager smart contract that sends/receives the asset token
/// to/from BrotherSwapper in the destination blockchain and tracks the product exposure.
/// @dev Deployed according to the upgradeable beacon proxy pattern.
contract OriginSpotManager is Initializable, OwnableUpgradeable, ISpotManager {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    struct OriginSpotManagerStorage {
        address strategy;
        address asset;
        address product;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.OriginSpotManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OriginSpotManagerStorageLocation =
        0x95ef178669169c185a874b31b21c7794e00401fe355c9bd013bddba6545f1000;

    function _getOriginSpotManagerStorage() private pure returns (OriginSpotManagerStorage storage $) {
        assembly {
            $.slot := OriginSpotManagerStorageLocation
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

    function initialize(address _owner, address _strategy) external initializer {
        __Ownable_init(_owner);

        SpotManagerStorage storage $ = _getOriginSpotManagerStorage();
        address _asset = IBasisStrategy(_strategy).asset();
        address _product = IBasisStrategy(_strategy).product();

        $.strategy = _strategy;
        $.asset = _asset;
        $.product = _product;

        // approve strategy to max amount
        IERC20(_asset).approve(_strategy, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                             BUY/SELL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Requests BrotherSwapper to buy product.
    ///
    /// @param amount The asset amount to be used to buy product.
    /// @param swapType The swap type.
    /// @param swapData The data used in swapping if necessary.
    function buy(uint256 amount, SwapType swapType, bytes calldata swapData) external authCaller(strategy()) {}

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice The strategy address.
    function strategy() public view returns (address) {
        return _getOriginSpotManagerStorage().strategy;
    }

    /// @notice The asset address.
    function asset() public view returns (address) {
        return _getOriginSpotManagerStorage().asset;
    }

    /// @notice The product address.
    function product() public view returns (address) {
        return _getOriginSpotManagerStorage().product;
    }
}
