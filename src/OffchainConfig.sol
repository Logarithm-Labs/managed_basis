// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract OffchainConfig is UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffchainConfig
    struct OffchainConfigStorage {
        uint256[2] increaseSizeMinMax;
        uint256[2] increaseCollateralMinMax;
        uint256[2] decreaseSizeMinMax;
        uint256[2] decreaseCollateralMinMax;
        uint256 limitDecreaseCollateral;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.OffchainConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OffchainConfigStorageLocation =
        0x99de5ae07e9b21f08a1b366635903c476af2a6e23356f0c0cd32acf443766c00;

    function _getOffchainConfigStorage() private pure returns (OffchainConfigStorage storage $) {
        assembly {
            $.slot := OffchainConfigStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);

        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        $.increaseSizeMinMax = [0, type(uint256).max];
        $.increaseCollateralMinMax = [0, type(uint256).max];
        $.decreaseSizeMinMax = [0, type(uint256).max];
        $.decreaseCollateralMinMax = [0, type(uint256).max];
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setSizeMinMax(
        uint256 increaseSizeMin,
        uint256 increaseSizeMax,
        uint256 decreaseSizeMin,
        uint256 decreaseSizeMax
    ) external onlyOwner {
        require(increaseSizeMin < increaseSizeMax && decreaseSizeMin < decreaseSizeMax);
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        $.increaseSizeMinMax = [increaseSizeMin, increaseSizeMax];
        $.decreaseSizeMinMax = [decreaseSizeMin, decreaseSizeMax];
    }

    function setCollateralMinMax(
        uint256 increaseCollateralMin,
        uint256 increaseCollateralMax,
        uint256 decreaseCollateralMin,
        uint256 decreaseCollateralMax
    ) external onlyOwner {
        require(increaseCollateralMin < increaseCollateralMax && decreaseCollateralMin < decreaseCollateralMax);
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        $.increaseCollateralMinMax = [increaseCollateralMin, increaseCollateralMax];
        $.decreaseCollateralMinMax = [decreaseCollateralMin, decreaseCollateralMax];
    }

    function setLimitDecreaseCollateral(uint256 limit) external onlyOwner {
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        require(limit > $.decreaseCollateralMinMax[0]);
        $.limitDecreaseCollateral = limit;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max) {
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        return ($.increaseCollateralMinMax[0], $.increaseCollateralMinMax[1]);
    }

    function increaseSizeMinMax() external view returns (uint256 min, uint256 max) {
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        return ($.increaseSizeMinMax[0], $.increaseSizeMinMax[1]);
    }

    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max) {
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        return ($.decreaseCollateralMinMax[0], $.decreaseCollateralMinMax[1]);
    }

    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max) {
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        return ($.decreaseSizeMinMax[0], $.decreaseSizeMinMax[1]);
    }

    function limitDecreaseCollateral() external view returns (uint256) {
        OffchainConfigStorage storage $ = _getOffchainConfigStorage();
        return $.limitDecreaseCollateral;
    }
}
