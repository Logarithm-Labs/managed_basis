// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";

import {Errors} from "src/libraries/utils/Errors.sol";

contract GmxGasStation is UUPSUpgradeable, Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxGasStation
    struct GmxGasStationStorage {
        mapping(address positionManager => bool) isPositionManager;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxGasStation")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GmxGasStationStorageLocation =
        0x63dafe2512cb44a709d10b12940dfa0f3fb2d081570628c61db84f8f1956ef00;

    function _getGmxGasStationStorage() private pure returns (GmxGasStationStorage storage $) {
        assembly {
            $.slot := GmxGasStationStorageLocation
        }
    }

    modifier onlyPositionManager(address caller) {
        _onlyPositionManager(caller);
        _;
    }

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

    function registerPositionManager(address positionManager, bool allowed) external onlyOwner {
        _getGmxGasStationStorage().isPositionManager[positionManager] = allowed;
    }

    /// @notice withdraw ETH for operators
    function withdraw(uint256 amount) external onlyOwner {
        (bool success,) = msg.sender.call{value: amount}("");
        assert(success);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev pay execution fee for gmx keepers when creating gmx orders
    ///
    /// @param exchangeRouter is the router of gmx
    /// @param orderVault is the vault of gmx to pay fee
    /// @param executionFee is fee to pay
    function payGmxExecutionFee(address exchangeRouter, address orderVault, uint256 executionFee)
        external
        onlyPositionManager(msg.sender)
    {
        IExchangeRouter(exchangeRouter).sendWnt{value: executionFee}(orderVault, executionFee);
    }

    function _onlyPositionManager(address caller) private view {
        if (!_getGmxGasStationStorage().isPositionManager[caller]) {
            revert Errors.CallerNotPositionManager();
        }
    }
}
