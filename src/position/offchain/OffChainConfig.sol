// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract OffChainConfig is UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffChainConfig
    struct OffChainConfigStorage {
        uint256[2] increaseSizeMinMax;
        uint256[2] increaseCollateralMinMax;
        uint256[2] decreaseSizeMinMax;
        uint256[2] decreaseCollateralMinMax;
        uint256 limitDecreaseCollateral;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.OffChainConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OffChainConfigStorageLocation =
        0x2671c3f114a72fdfd9bad0ca3f10d494473946d9f50351ab24f6b51f32180700;

    function _getOffChainConfigStorage() private pure returns (OffChainConfigStorage storage $) {
        assembly {
            $.slot := OffChainConfigStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);

        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
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
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
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
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        $.increaseCollateralMinMax = [increaseCollateralMin, increaseCollateralMax];
        $.decreaseCollateralMinMax = [decreaseCollateralMin, decreaseCollateralMax];
    }

    function setLimitDecreaseCollateral(uint256 limit) external onlyOwner {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        require(limit > $.decreaseCollateralMinMax[0]);
        $.limitDecreaseCollateral = limit;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function increaseCollateralMinMax() external view returns (uint256 min, uint256 max) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return ($.increaseCollateralMinMax[0], $.increaseCollateralMinMax[1]);
    }

    function increaseSizeMinMax() external view returns (uint256 min, uint256 max) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return ($.increaseSizeMinMax[0], $.increaseSizeMinMax[1]);
    }

    function decreaseCollateralMinMax() external view returns (uint256 min, uint256 max) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return ($.decreaseCollateralMinMax[0], $.decreaseCollateralMinMax[1]);
    }

    function decreaseSizeMinMax() external view returns (uint256 min, uint256 max) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return ($.decreaseSizeMinMax[0], $.decreaseSizeMinMax[1]);
    }

    function limitDecreaseCollateral() external view returns (uint256) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return $.limitDecreaseCollateral;
    }
}
