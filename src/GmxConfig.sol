// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IExchangeRouter} from "src/externals/gmx-v2/interfaces/IExchangeRouter.sol";
import {IOrderHandler} from "src/externals/gmx-v2/interfaces/IOrderHandler.sol";

contract GmxConfig is UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:logarithm.storage.GmxConfig
    struct GmxConfigStorage {
        address dataStore;
        address exchangeRouter;
        address orderHandler;
        address orderVault;
        address referralStorage;
        address reader;
        uint256 callbackGasLimit;
        bytes32 referralCode;
    }

    // keccak256(abi.encode(uint256(keccak256("logarithm.storage.GmxConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant GmxConfigStorageLocation =
        0x1e3aaedb53cd624bf0cd11c78d19d483bc92f075987e5791fdd0ed2484ab1200;

    function _getGmxConfigStorage() private pure returns (GmxConfigStorage storage $) {
        assembly {
            $.slot := GmxConfigStorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(address owner_, address exchageRouter_, address reader_) external initializer {
        __Ownable_init(owner_);
        GmxConfigStorage storage $ = _getGmxConfigStorage();
        _updateAddresses(exchageRouter_, reader_);
        $.callbackGasLimit = 2_000_000;
        $.referralCode = bytes32(0);
    }

    function _authorizeUpgrade(address /*newImplementation*/ ) internal virtual override onlyOwner {}

    function _updateAddresses(address exchageRouter_, address reader_) internal {
        GmxConfigStorage storage $ = _getGmxConfigStorage();
        $.exchangeRouter = exchageRouter_;
        $.dataStore = IExchangeRouter(exchageRouter_).dataStore();
        address orderHandler_ = IExchangeRouter(exchageRouter_).orderHandler();
        $.orderHandler = orderHandler_;
        $.orderVault = IOrderHandler(orderHandler_).orderVault();
        $.referralStorage = IOrderHandler(orderHandler_).referralStorage();
        $.reader = reader_;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function updateAddresses(address exchageRouter_, address reader_) external onlyOwner {
        _updateAddresses(exchageRouter_, reader_);
    }

    function setCallbackGasLimit(uint256 callbackGasLimit_) external onlyOwner {
        _getGmxConfigStorage().callbackGasLimit = callbackGasLimit_;
    }

    function setReferralCode(bytes32 referralCode_) external onlyOwner {
        _getGmxConfigStorage().referralCode = referralCode_;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function dataStore() external view returns (address) {
        return _getGmxConfigStorage().dataStore;
    }

    function exchangeRouter() external view returns (address) {
        return _getGmxConfigStorage().exchangeRouter;
    }

    function orderHandler() external view returns (address) {
        return _getGmxConfigStorage().orderHandler;
    }

    function orderVault() external view returns (address) {
        return _getGmxConfigStorage().orderVault;
    }

    function referralStorage() external view returns (address) {
        return _getGmxConfigStorage().referralStorage;
    }

    function reader() external view returns (address) {
        return _getGmxConfigStorage().reader;
    }

    function callbackGasLimit() external view returns (uint256) {
        return _getGmxConfigStorage().callbackGasLimit;
    }

    function referralCode() external view returns (bytes32) {
        return _getGmxConfigStorage().referralCode;
    }
}
