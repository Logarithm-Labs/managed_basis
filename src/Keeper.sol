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

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData) {
        (bytes32 checkType, address[] memory positionManagers) = abi.decode(checkData, (bytes32, address[]));
        if (checkType == CHECK_UPKEEP_GMX_POSITION_MANAGER) {
            uint256 counter;
            uint256 len = positionManagers.length;
            for (uint256 i; i < len;) {
                bool needSettle = IGmxV2PositionManager(positionManagers[i]).needSettle();
                (bool needAdjust, int256 deltaSizeInTokens) =
                    IGmxV2PositionManager(positionManagers[i]).needAdjustPositionSize();
                if (needSettle || needAdjust) {
                    unchecked {
                        ++counter;
                    }
                }
                unchecked {
                    ++i;
                }
            }

            if (counter == 0) return (false, "");
            upkeepNeeded = true;
            address[] memory neededPositionManagers = new address[](counter);
            bytes32[] memory neededTypes = new bytes32[](counter);
            uint256[] memory neededFees = new uint256[](counter);
            int256[] memory deltaSizes = new int256[](counter);

            uint256 indexCounter;
            for (uint256 i; i < len;) {
                bool needSettle = IGmxV2PositionManager(positionManagers[i]).needSettle();
                if (needSettle) {
                    (,uint256 feeDecrease) = IGmxV2PositionManager(positionManagers[i]).getExecutionFee();
                    neededPositionManagers[indexCounter] = positionManagers[i];
                    neededTypes[indexCounter] = PERFORM_SETTLE_GMX_POSITION_MANAGER;
                    neededFees[indexCounter] = feeDecrease;
                    unchecked {
                        ++indexCounter;
                    }
                } else {
                    (bool needAdjust, int256 deltaSizeInTokens) =
                        IGmxV2PositionManager(positionManagers[i]).needAdjustPositionSize();
                    if (needAdjust) {
                        (uint256 feeIncrease, uint256 feeDecrease) = IGmxV2PositionManager(positionManagers[i]).getExecutionFee();
                        neededPositionManagers[indexCounter] = positionManagers[i];
                        neededTypes[indexCounter] = PERFORM_SETTLE_GMX_POSITION_MANAGER;
                        neededFees[indexCounter] = deltaSizeInTokens > 0 ? feeIncrease : feeDecrease;
                        deltaSizes[indexCounter] = deltaSizeInTokens;
                        unchecked {
                            ++indexCounter;
                        }
                    }
                }
            }

            performData = abi.encode(neededPositionManagers, neededTypes, neededFees, deltaSizes);

            return (upkeepNeeded, performData);
        }

        return (false, "");
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata performData) external {
        if (msg.sender != forwarderAddress()) {
            revert Errors.UnAuthorizedForwarder(msg.sender);
        }
        (address[] memory positionManagers, bytes32[] memory types, uint256[] memory fees, int256[] memory sizes) =
            abi.decode(performData, (address[], bytes32[], uint256[], int256[]));
        uint256 len = positionManagers.length;
        for (uint256 i; i < len;) {
            if (types[i] == PERFORM_SETTLE_GMX_POSITION_MANAGER) {
                IGmxV2PositionManager(positionManagers[i]).decreasePosition{value: fees[i]}(1, 0);
            }
            if (types[i] == PERFORM_ADJUST_GMX_POSITION_MANAGER) {
                if (sizes[i] < 0) {
                    IGmxV2PositionManager(positionManagers[i]).decreasePosition{value: fees[i]}(0, uint256(-sizes[i]));
                } else {
                    IGmxV2PositionManager(positionManagers[i]).increasePosition{value: fees[i]}(0, uint256(sizes[i]));
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Set the address that `performUpkeep` is called from
    /// @dev Only callable by the owner
    /// @param forwarderAddress the address to set
    function setForwarderAddress(address forwarderAddress) external onlyOwner {
        _getKeeperStorage()._forwarderAddress = forwarderAddress;
    }

    function forwarderAddress() public view returns (address) {
        return _getKeeperStorage()._forwarderAddress;
    }
}
