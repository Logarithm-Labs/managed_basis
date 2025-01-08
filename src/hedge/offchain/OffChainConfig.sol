// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract OffChainConfig is UUPSUpgradeable, Ownable2StepUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.OffChainConfig
    struct OffChainConfigStorage {
        uint256 increaseSizeMin;
        uint256 increaseCollateralMin;
        uint256 decreaseSizeMin;
        uint256 decreaseCollateralMin;
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

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);

        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        $.increaseSizeMin = 0;
        $.increaseCollateralMin = 0;
        $.decreaseSizeMin = 0;
        $.decreaseCollateralMin = 0;
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setSizeMin(uint256 increaseSizeMin, uint256 decreaseSizeMin) external onlyOwner {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        $.increaseSizeMin = increaseSizeMin;
        $.decreaseSizeMin = decreaseSizeMin;
    }

    function setCollateralMin(uint256 increaseCollateralMin, uint256 decreaseCollateralMin) external onlyOwner {
        uint256 _limitDecreaseCollateral = limitDecreaseCollateral();
        if (_limitDecreaseCollateral != 0) {
            require(_limitDecreaseCollateral > decreaseCollateralMin);
        }
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        $.increaseCollateralMin = increaseCollateralMin;
        $.decreaseCollateralMin = decreaseCollateralMin;
    }

    function setLimitDecreaseCollateral(uint256 limit) external onlyOwner {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        require(limit > $.decreaseCollateralMin);
        $.limitDecreaseCollateral = limit;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function increaseCollateralMin() public view returns (uint256) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return $.increaseCollateralMin;
    }

    function increaseSizeMin() public view returns (uint256) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return $.increaseSizeMin;
    }

    function decreaseCollateralMin() public view returns (uint256) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return $.decreaseCollateralMin;
    }

    function decreaseSizeMin() public view returns (uint256) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return $.decreaseSizeMin;
    }

    function limitDecreaseCollateral() public view returns (uint256) {
        OffChainConfigStorage storage $ = _getOffChainConfigStorage();
        return $.limitDecreaseCollateral;
    }
}
