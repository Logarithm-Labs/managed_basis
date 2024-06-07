// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {AutomationCompatibleInterface} from "src/externals/chainlink/interfaces/AutomationCompatibleInterface.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";

import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "src/libraries/Errors.sol";

contract Keeper is AutomationCompatibleInterface, UUPSUpgradeable, Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.Keeper
    struct KeeperStorage {
        address _forwarderAddress;
        mapping(address positionManager => bool) _isPositionManager;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.Keeper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant KeeperStorageLocation = 0x63dafe2512cb44a709d10b12940dfa0f3fb2d081570628c61db84f8f1956ef00;

    function _getKeeperStorage() private pure returns (KeeperStorage storage $) {
        assembly {
            $.slot := KeeperStorageLocation
        }
    }

    modifier onlyPositionManager(address caller) {
        _onlyPositionManager(caller);
        _;
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function renounceOwnership() public pure override {
        revert();
    }

    receive() external payable {}

    /// @notice Set the address that `performUpkeep` is called from
    /// @dev Only callable by the owner
    /// @param _forwarderAddress the address to set
    function setForwarderAddress(address _forwarderAddress) external onlyOwner {
        _getKeeperStorage()._forwarderAddress = _forwarderAddress;
    }

    /// @dev register gmx position manager to make them use native ETH
    function registerPositionManager(address positionManager) external onlyOwner {
        _getKeeperStorage()._isPositionManager[positionManager] = true;
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata performData) external override {
        if (msg.sender != forwarderAddress()) {
            revert Errors.UnAuthorizedForwarder(msg.sender);
        }
        _performUpkeep(performData);
    }

    /// @dev used when chainlink is down
    function manualUpkeep(bytes calldata performData) external onlyOwner {
        _performUpkeep(performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        address positionManager = abi.decode(checkData, (address));
        (upkeepNeeded, performData) = IGmxV2PositionManager(positionManager).checkUpkeep();
        performData = abi.encode(positionManager, performData);
        return (upkeepNeeded, performData);
    }

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

    function forwarderAddress() public view returns (address) {
        return _getKeeperStorage()._forwarderAddress;
    }

    function _performUpkeep(bytes memory performData) private {
        address positionManager;
        (positionManager, performData) = abi.decode(performData, (address, bytes));
        IGmxV2PositionManager(positionManager).performUpkeep(performData);
    }

    function _onlyPositionManager(address caller) private view {
        if (!_getKeeperStorage()._isPositionManager[caller]) {
            revert Errors.CallerNotPositionManager();
        }
    }
}
