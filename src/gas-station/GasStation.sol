// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

// import {IExchangeRouter} from "../externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IGasStation} from "./IGasStation.sol";
import {Errors} from "../libraries/utils/Errors.sol";

/// @title GasStation
///
/// @author Logarithm Labs
///
/// @dev GasStation is designed to pay execution gas costs including gmx and cross-chain gas fees.
contract GasStation is UUPSUpgradeable, Ownable2StepUpgradeable, IGasStation {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GasStation
    struct GasStationStorage {
        mapping(address manager => bool) isRegistered;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GasStation")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GasStationStorageLocation =
        0x9366fbbab19ee4ad13517d343e280b7e15520706d753013a2ab04658044b2e00;

    function _getGasStationStorage() private pure returns (GasStationStorage storage $) {
        assembly {
            $.slot := GasStationStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ManagerRegistered(address indexed account, address indexed manager, bool indexed allowed);

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function renounceOwnership() public pure override {
        revert();
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Registers system managers to use eth balance of this contract for the execution fees.
    function registerManager(address manager, bool allowed) external onlyOwner {
        if (isRegistered(manager) != allowed) {
            _getGasStationStorage().isRegistered[manager] = allowed;
            emit ManagerRegistered(_msgSender(), manager, allowed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // /// @dev Pays the execution fee for gmx keepers when creating gmx orders.
    // ///
    // /// @param exchangeRouter The address of gmx's exchangeRouter.
    // /// @param orderVault The address of gmx's orderVault.
    // /// @param executionFee The fee amount to pay.
    // function payGmxExecutionFee(address exchangeRouter, address orderVault, uint256 executionFee) external {
    //     _requireRegistered(_msgSender());
    //     IExchangeRouter(exchangeRouter).sendWnt{value: executionFee}(orderVault, executionFee);
    // }

    /// @notice Withdraws ether of this smart contract.
    function withdraw(uint256 amount) external {
        _requireOwnerOrRegistered(_msgSender());
        (bool success,) = msg.sender.call{value: amount}("");
        assert(success);
    }

    /// @dev Authorize caller if it is registered.
    function _requireRegistered(address caller) private view {
        if (!isRegistered(caller)) {
            revert Errors.GasCallerNotAllowed();
        }
    }

    /// @dev Authorize caller if it is registered or owner.
    function _requireOwnerOrRegistered(address caller) private view {
        if (caller != owner() && !isRegistered(caller)) {
            revert Errors.GasCallerNotAllowed();
        }
    }

    /// @dev Tells if a manager is registered or not.
    function isRegistered(address manager) public view returns (bool) {
        return _getGasStationStorage().isRegistered[manager];
    }
}
