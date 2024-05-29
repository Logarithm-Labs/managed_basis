// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {AutomationCompatibleInterface} from "src/externals/chainlink/interfaces/AutomationCompatibleInterface.sol";

import {IGmxV2PositionManager} from "src/interfaces/IGmxV2PositionManager.sol";

import {Errors} from "src/libraries/Errors.sol";

contract Keeper is AutomationCompatibleInterface, UUPSUpgradeable, Ownable2StepUpgradeable {
    bytes32 public constant CHECK_UPKEEP_GMX_POSITION_MANAGER =
        keccak256(abi.encode("CHECK_UPKEEP_GMX_POSITION_MANAGER"));
    bytes32 public constant PERFORM_SETTLE_GMX_POSITION_MANAGER =
        keccak256(abi.encode("PERFORM_SETTLE_GMX_POSITION_MANAGER"));
    bytes32 public constant PERFORM_ADJUST_GMX_POSITION_MANAGER =
        keccak256(abi.encode("PERFORM_ADJUST_GMX_POSITION_MANAGER"));

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.Keeper
    struct KeeperStorage {
        address _forwarderAddress;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.Keeper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant KeeperStorageLocation = 0x63dafe2512cb44a709d10b12940dfa0f3fb2d081570628c61db84f8f1956ef00;

    function _getKeeperStorage() private pure returns (KeeperStorage storage $) {
        assembly {
            $.slot := KeeperStorageLocation
        }
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function renounceOwnership() public pure override {
        revert();
    }

    receive() external payable {}

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        address positionManager = abi.decode(checkData, (address));
        (upkeepNeeded, performData) = IGmxV2PositionManager(positionManager).checkUpkeep();
        (uint256 feeIncrease, uint256 feeDecrease) = IGmxV2PositionManager(positionManager).getExecutionFee();
        uint256 maxGasFee = feeIncrease > feeDecrease ? feeIncrease : feeDecrease;
        performData = abi.encode(positionManager, maxGasFee, performData);
        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes memory performData) external override {
        if (msg.sender != forwarderAddress()) {
            revert Errors.UnAuthorizedForwarder(msg.sender);
        }
        address positioinManager;
        uint256 executionFee;
        (positioinManager, executionFee, performData) = abi.decode(performData, (address, uint256, bytes));
        IGmxV2PositionManager(positioinManager).performUpkeep{value: executionFee}(performData);
    }

    /// @notice Set the address that `performUpkeep` is called from
    /// @dev Only callable by the owner
    /// @param _forwarderAddress the address to set
    function setForwarderAddress(address _forwarderAddress) external onlyOwner {
        _getKeeperStorage()._forwarderAddress = _forwarderAddress;
    }

    function forwarderAddress() public view returns (address) {
        return _getKeeperStorage()._forwarderAddress;
    }
}
